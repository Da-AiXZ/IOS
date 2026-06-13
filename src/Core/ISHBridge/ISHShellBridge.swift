import Foundation

// MARK: - ISHShellResult

/// Shell 执行结果（桥接 ISHShellExecutor 的 ISHShellExecutionResult）。
struct ISHShellResult: Sendable {
    /// 进程退出码。0 表示成功。
    let exitCode: Int32

    /// Guest 内进程 PID。
    let pid: Int32

    /// 标准输出（UTF-8 字符串）。
    let stdout: String

    /// 标准错误（UTF-8 字符串）。
    let stderr: String

    /// 命令执行耗时（秒）。
    let duration: TimeInterval

    /// 便捷属性：是否成功执行。
    var success: Bool { exitCode == 0 }

    /// 合并 stdout 和 stderr。
    var combinedOutput: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }
}

// MARK: - ISHShellError

/// ISHShellBridge 执行过程中可能出现的错误。
enum ISHShellError: Error, LocalizedError {
    /// ISHEngine 尚未初始化。
    case engineNotInitialized

    /// 进程创建失败（ISHShellExecutor 返回 invalid pid）。
    case processCreationFailed

    /// exec 失败（在 guest 内执行命令失败）。
    case execFailed(reason: String)

    /// 执行超时。
    case timeout

    /// 执行被取消。
    case cancelled

    /// 未知错误，携带原始错误码。
    case unknown(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .engineNotInitialized:
            return "ish 引擎尚未初始化"
        case .processCreationFailed:
            return "Guest 进程创建失败"
        case .execFailed(let reason):
            return "Guest 内命令执行失败: \(reason)"
        case .timeout:
            return "命令执行超时"
        case .cancelled:
            return "命令执行已取消"
        case .unknown(let code):
            return "未知错误 (code: \(code))"
        }
    }
}

// MARK: - ProcessHandle

/// Guest 进程句柄，追踪单个活跃执行。
private struct ProcessHandle: Sendable {
    let pid: Int32
    let startTime: Date
    var isCancelled: Bool = false
}

// MARK: - ISHShellBridge

/// ish guest Shell 执行桥接器。
///
/// 包装 ISHShellExecutor C API（定义于 ish 的 `ISHShellExecutor.h`），
/// 提供 Swift-native async/await 接口在 Linux guest 中执行命令。
///
/// - Important: ISHShellBridge 在 **ish Linux guest** 中执行命令，
///   路径空间是 Linux 文件系统（`/root/`、`/tmp/` 等），
///   **不是** iOS 原生文件系统。若需要在 iOS 原生环境执行，请使用 `SpawnRoot`。
///
/// 使用示例：
/// ```swift
/// let bridge = ISHShellBridge.shared
/// let result = try await bridge.execute("echo 'Hello from Linux'")
/// print(result.stdout) // "Hello from Linux\n"
/// ```
actor ISHShellBridge {

    // MARK: - Singleton

    /// 共享实例（便利访问）。
    static let shared = ISHShellBridge()

    // MARK: - Active Process Tracking

    /// 当前活跃的 guest 进程映射（pid → handle）。
    private var activeProcesses: [Int32: ProcessHandle] = [:]

    /// 进程 ID 计数器（用于生成本地追踪 ID）。
    private var nextLocalPID: Int32 = 1000

    // MARK: - Public API: Async Execute (Shell Command)

    /// 异步执行 shell 命令（通过 `/bin/sh -c`）。
    ///
    /// - Parameters:
    ///   - command: 将通过 `/bin/sh -c` 执行的命令字符串。
    ///   - lineCallback: 每行输出回调。`nil` 表示不关心实时输出。
    ///     回调在后台线程执行，参数 `(line: String, isStderr: Bool)`。
    /// - Returns: ``ISHShellResult`` 完整执行结果。
    /// - Throws: ``ISHShellError``。
    func execute(
        _ command: String,
        lineCallback: ((_ line: String, _ isStderr: Bool) -> Void)? = nil
    ) async throws -> ISHShellResult {
        // Validate engine state — ISHEngine is @MainActor, must await
        guard await ISHEngine.shared.isInitialized else {
            throw ISHShellError.engineNotInitialized
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty command → return success with empty output
            return ISHShellResult(
                exitCode: 0, pid: 0, stdout: "", stderr: "", duration: 0
            )
        }

        print("[ISHShellBridge] 执行: \(trimmed.prefix(200))")
        let startTime = Date()

        // Bridge to ISHShellExecutor C API via continuation
        return try await withCheckedThrowingContinuation { continuation in
            // ISHShellExecutor.executeCommand is a C function exposed via
            // the Bridging Header. It accepts:
            //   - command: NSString
            //   - lineCallback: (NSString, BOOL) -> Void
            //   - completion: (ISHShellExecutionResult *) -> Void
            //
            // Returns: pid (Int32), or -1 on failure.

            let pid = ish_execute_command(
                trimmed,
                { line, isStderr in
                    // Line callback — deliver on a consistent queue
                    if let callback = lineCallback {
                        DispatchQueue.main.async {
                            callback(line, isStderr)
                        }
                    }
                },
                { result in
                    // Completion callback — result is ISHShellExecutionResult ObjC object
                    let duration = Date().timeIntervalSince(startTime)

                    // Remove from active processes
                    let pid = Int32(result.pid)
                    self.removeProcess(pid: pid)

                    let shellResult = ISHShellResult(
                        exitCode: Int32(result.exitCode),
                        pid: Int32(result.pid),
                        stdout: result.output ?? "",
                        stderr: result.errorOutput ?? "",
                        duration: duration
                    )

                    print("[ISHShellBridge] 命令完成: exitCode=\(result.exitCode), "
                          + "耗时=\(String(format: "%.3f", duration))s")
                    continuation.resume(returning: shellResult)
                }
            )

            if pid < 0 {
                // Process creation failed
                continuation.resume(throwing: ISHShellError.processCreationFailed)
            } else {
                // Track the process
                self.trackProcess(pid: pid)
            }
        }
    }

    // MARK: - Public API: Async Execute (Direct Executable)

    /// 直接执行可执行文件（不经过 shell）。
    ///
    /// - Parameters:
    ///   - executable: Guest 内可执行文件绝对路径（如 `/usr/bin/python3`）。
    ///   - arguments: 参数数组（不含 argv[0]）。
    ///   - environment: 环境变量字典。nil 表示使用默认环境。
    ///   - lineCallback: 逐行输出回调。
    /// - Returns: ``ISHShellResult``。
    /// - Throws: ``ISHShellError``。
    func execute(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        lineCallback: ((_ line: String, _ isStderr: Bool) -> Void)? = nil
    ) async throws -> ISHShellResult {
        // Build a shell command that sets env vars and executes the binary
        var cmdParts: [String] = []

        if let env = environment, !env.isEmpty {
            for (key, value) in env {
                cmdParts.append("export \(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'")
            }
        }

        let argsQuoted = arguments.map { arg in
            "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        cmdParts.append("'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' \(argsQuoted.joined(separator: " "))")

        let fullCommand = cmdParts.joined(separator: "; ")
        return try await execute(fullCommand, lineCallback: lineCallback)
    }

    // MARK: - Public API: Synchronous Execute

    /// 同步阻塞执行（带超时）。
    ///
    /// - Parameters:
    ///   - command: shell 命令字符串。
    ///   - timeout: 最大等待秒数。0 = 无限等待。
    ///   - lineCallback: 逐行输出回调。
    /// - Returns: ``ISHShellResult``。
    /// - Throws: ``ISHShellError``（包括 `.timeout`）。
    func executeSync(
        _ command: String,
        timeout: TimeInterval = 0,
        lineCallback: ((_ line: String, _ isStderr: Bool) -> Void)? = nil
    ) throws -> ISHShellResult {
        // Access @MainActor ISHEngine.shared.isInitialized via semaphore bridge
        let initSem = DispatchSemaphore(value: 0)
        var engineReady = false
        Task { @MainActor in
            engineReady = ISHEngine.shared.isInitialized
            initSem.signal()
        }
        initSem.wait()

        guard engineReady else {
            throw ISHShellError.engineNotInitialized
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ISHShellResult(exitCode: 0, pid: 0, stdout: "", stderr: "", duration: 0)
        }

        print("[ISHShellBridge] 同步执行: \(trimmed.prefix(200))")
        let startTime = Date()

        // Use ISHShellExecutor's synchronous API if available,
        // otherwise fall back to semaphore-based async bridge.
        let semaphore = DispatchSemaphore(value: 0)
        var shellResult: ISHShellResult?

        let pid = ish_execute_command(
            trimmed,
            { line, isStderr in
                if let callback = lineCallback {
                    DispatchQueue.main.async {
                        callback(line, isStderr)
                    }
                }
            },
            { result in
                let duration = Date().timeIntervalSince(startTime)
                self.removeProcess(pid: Int32(result.pid))

                shellResult = ISHShellResult(
                    exitCode: Int32(result.exitCode),
                    pid: Int32(result.pid),
                    stdout: result.output ?? "",
                    stderr: result.errorOutput ?? "",
                    duration: duration
                )
                semaphore.signal()
            }
        )

        if pid < 0 {
            throw ISHShellError.processCreationFailed
        }
        trackProcess(pid: pid)

        // Wait with optional timeout
        if timeout > 0 {
            let waitResult = semaphore.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                // Kill the process
                _ = kill(pid: pid, signal: SIGKILL)
                removeProcess(pid: pid)
                throw ISHShellError.timeout
            }
        } else {
            semaphore.wait()
        }

        // Return result or fallback (shellError variable removed — Bug 7: dead code)
        return shellResult ?? ISHShellResult(
            exitCode: -1, pid: pid, stdout: "", stderr: "执行异常中断", duration: 0
        )
    }

    // MARK: - Public API: Kill

    /// 终止运行中的 guest 进程。
    ///
    /// - Parameters:
    ///   - pid: 进程 PID（来自 execute 返回值的 `pid` 字段）。
    ///   - signal: 信号编号。默认 `SIGKILL` (9)。
    /// - Returns: `true` 如果成功发送信号。
    func kill(pid: Int32, signal: Int32 = SIGKILL) -> Bool {
        print("[ISHShellBridge] 终止进程 pid=\(pid), signal=\(signal)")

        // Call ISHShellExecutor C API
        let result = ish_kill_process(pid, signal)
        if result {
            removeProcess(pid: pid)
        }
        return result
    }

    /// 终止所有活跃的 guest 进程。
    func killAll() {
        let pids = activeProcesses.keys
        for pid in pids {
            _ = kill(pid: pid, signal: SIGKILL)
        }
    }

    // MARK: - Process Tracking

    private func trackProcess(pid: Int32) {
        activeProcesses[pid] = ProcessHandle(pid: pid, startTime: Date())
    }

    private func removeProcess(pid: Int32) {
        activeProcesses.removeValue(forKey: pid)
    }

    /// 当前活跃进程数。
    var activeProcessCount: Int {
        activeProcesses.count
    }
}

// MARK: - ISHShellExecutor C Bridge

/// C function declarations bridged via @_silgen_name to the Obj-C methods
/// defined in ISHShellExecutor.h (ish-arm64).

/// Execute a shell command in the ish Linux guest.
///
/// Mirrors: `+[ISHShellExecutor executeCommand:lineCallback:completion:]`
///
/// - Parameters:
///   - command: Shell command string.
///   - lineCallback: Called for each line of output (line: String, isStderr: Bool).
///   - completion: Called when the process exits with ISHShellExecutionResult *.
///     **Must accept ISHShellExecutionResult (ObjC class), matching the C ABI.**
/// - Returns: Process PID (Int32), or -1 on failure.
@_silgen_name("ISHShellExecutor_executeCommand")
private func ish_execute_command(
    _ command: String,
    _ lineCallback: @escaping @convention(block) (String, Bool) -> Void,
    _ completion: @escaping @convention(block) (ISHShellExecutionResult) -> Void
) -> Int32

/// Kill a process in the ish Linux guest.
///
/// Mirrors: `+[ISHShellExecutor killProcess:withSignal:]`
///
/// - Parameters:
///   - pid: Process ID (Int32).
///   - signal: Signal number (Int32, e.g., SIGKILL = 9).
/// - Returns: Bool — true if signal was sent successfully.
@_silgen_name("ISHShellExecutor_killProcess")
private func ish_kill_process(_ pid: Int32, _ signal: Int32) -> Bool

// MARK: - ISHShellBridge Convenience Extensions

extension ISHShellBridge {

    /// 检查引擎是否可用，不可用则抛出错误。
    func validateReady() throws {
        // Access @MainActor ISHEngine.shared.isInitialized via semaphore bridge
        let initSem = DispatchSemaphore(value: 0)
        var engineReady = false
        Task { @MainActor in
            engineReady = ISHEngine.shared.isInitialized
            initSem.signal()
        }
        initSem.wait()

        guard engineReady else {
            throw ISHShellError.engineNotInitialized
        }
    }
}
