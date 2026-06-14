import Foundation

// MARK: - ISHShellResult

/// Shell 执行结果（Phase 2: 基于 ISHShellExecutor）。
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
/// Phase 2: 基于 ISHShellExecutor ObjC API 实现真实 ish 内核内命令执行。
/// 替代了 Phase 1 的 SpawnRoot / chroot 方案。
actor ISHShellBridge {
    static let shared = ISHShellBridge()

    private var activePids: Set<Int32> = []

    // MARK: - Async Execute

    /// 在 ish guest 内异步执行命令。
    ///
    /// - Parameters:
    ///   - command: 待执行的 shell 命令（经 /bin/sh -c 执行）。
    ///   - lineCallback: 逐行输出回调 (line, isStderr)，可选。
    /// - Returns: ``ISHShellResult`` 包含退出码、PID、stdout/stderr 和耗时。
    /// - Throws: ``ISHShellError``。
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

        return try await withCheckedThrowingContinuation { continuation in
            let pid = ISHShellExecutor.executeCommand(
                trimmed,
                lineCallback: { line, isStderr in
                    lineCallback?(line, isStderr)
                },
                completion: { result in
                    let shellResult = ISHShellResult(
                        exitCode: Int32(result.exitCode),
                        pid: Int32(result.pid),
                        stdout: result.output ?? "",
                        stderr: result.errorOutput ?? "",
                        duration: result.duration
                    )
                    continuation.resume(returning: shellResult)
                }
            )

            if pid < 0 {
                let reason: String
                switch pid {
                case ISHShellExecutorError.processCreationFailed.rawValue:
                    reason = "进程创建失败"
                case ISHShellExecutorError.execFailed.rawValue:
                    reason = "exec 失败"
                case ISHShellExecutorError.cancelled.rawValue:
                    reason = "已取消"
                default:
                    reason = "ISHShellExecutor 错误码: \(pid)"
                }
                continuation.resume(throwing: ISHShellError.spawnFailed(reason: reason))
                return
            }

            // Track active PID (auto-removed when process exits).
            Task { [weak self] in
                await self?.trackPid(Int32(pid))
            }
        }
    }

    // MARK: - Sync Execute

    /// 同步执行命令（阻塞当前线程直到进程退出或超时）。
    ///
    /// - Parameters:
    ///   - command: 待执行的 shell 命令。
    ///   - timeout: 超时时间（秒），超过则抛出 ``ISHShellError/timeout``。
    /// - Returns: ``ISHShellResult``。
    /// - Throws: ``ISHShellError``。
    func executeSync(_ command: String, timeout: TimeInterval = 60) throws -> ISHShellResult {
        guard ISHEngine.shared.isInitialized else {
            throw ISHShellError.engineNotInitialized
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ISHShellError.commandEmpty
        }

        let result = ISHShellExecutor.executeCommandSync(
            trimmed,
            timeout: timeout,
            lineCallback: nil
        )

        guard result.error == ISHShellExecutorError.none else {
            switch result.error {
            case .timeout:
                throw ISHShellError.timeout
            case .cancelled:
                throw ISHShellError.processKilled(pid: Int32(result.pid))
            default:
                throw ISHShellError.spawnFailed(
                    reason: "ISHShellExecutor 错误: \(result.error.rawValue)"
                )
            }
        }

        return ISHShellResult(
            exitCode: Int32(result.exitCode),
            pid: Int32(result.pid),
            stdout: result.output ?? "",
            stderr: result.errorOutput ?? "",
            duration: result.duration
        )
    }

    // MARK: - Kill

    /// 向 guest 进程发送信号。
    /// - Parameters:
    ///   - pid: Guest 进程 PID。
    ///   - signal: 信号编号，默认 SIGKILL (9)。
    func kill(pid: Int32, signal: Int32 = 9 /* SIGKILL */) {
        ISHShellExecutor.killProcess(pid, withSignal: signal)
        activePids.remove(pid)
    }

    /// 杀死所有当前跟踪的活跃进程。
    func killAll() {
        for pid in activePids {
            ISHShellExecutor.killProcess(pid, withSignal: SIGKILL)
        }
        activePids.removeAll()
    }

    // MARK: - Private

    private func trackPid(_ pid: Int32) {
        activePids.insert(pid)
    }
}
