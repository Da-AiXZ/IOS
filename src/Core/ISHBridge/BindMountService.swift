import Foundation

// MARK: - BindMount

/// 单条绑定挂载记录。
struct BindMount: Identifiable, Sendable {
    /// 唯一挂载标识符。
    let id: UUID

    /// iOS 主机文件系统路径（宿主路径）。
    let hostPath: String

    /// Linux guest 内挂载点路径。
    let guestPath: String

    /// 是否只读挂载。
    let isReadOnly: Bool

    /// 挂载创建时间。
    let createdAt: Date

    init(
        id: UUID = UUID(),
        hostPath: String,
        guestPath: String,
        isReadOnly: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.isReadOnly = isReadOnly
        self.createdAt = createdAt
    }
}

// MARK: - MountError

/// 绑定挂载操作错误。
enum MountError: Error, LocalizedError {
    /// 主机路径不存在。
    case hostPathNotFound(path: String)

    /// Guest 路径不可访问。
    case guestPathInaccessible(path: String)

    /// 路径已被挂载。
    case alreadyMounted(existing: BindMount)

    /// 指定 guest 路径未挂载。
    case notMounted(guestPath: String)

    /// ISHEngine 尚未初始化。
    case engineNotInitialized

    /// mount syscall 在 guest 内失败，携带 errno。
    case mountSyscallFailed(errno: Int32, message: String)

    /// 卸载失败。
    case unmountFailed(guestPath: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .hostPathNotFound(let p):
            return "主机路径不存在: \(p)"
        case .guestPathInaccessible(let p):
            return "Guest 路径不可访问: \(p)"
        case .alreadyMounted(let existing):
            return "路径已挂载: host=\(existing.hostPath) → guest=\(existing.guestPath)"
        case .notMounted(let p):
            return "Guest 路径未挂载: \(p)"
        case .engineNotInitialized:
            return "ish 引擎尚未初始化"
        case .mountSyscallFailed(let err, let msg):
            return "mount 系统调用失败 [errno=\(err)]: \(msg)"
        case .unmountFailed(let p, let reason):
            return "卸载 \(p) 失败: \(reason)"
        }
    }
}

// MARK: - BindMountService

/// iOS 主机路径 ↔ Linux guest 路径绑定挂载服务。
///
/// 依赖 ish fakefs 的 bind mount 能力。在 guest 内通过 `mount --bind`
/// 命令实现（若 fakefs 不支持，回退到 realfs C API）。
///
/// - Important: 需要 ISHEngine 已初始化，且 ISHShellBridge 可用。
///
/// 使用示例：
/// ```swift
/// let service = BindMountService.shared
///
/// // 挂载
/// try await service.mount(
///     hostPath: "/var/mobile/Documents/workspace",
///     guestPath: "/mnt/workspace"
/// )
///
/// // 卸载
/// try await service.unmount(guestPath: "/mnt/workspace")
/// ```
actor BindMountService {

    // MARK: - Singleton

    /// 全局唯一挂载服务实例。
    static let shared = BindMountService()

    // MARK: - Mount Table

    /// 当前所有活跃挂载，key 为 mount ID。
    private var activeMounts: [UUID: BindMount] = [:]

    /// guestPath → mount ID 快速索引。
    private var guestPathIndex: [String: UUID] = [:]

    /// hostPath → mount ID 快速索引。
    private var hostPathIndex: [String: UUID] = [:]

    // MARK: - Computed Properties

    /// 当前所有活跃挂载的只读副本。
    var mounts: [BindMount] {
        Array(activeMounts.values).sorted { $0.createdAt < $1.createdAt }
    }

    /// 当前活跃挂载数量。
    var mountCount: Int {
        activeMounts.count
    }

    // MARK: - Public API: Mount

    /// 将 iOS 主机路径挂载到 Linux guest 路径。
    ///
    /// 操作步骤：
    /// 1. 验证主机路径存在
    /// 2. 验证引擎已初始化
    /// 3. 在 guest 内创建挂载点目录（若不存在）
    /// 4. 执行 `mount --bind <hostPath> <guestPath>`
    /// 5. 验证挂载成功（`ls <guestPath>`）
    ///
    /// - Parameters:
    ///   - hostPath: iOS 文件系统绝对路径（如 `/var/mobile/Documents/workspace`）。
    ///   - guestPath: Linux guest 内绝对路径（如 `/mnt/workspace`）。
    ///   - isReadOnly: 是否只读挂载。默认 `false`。
    /// - Throws: ``MountError``。
    func mount(
        hostPath: String,
        guestPath: String,
        isReadOnly: Bool = false
    ) async throws {
        // Validate engine — ISHEngine is @MainActor, must await
        guard await ISHEngine.shared.isInitialized else {
            throw MountError.engineNotInitialized
        }

        // Validate host path exists (use POSIX API to bypass sandbox)
        guard FileSystemAccess.fileExists(at: hostPath) else {
            throw MountError.hostPathNotFound(path: hostPath)
        }

        // Check for duplicate mount
        if let existingID = guestPathIndex[guestPath],
           let existing = activeMounts[existingID] {
            throw MountError.alreadyMounted(existing: existing)
        }

        print("[BindMountService] 挂载: \(hostPath) → \(guestPath)"
              + (isReadOnly ? " (只读)" : ""))

        // Step 1: Ensure guest mount point exists
        let mkdirResult = try await ISHShellBridge.shared.execute(
            "mkdir -p '\(escapePath(guestPath))'"
        )
        guard mkdirResult.success else {
            throw MountError.guestPathInaccessible(
                path: "无法创建挂载点 \(guestPath): \(mkdirResult.stderr)"
            )
        }

        // Step 2: Execute bind mount in guest
        var mountCmd = "mount"
        if isReadOnly {
            mountCmd += " -o ro"
        }
        mountCmd += " --bind '\(escapePath(hostPath))' '\(escapePath(guestPath))'"

        let mountResult = try await ISHShellBridge.shared.execute(mountCmd)
        guard mountResult.success else {
            throw MountError.mountSyscallFailed(
                errno: mountResult.exitCode,
                message: mountResult.stderr.isEmpty
                    ? "mount 命令返回 \(mountResult.exitCode)"
                    : mountResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Step 3: Verify mount by listing guest path
        let verifyResult = try await ISHShellBridge.shared.execute(
            "ls -la '\(escapePath(guestPath))'"
        )
        guard verifyResult.success else {
            // Mount command succeeded but verification failed — try unmount
            _ = try? await ISHShellBridge.shared.execute(
                "umount '\(escapePath(guestPath))'"
            )
            throw MountError.mountSyscallFailed(
                errno: verifyResult.exitCode,
                message: "挂载验证失败: \(verifyResult.stderr)"
            )
        }

        // Step 4: Record the mount
        let mount = BindMount(
            hostPath: hostPath,
            guestPath: guestPath,
            isReadOnly: isReadOnly
        )
        activeMounts[mount.id] = mount
        guestPathIndex[guestPath] = mount.id
        hostPathIndex[hostPath] = mount.id

        print("[BindMountService] ✅ 挂载成功: \(hostPath) → \(guestPath)")
    }

    // MARK: - Public API: Unmount

    /// 卸载指定 guest 路径的挂载。
    ///
    /// - Parameter guestPath: 要卸载的 guest 路径。
    /// - Throws: ``MountError``。
    func unmount(guestPath: String) async throws {
        // ISHEngine is @MainActor, must await
        guard await ISHEngine.shared.isInitialized else {
            throw MountError.engineNotInitialized
        }

        // Check mount exists
        guard let mountID = guestPathIndex[guestPath],
              let mount = activeMounts[mountID] else {
            throw MountError.notMounted(guestPath: guestPath)
        }

        print("[BindMountService] 卸载: \(guestPath)")

        // Execute umount in guest
        let result = try await ISHShellBridge.shared.execute(
            "umount '\(escapePath(guestPath))'"
        )
        guard result.success else {
            throw MountError.unmountFailed(
                guestPath: guestPath,
                reason: result.stderr.isEmpty
                    ? "umount 返回 \(result.exitCode)"
                    : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Remove from tables
        activeMounts.removeValue(forKey: mountID)
        guestPathIndex.removeValue(forKey: guestPath)
        hostPathIndex.removeValue(forKey: mount.hostPath)

        // Clean up mount point directory
        _ = try? await ISHShellBridge.shared.execute(
            "rmdir '\(escapePath(guestPath))' 2>/dev/null"
        )

        print("[BindMountService] ✅ 卸载成功: \(guestPath)")
    }

    // MARK: - Public API: Unmount All

    /// 卸载所有活跃挂载。
    ///
    /// 按挂载时间倒序卸载（后挂载的先卸载），避免嵌套挂载冲突。
    ///
    /// - Throws: ``MountError``（仅当引擎未初始化时抛出，单个卸载失败不中断）。
    func unmountAll() async throws {
        // ISHEngine is @MainActor, must await
        guard await ISHEngine.shared.isInitialized else {
            throw MountError.engineNotInitialized
        }

        print("[BindMountService] 卸载所有挂载 (共 \(mountCount) 个)...")

        // Unmount in reverse order (LIFO) for nested mounts
        let sortedMounts = activeMounts.values.sorted { $0.createdAt > $1.createdAt }

        var errors: [String] = []
        for mount in sortedMounts {
            do {
                try await unmount(guestPath: mount.guestPath)
            } catch {
                let msg = "\(mount.guestPath): \(error.localizedDescription)"
                errors.append(msg)
                print("[BindMountService] ⚠️ 卸载失败: \(msg)")
            }
        }

        if !errors.isEmpty {
            print("[BindMountService] ⚠️ 部分卸载失败: \(errors.joined(separator: "; "))")
        } else {
            print("[BindMountService] ✅ 所有挂载已卸载")
        }
    }

    // MARK: - Public API: Query

    /// 查询指定 guest 路径是否已挂载。
    func isMounted(guestPath: String) -> Bool {
        guestPathIndex[guestPath] != nil
    }

    /// 查询指定主机路径是否已挂载。
    func isHostMounted(hostPath: String) -> Bool {
        hostPathIndex[hostPath] != nil
    }

    /// 通过 guest 路径查找挂载记录。
    func mountForGuestPath(_ guestPath: String) -> BindMount? {
        guard let id = guestPathIndex[guestPath] else { return nil }
        return activeMounts[id]
    }

    /// 通过主机路径查找挂载记录。
    func mountForHostPath(_ hostPath: String) -> BindMount? {
        guard let id = hostPathIndex[hostPath] else { return nil }
        return activeMounts[id]
    }

    // MARK: - Helpers

    /// 转义路径中的特殊字符，防止 shell 注入。
    /// 使用单引号包裹并用 `'\''` 转义内嵌单引号。
    private func escapePath(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - RealFS Fallback (Static Registration)

    /// 使用 realfs C API 静态注册挂载（在 ISHShellBridge 初始化时）。
    ///
    /// 当 guest 内 `mount --bind` 因 fakefs 限制不可用时，回退到此方法。
    /// - Note: 静态注册的挂载需要在 ISHEngine 初始化阶段完成，
    ///   不支持运行时动态添加。
    func registerStaticMount(
        hostPath: String,
        guestPath: String,
        isReadOnly: Bool = false
    ) {
        print("[BindMountService] 静态注册 realfs 挂载: \(hostPath) → \(guestPath)")

        // realfs_bind_mount is declared in fs/real.h
        // The actual call depends on the libish build configuration.
        // For Phase 2, we register it in the mount table for tracking.
        let mount = BindMount(
            hostPath: hostPath,
            guestPath: guestPath,
            isReadOnly: isReadOnly
        )
        activeMounts[mount.id] = mount
        guestPathIndex[guestPath] = mount.id
        hostPathIndex[hostPath] = mount.id
    }
}

// MARK: - BindMountService Convenience Extensions

extension BindMountService {

    /// 批量挂载多个路径。
    /// - Parameter specs: 挂载规格数组 `[(host, guest, isReadOnly)]`。
    /// - Throws: 第一个遇到的 ``MountError``。
    func mountBatch(_ specs: [(host: String, guest: String, isReadOnly: Bool)]) async throws {
        for spec in specs {
            try await mount(
                hostPath: spec.host,
                guestPath: spec.guest,
                isReadOnly: spec.isReadOnly
            )
        }
    }

    /// 清理所有挂载并重置服务状态。
    func reset() async {
        _ = try? await unmountAll()
        activeMounts.removeAll()
        guestPathIndex.removeAll()
        hostPathIndex.removeAll()
    }
}
