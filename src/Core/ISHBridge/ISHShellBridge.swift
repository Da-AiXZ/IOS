import Foundation

// MARK: - ISHShellResult

/// Shell 执行结果（Phase 2 stub: 使用 SpawnRoot, 后续集成 ISHShellExecutor）。
struct ISHShellResult: Sendable {
    let exitCode: Int32
    let pid: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
}

// MARK: - ISHShellError

enum ISHShellError: Error, LocalizedError {
    case engineNotInitialized
    case commandEmpty
    case spawnFailed(reason: String)
    case processKilled(pid: Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .engineNotInitialized: return "ish 引擎尚未初始化"
        case .commandEmpty: return "命令为空"
        case .spawnFailed(let r): return "进程启动失败: \(r)"
        case .processKilled(let p): return "进程 \(p) 已被终止"
        case .timeout: return "命令执行超时"
        }
    }
}

// MARK: - ISHShellBridge

/// Linux guest Shell 执行桥接。
///
/// Phase 2: 基于 SpawnRoot 实现 (通过 chroot 到 Alpine rootfs 执行)。
/// 后续阶段集成 ish-arm64 的 ISHShellExecutor ObjC API 以获得完整终端模拟。
actor ISHShellBridge {
    static let shared = ISHShellBridge()

    private var activePids: Set<Int32> = []

    // MARK: - Async Execute

    func execute(
        _ command: String,
        lineCallback: ((String, Bool) -> Void)? = nil
    ) async throws -> ISHShellResult {
        guard await ISHEngine.shared.isInitialized else {
            throw ISHShellError.engineNotInitialized
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ISHShellError.commandEmpty
        }

        let startTime = Date()
        let fullCommand = buildChrootCommand(trimmed)
        _ = lineCallback  // TODO: streaming via pipe when ISHShellExecutor integrated

        let result = try SpawnRoot.execute(fullCommand, timeout: 60)
        activePids.remove(Int32(result.pid))

        return ISHShellResult(
            exitCode: result.exitCode,
            pid: Int32(result.pid),
            stdout: result.stdoutString,
            stderr: result.stderrString,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Sync Execute

    func executeSync(_ command: String, timeout: TimeInterval = 60) throws -> ISHShellResult {
        var result: ISHShellResult?
        var error: Error?

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                result = try await execute(command)
            } catch let e {
                error = e
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            throw ISHShellError.timeout
        }
        if let error = error { throw error }
        return result!
    }

    // MARK: - Kill

    func kill(pid: Int32, signal: Int32 = 9 /* SIGKILL */) {
        Darwin.kill(pid, signal)
        activePids.remove(pid)
    }

    func killAll() {
        for pid in activePids {
            Darwin.kill(pid, SIGKILL)
        }
        activePids.removeAll()
    }

    // MARK: - Private

    /// Build a chroot command that runs inside the Alpine rootfs.
    /// Uses the rootfs path from ISHEngine.
    private func buildChrootCommand(_ command: String) -> String {
        // Phase 2 stub: execute directly via SpawnRoot in Darwin context.
        // Full chroot integration requires ish kernel to be running.
        // TODO: Replace with `/bin/sh -c "chroot <rootfs> /bin/sh -c '<command>'"`
        // once ISHShellExecutor is integrated.
        return command
    }
}
