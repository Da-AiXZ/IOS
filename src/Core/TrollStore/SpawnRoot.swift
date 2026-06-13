import Foundation

// MARK: - SpawnResult

/// 以 root (UID=0) 权限执行 iOS 原生进程的结果。
struct SpawnResult: Sendable {
    /// 进程退出码。0 表示成功。
    let exitCode: Int32

    /// 标准输出数据（raw bytes）。
    let stdout: Data

    /// 标准错误数据（raw bytes）。
    let stderr: Data

    /// 子进程 PID。
    let pid: pid_t

    /// 便捷属性：是否成功执行。
    var success: Bool { exitCode == 0 }

    /// 将 stdout 解码为 UTF-8 字符串，解码失败返回空串。
    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    /// 将 stderr 解码为 UTF-8 字符串，解码失败返回空串。
    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

// MARK: - SpawnError

/// SpawnRoot 执行过程中可能出现的错误。
enum SpawnError: Error, LocalizedError {
    /// posix_spawn 调用失败，携带 errno 值。
    case spawnFailed(errno: Int32)

    /// persona 分配或设置失败，携带原因描述。
    case personaFailed(reason: String)

    /// 管道创建失败。
    case pipeError

    /// 命令字符串为空。
    case commandEmpty

    /// 可执行文件路径无效或不存在。
    case executableNotFound(path: String)

    /// 进程执行超时。
    case timeout(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let err):
            return "posix_spawn 失败，errno: \(err) (\(String(cString: strerror(err))))"
        case .personaFailed(let reason):
            return "Persona 操作失败: \(reason)"
        case .pipeError:
            return "管道创建失败"
        case .commandEmpty:
            return "命令字符串为空"
        case .executableNotFound(let path):
            return "可执行文件未找到: \(path)"
        case .timeout(let seconds):
            return "进程执行超时 (\(seconds) 秒)"
        }
    }
}

// MARK: - SpawnRoot

/// 以 root (UID=0) 权限执行 iOS 原生进程。
///
/// 依赖 TrollStore 的 `persona-mgmt` 和 `no-sandbox` 权限。
/// 优先使用 persona 机制分配 root persona 再 spawn；
/// persona 不可用时回退到 fork + setuid(0) + execve。
///
/// - Important: SpawnRoot 在 **iOS 原生 Darwin 环境** 执行命令，
///   路径空间是 iOS 文件系统（`/bin/sh` 是 Darwin shell），
///   **不是** ish Linux guest 环境。若需要在 Linux guest 中执行，
///   请使用 `ISHShellBridge`。
///
/// 使用示例：
/// ```swift
/// let result = try SpawnRoot.execute("whoami")
/// print(result.stdoutString) // "root\n"
/// ```
enum SpawnRoot {

    // MARK: - Public API: Shell Command

    /// 执行 shell 命令（通过 `/bin/sh -c`），返回完整结果。
    ///
    /// - Parameters:
    ///   - command: shell 命令字符串。
    ///   - environment: 额外环境变量字典。nil 表示继承当前进程环境。
    ///   - timeout: 可选超时秒数。nil 表示无限等待。
    /// - Returns: ``SpawnResult`` 包含 exitCode、stdout、stderr、pid。
    /// - Throws: ``SpawnError`` 描述具体失败原因。
    static func execute(
        _ command: String,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> SpawnResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpawnError.commandEmpty
        }

        print("[SpawnRoot] 执行命令: \(trimmed.prefix(200))")

        // Build argv
        var args: [String] = ["/bin/sh", "-c", trimmed]

        // Build envp from current + overrides
        var envDict = ProcessInfo.processInfo.environment
        // Ensure minimal PATH for root context
        envDict["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        if let extras = environment {
            for (key, value) in extras {
                envDict[key] = value
            }
        }

        // Try persona path first, fallback to fork
        do {
            return try executeViaPersona(
                executable: "/bin/sh",
                arguments: args,
                environment: envDict,
                timeout: timeout
            )
        } catch SpawnError.personaFailed(let reason) {
            print("[SpawnRoot] Persona 路径失败 (\(reason))，回退到 fork 路径")
            return try executeViaFork(
                executable: "/bin/sh",
                arguments: args,
                environment: envDict,
                timeout: timeout
            )
        }
    }

    // MARK: - Public API: Direct Executable

    /// 直接执行可执行文件（不经过 shell）。
    ///
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径。
    ///   - arguments: 参数数组（不含 argv[0]，自动设置）。
    ///   - environment: 环境变量字典。nil 表示继承当前进程环境。
    ///   - timeout: 可选超时秒数。
    /// - Returns: ``SpawnResult``。
    /// - Throws: ``SpawnError``。
    static func execute(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> SpawnResult {
        guard !executable.isEmpty else {
            throw SpawnError.commandEmpty
        }

        // Check executable exists — use POSIX API to bypass sandbox
        guard FileSystemAccess.fileExists(at: executable) else {
            throw SpawnError.executableNotFound(path: executable)
        }

        print("[SpawnRoot] 直接执行: \(executable) \(arguments.joined(separator: " "))")

        // Build env dict
        var envDict = ProcessInfo.processInfo.environment
        envDict["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        if let extras = environment {
            for (key, value) in extras {
                envDict[key] = value
            }
        }

        // argv[0] = executable path
        var args = [executable]
        args.append(contentsOf: arguments)

        // Try persona path first
        do {
            return try executeViaPersona(
                executable: executable,
                arguments: args,
                environment: envDict,
                timeout: timeout
            )
        } catch SpawnError.personaFailed(let reason) {
            print("[SpawnRoot] Persona 路径失败 (\(reason))，回退到 fork 路径")
            return try executeViaFork(
                executable: executable,
                arguments: args,
                environment: envDict,
                timeout: timeout
            )
        }
    }

    // MARK: - Persona Path

    /// 使用 persona 机制以 UID=0 执行进程。
    private static func executeViaPersona(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) throws -> SpawnResult {

        // 1. Allocate root persona
        var personaId: UInt32 = 0
        let allocResult = agentbox_persona_alloc_root(&personaId)
        guard allocResult == 0 else {
            let reason = "kpersona_alloc 失败，errno: \(errno) (\(String(cString: strerror(errno))))"
            throw SpawnError.personaFailed(reason: reason)
        }
        defer {
            // Do NOT dealloc until child finishes
            // agentbox_persona_dealloc(personaId) handled after wait
        }

        // 2. Prepare C arrays for posix_spawn
        var cArgs = arguments.map { strdup($0) }
        cArgs.append(nil) // NULL terminate
        defer { cArgs.forEach { free($0) } }

        // Build envp as ["KEY=VALUE", ...] + nil
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var cEnv = envStrings.map { strdup($0) }
        cEnv.append(nil)
        defer { cEnv.forEach { free($0) } }

        // 3. Spawn with persona
        var stdoutFd: Int32 = -1
        var stderrFd: Int32 = -1
        var pid: pid_t = 0

        let spawnResult = agentbox_spawn_with_persona(
            personaId,
            executable,
            &cArgs,
            &cEnv,
            &stdoutFd,
            &stderrFd,
            &pid
        )

        guard spawnResult == 0 else {
            agentbox_persona_dealloc(personaId)
            throw SpawnError.spawnFailed(errno: errno)
        }

        // 4. Read output and wait for child
        return try readOutputAndWait(
            stdoutFd: stdoutFd,
            stderrFd: stderrFd,
            pid: pid,
            timeout: timeout,
            cleanup: { agentbox_persona_dealloc(personaId) }
        )
    }

    // MARK: - Fork Fallback

    /// Fork + setuid(0) + execve 回退路径。
    private static func executeViaFork(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) throws -> SpawnResult {

        // Prepare C arrays
        var cArgs = arguments.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var cEnv = envStrings.map { strdup($0) }
        cEnv.append(nil)
        defer { cEnv.forEach { free($0) } }

        var stdoutFd: Int32 = -1
        var stderrFd: Int32 = -1
        var pid: pid_t = 0

        let forkResult = agentbox_fork_root_spawn(
            executable,
            &cArgs,
            &cEnv,
            &stdoutFd,
            &stderrFd,
            &pid
        )

        guard forkResult == 0 else {
            throw SpawnError.spawnFailed(errno: errno)
        }

        return try readOutputAndWait(
            stdoutFd: stdoutFd,
            stderrFd: stderrFd,
            pid: pid,
            timeout: timeout,
            cleanup: { /* no persona to dealloc */ }
        )
    }

    // MARK: - Output Reading

    /// Read stdout/stderr from pipes, wait for child, return SpawnResult.
    private static func readOutputAndWait(
        stdoutFd: Int32,
        stderrFd: Int32,
        pid: pid_t,
        timeout: TimeInterval?,
        cleanup: @escaping () -> Void
    ) throws -> SpawnResult {
        defer { cleanup() }

        let stdoutData = readAllFromFD(stdoutFd)
        let stderrData = readAllFromFD(stderrFd)

        close(stdoutFd)
        close(stderrFd)

        // Wait for child with optional timeout
        let exitCode: Int32
        if let timeout = timeout {
            exitCode = try waitWithTimeout(pid: pid, timeout: timeout)
        } else {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1
        }

        return SpawnResult(
            exitCode: exitCode,
            stdout: stdoutData,
            stderr: stderrData,
            pid: pid
        )
    }

    /// Read all available data from a file descriptor.
    private static func readAllFromFD(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }

        return data
    }

    /// Wait for a child process with timeout using WNOHANG polling.
    private static func waitWithTimeout(pid: pid_t, timeout: TimeInterval) throws -> Int32 {
        let deadline = Date().timeIntervalSince1970 + timeout
        let pollInterval: TimeInterval = 0.05 // 50ms

        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)

            if result == pid {
                // Child exited
                return WIFEXITED(status) ? WEXITSTATUS(status) : -1
            } else if result == -1 {
                // Error (e.g., no such process)
                return -1
            }

            // Check timeout
            if Date().timeIntervalSince1970 > deadline {
                // Kill the child process on timeout
                kill(pid, SIGKILL)
                var status: Int32 = 0
                waitpid(pid, &status, 0) // Reap the killed child
                throw SpawnError.timeout(seconds: timeout)
            }

            // Sleep briefly before polling again
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}
