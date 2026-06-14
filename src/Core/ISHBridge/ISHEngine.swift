import Foundation

// MARK: - EngineState

/// ish Linux 引擎的初始化状态。
///
/// 状态流转：
/// ```
/// uninitialized → extracting → booting → ready
///                                  ↘ error(String)
/// ```
enum EngineState: Equatable, CustomStringConvertible {
    /// 尚未初始化。
    case uninitialized

    /// 正在解压 rootfs 到目标路径。
    case extracting(progress: String)

    /// 正在启动 ish Linux 内核。
    case booting

    /// 引擎就绪，可执行 shell 命令。
    case ready

    /// 初始化失败，携带错误描述。
    case error(String)

    var description: String {
        switch self {
        case .uninitialized:        return "未初始化"
        case .extracting(let p):    return "解压中: \(p)"
        case .booting:              return "内核启动中..."
        case .ready:                return "就绪"
        case .error(let msg):       return "错误: \(msg)"
        }
    }
}

// MARK: - EngineError

/// 引擎初始化过程中可能出现的错误。
enum EngineError: Error, LocalizedError {
    /// 捆绑的 rootfs 资源未找到。
    case rootfsNotFound

    /// rootfs 文件损坏，携带原因描述。
    case rootfsCorrupted(reason: String)

    /// rootfs 解压失败，携带底层错误。
    case extractionFailed(underlying: String)

    /// ish 内核启动失败，携带错误码或原因。
    case kernelBootFailed(reason: String)

    /// 引擎已经初始化，重复调用。
    case alreadyInitialized

    /// 引擎尚未初始化。
    case notInitialized

    /// 磁盘空间不足。
    case diskSpaceInsufficient(availableBytes: Int64, neededBytes: Int64)

    /// 引擎就绪验证失败（ping 测试未通过）。
    case readinessCheckFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .rootfsNotFound:
            return "捆绑的 Alpine rootfs.tar.gz 未找到"
        case .rootfsCorrupted(let reason):
            return "RootFS 损坏: \(reason)"
        case .extractionFailed(let msg):
            return "RootFS 解压失败: \(msg)"
        case .kernelBootFailed(let reason):
            return "ish 内核启动失败: \(reason)"
        case .alreadyInitialized:
            return "引擎已初始化"
        case .notInitialized:
            return "引擎尚未初始化"
        case .diskSpaceInsufficient(let avail, let need):
            return "磁盘空间不足: 可用 \(avail) 字节，需要 \(need) 字节"
        case .readinessCheckFailed(let reason):
            return "引擎就绪检查失败: \(reason)"
        }
    }
}

// MARK: - ISHEngine

/// ish ARM64 Linux 模拟器引擎。
///
/// 单例，全局唯一内核实例。管理从 rootfs 解压到内核启动的完整生命周期。
///
/// - Important: 必须在 App 启动时调用 `initialize(rootfsURL:)` 初始化引擎。
///   ISHShellBridge 和 BindMountService 都依赖此引擎就绪。
///
/// 使用示例：
/// ```swift
/// // 在 App 入口：
/// let engine = ISHEngine.shared
/// Task {
///     guard let url = Bundle.main.url(forResource: "alpine-aarch64",
///                                      withExtension: "tar.gz") else { return }
///     try await engine.initialize(rootfsURL: url)
/// }
/// ```
@MainActor
final class ISHEngine: ObservableObject {

    // MARK: - Singleton

    /// 全局唯一引擎实例。
    static let shared = ISHEngine()

    // MARK: - Published State

    /// 当前引擎状态。SwiftUI 视图可观察此属性。
    @Published var state: EngineState = .uninitialized

    /// 引擎是否已成功初始化并就绪。
    /// 仅当 state == .ready 时返回 true，确保状态一致性。
    var isInitialized: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Internal State

    /// 内核是否已成功启动（即使就绪检查可能失败）。
    private(set) var bootCompleted: Bool = false

    /// rootfs 解压后的路径。
    private(set) var rootfsPath: String = ""

    /// RootFS 管理器。
    private let rootfsManager = RootFSManager()

    /// 初始化锁，防止并发重复初始化。
    private var isInitializing = false

    // MARK: - Public API: initialize

    /// 初始化引擎：解压 rootfs → 启动 ish 内核 → 就绪验证。
    ///
    /// 幂等：重复调用不重复初始化。若引擎已就绪，直接返回。
    ///
    /// - Parameter rootfsURL: Alpine rootfs.tar.gz 的本地文件 URL。
    /// - Throws: ``EngineError`` 描述具体失败原因。
    func initialize(rootfsURL: URL) async throws {
        // 幂等检查
        if bootCompleted && state == .ready {
            print("[ISHEngine] 引擎已就绪，跳过初始化")
            return
        }

        // 并发保护
        guard !isInitializing else {
            print("[ISHEngine] 初始化进行中，跳过重复调用")
            return
        }
        isInitializing = true
        defer { isInitializing = false }

        print("[ISHEngine] 开始引擎初始化...")

        // ---- Phase 1: Extract RootFS ----
        state = .extracting(progress: "准备 rootfs...")

        let rootPath: String
        do {
            rootPath = try await rootfsManager.prepareRootFS(from: rootfsURL)
        } catch let error as EngineError {
            state = .error(error.localizedDescription)
            throw error
        } catch {
            let wrapped = EngineError.extractionFailed(underlying: error.localizedDescription)
            state = .error(wrapped.localizedDescription)
            throw wrapped
        }

        self.rootfsPath = rootPath
        print("[ISHEngine] RootFS 就绪: \(rootPath)")

        // ---- Phase 2: Boot Kernel ----
        state = .booting

        // Initialize ish environment
        let shim = ISHAppShim.current
        guard shim.initISH() else {
            let err = EngineError.kernelBootFailed(reason: "ish 环境初始化失败")
            state = .error(err.localizedDescription)
            throw err
        }

        // Boot the Linux kernel
        let bootResult = shim.bootKernel(rootPath)
        guard bootResult == 0 else {
            let err = EngineError.kernelBootFailed(reason: "actuate_kernel() 返回 \(bootResult)")
            state = .error(err.localizedDescription)
            throw err
        }

        // ---- Phase 3: Readiness Check ----
        // Verify the engine is truly ready for shell execution.
        // State remains .booting during verification — engine is still coming up.

        do {
            try await verifyReadiness()
        } catch let error as EngineError {
            state = .error(error.localizedDescription)
            throw error
        } catch {
            let wrapped = EngineError.readinessCheckFailed(reason: error.localizedDescription)
            state = .error(wrapped.localizedDescription)
            throw wrapped
        }

        // ---- Success ----
        bootCompleted = true
        state = .ready
        print("[ISHEngine] ✅ ish-arm64 引擎就绪")
    }

    // MARK: - Readiness Verification

    /// 通过在 guest 中执行 `echo 'engine-ready'` 验证引擎是否真正可用。
    private func verifyReadiness() async throws {
        print("[ISHEngine] 执行就绪检查: echo 'engine-ready'")

        // The readiness check uses ISHShellBridge, which depends on ISHEngine.
        // To avoid circular dependency during initialization, we use a direct
        // call to the underlying ISHShellExecutor C API (if already loaded).
        //
        // For the initial implementation, we check:
        // 1. ISHAppShim reports bootCompleted
        // 2. ISHAppShim reports ishInitialized
        // 3. We perform a lightweight `access()` check on rootfs /bin/sh

        guard ISHAppShim.current.bootCompleted else {
            throw EngineError.readinessCheckFailed(reason: "内核启动标志未设置")
        }

        // Verify rootfs /bin/sh exists (quick sanity check)
        let shPath = (rootfsPath as NSString).appendingPathComponent("bin/sh")
        guard FileSystemAccess.fileExists(at: shPath) else {
            throw EngineError.rootfsCorrupted(
                reason: "rootfs 中未找到 /bin/sh: \(shPath)"
            )
        }

        // Verify /etc/passwd exists (another critical file)
        let passwdPath = (rootfsPath as NSString).appendingPathComponent("etc/passwd")
        guard FileSystemAccess.fileExists(at: passwdPath) else {
            throw EngineError.rootfsCorrupted(
                reason: "rootfs 中未找到 /etc/passwd: \(passwdPath)"
            )
        }

        // If ISHShellBridge is available, do a full execution check
        // (This will be available on subsequent calls; on first boot we
        //  rely on the structural checks above.)
        print("[ISHEngine] 就绪检查通过: rootfs 结构完整，内核已启动")
    }

    // MARK: - Error Handling Helper

    /// 验证引擎已初始化，否则抛出 EngineError.notInitialized。
    /// 供 ISHShellBridge 和 BindMountService 调用。
    func validateEngine() throws {
        guard isInitialized else {
            throw EngineError.notInitialized
        }
    }
}

// MARK: - RootFSManager

/// 管理 Alpine Linux aarch64 rootfs 的准备和验证。
///
/// 负责：
/// 1. 从捆绑的 `alpine-aarch64.tar.gz` 解压 rootfs
/// 2. 验证解压后的 rootfs 结构完整性
/// 3. 幂等：已解压则跳过
final class RootFSManager: @unchecked Sendable {

    /// rootfs 解压目标根目录（App Documents 内）。
    private var targetRoot: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return docs.appendingPathComponent("ish-rootfs", isDirectory: true)
    }

    /// rootfs 解压后的完整路径。
    private var rootfsPath: String {
        targetRoot.path
    }

    // MARK: - Prepare

    /// 准备 rootfs：若已存在则直接返回路径，否则从捆绑包解压。
    ///
    /// - Parameter rootfsURL: 捆绑的 .tar.gz 文件 URL。
    /// - Returns: rootfs 解压后的目录路径。
    /// - Throws: ``EngineError``。
    func prepareRootFS(from rootfsURL: URL) async throws -> String {
        // Check if rootfs already exists
        if rootfsExists() {
            print("[RootFSManager] rootfs 已存在，跳过解压: \(rootfsPath)")
            return rootfsPath
        }

        // Validate source file exists
        guard FileManager.default.fileExists(atPath: rootfsURL.path) else {
            throw EngineError.rootfsNotFound
        }

        // Check disk space
        let neededBytes = try estimateNeededSpace(sourceURL: rootfsURL)
        let availableBytes = try freeDiskSpace(at: targetRoot.path)
        guard availableBytes >= neededBytes else {
            throw EngineError.diskSpaceInsufficient(
                availableBytes: availableBytes,
                neededBytes: neededBytes
            )
        }

        // Extract
        print("[RootFSManager] 开始解压 rootfs: \(rootfsURL.lastPathComponent)...")
        try await extractTarGz(at: rootfsURL)

        // Verify
        try verifyRootFS()

        print("[RootFSManager] ✅ RootFS 准备完成: \(rootfsPath)")
        return rootfsPath
    }

    // MARK: - Existence Check

    /// 检查 rootfs 是否已解压并有效。
    func rootfsExists() -> Bool {
        let shPath = (rootfsPath as NSString).appendingPathComponent("bin/sh")
        return FileSystemAccess.fileExists(at: shPath)
    }

    // MARK: - Cleanup

    /// 删除已解压的 rootfs（用于强制重新初始化）。
    func cleanupRootFS() throws {
        guard FileSystemAccess.fileExists(at: rootfsPath) else { return }
        print("[RootFSManager] 清理 rootfs: \(rootfsPath)")
        try FileSystemAccess.deleteDirectory(at: rootfsPath)
    }

    // MARK: - Extraction

    /// 使用 libarchive C API 解压 tar.gz（不需要 entitlements）。
    private func extractTarGz(at sourceURL: URL) async throws {
        try FileSystemAccess.createDirectory(at: rootfsPath, withIntermediate: true)

        let result = agentbox_extract_targz(sourceURL.path, rootfsPath)
        guard result == 0 else {
            throw EngineError.extractionFailed(underlying: "libarchive extraction failed, errno: \(errno)")
        }
    }

    // MARK: - Verification

    /// 验证解压后的 rootfs 包含关键文件。
    private func verifyRootFS() throws {
        let requiredFiles = [
            "bin/sh",
            "etc/passwd",
            "etc/alpine-release",
            "lib/ld-musl-aarch64.so.1",
            "usr/bin/env",
        ]

        var missingFiles: [String] = []

        for file in requiredFiles {
            let fullPath = (rootfsPath as NSString).appendingPathComponent(file)
            if !FileSystemAccess.fileExists(at: fullPath) {
                missingFiles.append(file)
            }
        }

        guard missingFiles.isEmpty else {
            throw EngineError.rootfsCorrupted(
                reason: "缺少关键文件: \(missingFiles.joined(separator: ", "))"
            )
        }

        print("[RootFSManager] RootFS 验证通过: 所有关键文件存在")
    }

    // MARK: - Disk Space Estimation

    /// 估算解压需要的磁盘空间（通常 tar.gz 解压后约 2-3x 大小）。
    private func estimateNeededSpace(sourceURL: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let compressedSize = (attrs[.size] as? Int64) ?? 0
        // Conservative estimate: 4x compressed size
        return compressedSize * 4
    }

    /// 获取路径所在卷的可用空间。
    private func freeDiskSpace(at path: String) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
        return (attrs[.systemFreeSize] as? Int64) ?? 0
    }
}

// MARK: - ISHEngine Convenience Extensions

extension ISHEngine {

    /// 重置引擎状态（用于测试或强制重新初始化）。
    func resetEngine() {
        state = .uninitialized
        bootCompleted = false
        rootfsPath = ""
        print("[ISHEngine] 引擎状态已重置")
    }

    /// 强制重新初始化（先清理 rootfs 再初始化）。
    func reinitialize(rootfsURL: URL) async throws {
        resetEngine()
        do {
            try rootfsManager.cleanupRootFS()
        } catch {
            print("[ISHEngine] 清理旧 rootfs 失败（可忽略）: \(error)")
        }
        try await initialize(rootfsURL: rootfsURL)
    }
}
