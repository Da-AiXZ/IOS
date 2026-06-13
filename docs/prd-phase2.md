# AgentBox Phase 2 PRD：TrollStore 集成 + ish 引擎初始化

| 属性 | 值 |
|------|-----|
| 版本 | 1.0 |
| 作者 | 许清楚（Xu），Product Manager |
| 日期 | 2025-07-17 |
| 语言 | 中文 |
| 编程语言 | Swift 5.0 (iOS 16.0+)，桥接 C/Obj-C |
| 项目 | AgentBox，ARM64 only，TrollStore 2 签名 |

---

## 1. 产品目标

1. **G1 — Root 执行可用**：从 AgentBox Swift 层以 UID=0 启动任意进程，并能捕获 stdout/stderr/exitCode。
2. **G2 — 无沙盒文件 IO**：App 可读写 iOS 文件系统中任意路径（不受 Container 限制），提供 Swift-native 文件操作 API。
3. **G3 — ish 引擎可启动**：Alpine Linux 3.21 aarch64 rootfs 成功解压 → ish 内核启动 → `echo "test" > /tmp/test.txt` 在 Linux guest 中执行成功，stdout 无错误。
4. **G4 — Shell 桥接可用**：Swift 层可通过 async/await 或同步阻塞方式在 Linux guest 中执行任意 shell 命令，获得结构化结果。
5. **G5 — 路径映射可用**：iOS 主机路径可挂载进 Linux guest 文件系统，guest 内文件变更对主机可见。

---

## 2. 用户故事

### US-1：Agent 在 Linux 环境中执行任务

> 作为 AI Agent，我需要在一个隔离的 Linux 容器中执行 shell 命令（安装 apt 包、运行 Python 脚本、操作文件），并且命令的 stdout/stderr 能实时流式回传，这样我能像 Claude Code 一样迭代式地完成任务。

**验收标准**：
- `ISHShellBridge.execute("apt-get update && apt-get install -y python3")` 返回 `exitCode == 0`
- `ISHShellBridge.execute("python3 -c 'print(1+1)'")` → `output == "2\n"`

### US-2：宿主文件与 Guest 共享

> 作为开发者，我需要把 iOS 文件系统中的某个目录（如 `/var/mobile/Documents/workspace`）挂载进 Linux guest（如 `/mnt/workspace`），这样 Agent 可以操作宿主上的项目文件，修改结果对 iOS 宿主层立即可见。

**验收标准**：
- `BindMountService.mount(host: "/var/mobile/Documents/workspace", guest: "/mnt/workspace")` 成功
- Guest 内 `ls /mnt/workspace` 显示与 iOS 宿主 `FileManager` 一致的文件列表
- Guest 内 `touch /mnt/workspace/new.txt` → 宿主 `FileManager.fileExists` 返回 true

---

## 3. 需求池

### P0（必须交付，Phase 2 不可发布项）

| ID | 模块 | 需求 | 可验证标准 |
|----|------|------|-----------|
| P0-1 | ISHEngine | Alpine rootfs.tar.gz 解压到 App 可写目录，调用 `actuate_kernel()` 启动 ish | `ISHEngine.shared.isInitialized == true`，ish 内核进程运行中 |
| P0-2 | ISHShellBridge | 包装 `ISHShellExecutor` C API 为 Swift async 接口 | `await bridge.execute("echo hello")` 返回 exitCode=0, output="hello" |
| P0-3 | SpawnRoot | `posix_spawn` + persona 以 UID=0 执行 iOS 原生命令 | `SpawnRoot.execute("whoami")` → stdout="root" |
| P0-4 | FileSystemAccess | 无沙盒文件读写（不依赖 FileManager delegate/entitlement 沙箱路径） | `FileSystemAccess.writeFile(at: "/tmp/agentbox-test", data: ...)` 成功 |
| P0-5 | E2E | `echo "test" > /tmp/test.txt` 在 guest 中执行并验证 | `cat /tmp/test.txt` 输出 "test" |

### P1（应该交付，Phase 2 发布必须有合理替代方案）

| ID | 模块 | 需求 | 可验证标准 |
|----|------|------|-----------|
| P1-1 | ISHShellBridge | 同步阻塞执行（带超时），用于不需要并发的场景 | `bridge.executeSync("sleep 1", timeout: 5)` 正常返回 |
| P1-2 | ISHShellBridge | 逐行流式回调，Agent 可实时看到命令输出 | lineCallback 在每行产生时被调用 |
| P1-3 | FileSystemAccess | 递归目录遍历、文件属性查询（大小/权限/修改时间） | `listDirectory` 不遗漏子项 |
| P1-4 | BindMountService | 单路径挂载：iOS 宿主路径 ↔ Linux guest 路径 | Guest 内 `ls /mnt/xxx` 与宿主一致 |
| P1-5 | ISHEngine | 初始化失败时抛出明确错误（rootfs 损坏/磁盘不足/内核异常） | 每种失败模式有独立 throw type |

### P2（锦上添花，Phase 2 可延后）

| ID | 模块 | 需求 |
|----|------|------|
| P2-1 | BindMountService | 多路径同时挂载 + 只读挂载选项 |
| P2-2 | ISHShellBridge | 多命令并行执行（多个独立 guest process） |
| P2-3 | SpawnRoot | 环境变量注入 + 工作目录设置 |
| P2-4 | FileSystemAccess | 原子写入（write-then-rename） |

---

## 4. 关键模块公开 API 签名草案

### 4.1 SpawnRoot

```swift
// File: src/Core/TrollStore/SpawnRoot.swift

import Foundation

/// 以 root (UID=0) 权限执行 iOS 原生进程的结果
struct SpawnResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let pid: pid_t
}

/// 以 root 身份 posix_spawn 执行命令。
/// 依赖 entitlements: no-sandbox + persona-mgmt。
enum SpawnRoot {
    /// 执行命令（通过 /bin/sh -c），返回完整结果。
    /// - Parameters:
    ///   - command: shell 命令字符串
    ///   - environment: 额外环境变量，nil 表示继承当前进程环境
    /// - Throws: SpawnError
    static func execute(
        _ command: String,
        environment: [String: String]? = nil
    ) throws -> SpawnResult

    /// 直接执行可执行文件（不经过 shell）。
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径
    ///   - arguments: 参数数组
    ///   - environment: 环境变量
    /// - Throws: SpawnError
    static func execute(
        executable: String,
        arguments: [String],
        environment: [String: String]?
    ) throws -> SpawnResult
}

enum SpawnError: Error {
    case spawnFailed(errno: Int32)
    case personaFailed(reason: String)
    case pipeError
}
```

### 4.2 FileSystemAccess

```swift
// File: src/Core/Utilities/FileSystemAccess.swift

import Foundation

/// 无沙盒文件系统操作包装器。
/// 使用 POSIX API（open/read/write/unlink/mkdir/rename），
/// 不经过 iOS Sandbox 路径检查。
enum FileSystemAccess {

    // MARK: 基本 IO
    static func readFile(at path: String) throws -> Data
    static func writeFile(at path: String, data: Data, createIntermediate: Bool) throws
    static func deleteFile(at path: String) throws
    static func fileExists(at path: String) -> Bool
    static func isDirectory(at path: String) -> Bool

    // MARK: 目录
    static func createDirectory(at path: String, withIntermediate: Bool) throws
    static func listDirectory(at path: String) throws -> [String]
    static func deleteDirectory(at path: String) throws

    // MARK: 移动/复制
    static func moveFile(from: String, to: String) throws
    static func copyFile(from: String, to: String) throws

    // MARK: 属性
    static func attributes(at path: String) throws -> FileAttributes
}

struct FileAttributes {
    let size: Int64
    let modificationDate: Date
    let creationDate: Date
    let isDirectory: Bool
    let permissions: Int16
}
```

### 4.3 ISHEngine

```swift
// File: src/Core/Harness/ISHEngine.swift

import Foundation

/// ish ARM64 Linux 模拟器引擎。
/// 单例，全局唯一内核实例。
final class ISHEngine {

    static let shared = ISHEngine()

    /// 引擎是否已成功初始化
    var isInitialized: Bool { get }

    /// 初始化引擎：解压 rootfs → 启动 ish 内核。
    ///
    /// - Parameter rootfsURL: Alpine rootfs.tar.gz 的本地文件 URL
    /// - Throws: EngineError 描述具体失败原因
    ///
    /// 幂等：重复调用不重复初始化。
    func initialize(rootfsURL: URL) throws
}

enum EngineError: Error {
    case rootfsNotFound
    case rootfsCorrupted(reason: String)
    case extractionFailed(underlying: Error)
    case kernelBootFailed(reason: String)
    case alreadyInitialized
    case notInitialized
}
```

### 4.4 ISHShellBridge

```swift
// File: src/Core/ISHBridge/ISHShellBridge.swift

import Foundation

/// Shell 执行结果（桥接 ISHShellExecutionResult）
struct ISHShellResult {
    let exitCode: Int32
    let pid: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
}

/// ish guest Shell 执行桥接器。
/// 包装 ISHShellExecutor C API（定义于 libish/app/ISHShellExecutor.h）。
final class ISHShellBridge {

    /// 异步执行 shell 命令（async/await）。
    /// - Parameters:
    ///   - command: 将通过 /bin/sh -c 执行的命令
    ///   - lineCallback: 每行输出回调（主队列），nil 表示不关心实时输出
    /// - Returns: 完整执行结果
    /// - Throws: ISHShellError
    func execute(
        _ command: String,
        lineCallback: ((_ line: String, _ isStderr: Bool) -> Void)? = nil
    ) async throws -> ISHShellResult

    /// 直接执行可执行文件（不经过 shell）。
    func execute(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        lineCallback: ((_ line: String, _ isStderr: Bool) -> Void)?
    ) async throws -> ISHShellResult

    /// 同步阻塞执行（带超时）。
    /// - Parameters:
    ///   - command: shell 命令
    ///   - timeout: 最大等待秒数，0 = 无限等待
    ///   - lineCallback: 每行输出回调
    /// - Returns: 完整执行结果
    func executeSync(
        _ command: String,
        timeout: TimeInterval = 0,
        lineCallback: ((_ line: String, _ isStderr: Bool) -> Void)? = nil
    ) -> ISHShellResult

    /// 终止运行中的 guest 进程。
    /// - Parameters:
    ///   - pid: 进程 PID（来自 execute 返回值）
    ///   - signal: 信号编号，默认 SIGKILL=9
    /// - Returns: 是否成功发送信号
    func kill(pid: Int32, signal: Int32 = 9) -> Bool
}

enum ISHShellError: Error {
    case engineNotInitialized
    case processCreationFailed
    case execFailed(reason: String)
    case timeout
    case cancelled
}
```

### 4.5 BindMountService

```swift
// File: src/Core/ISHBridge/BindMountService.swift

import Foundation

/// 单条挂载记录
struct BindMount {
    let id: UUID
    let hostPath: String
    let guestPath: String
    let isReadOnly: Bool
    let createdAt: Date
}

/// iOS 主机路径 ↔ Linux guest 路径绑定挂载服务。
/// 依赖 ish fakefs 的 bind mount 能力。
final class BindMountService {

    static let shared = BindMountService()

    /// 当前所有活跃挂载
    var mounts: [BindMount] { get }

    /// 将主机路径挂载到 guest 路径。
    /// - Parameters:
    ///   - hostPath: iOS 文件系统绝对路径
    ///   - guestPath: Linux guest 内绝对路径
    ///   - isReadOnly: 是否只读
    /// - Throws: MountError
    func mount(hostPath: String, guestPath: String, isReadOnly: Bool = false) throws

    /// 卸载指定 guest 路径。
    func unmount(guestPath: String) throws

    /// 卸载所有挂载。
    func unmountAll() throws
}

enum MountError: Error {
    case hostPathNotFound
    case guestPathInaccessible
    case alreadyMounted(existing: BindMount)
    case notMounted(guestPath: String)
    case engineNotInitialized
}
```

---

## 5. 待确认问题

| # | 问题 | 影响范围 |
|---|------|---------|
| Q1 | **persona 机制在 iOS 16.6.1 是否可用？** `posix_spawnattr_set_persona_np` 等 API 在 iOS 上并非公开 API，TrollStore 环境是否支持？若不可用，SpawnRoot 的备选方案是什么（如直接 `fork`+`setuid`+`exec`）？ | SpawnRoot |
| Q2 | **ish 内核启动时序**：`actuate_kernel()` 是否是同步调用？调用后 ISHShellExecutor 立即可用，还是需要等待某个回调/通知（如 `linux_start_session` 的 done block）？ | ISHEngine, ISHShellBridge |
| Q3 | **rootfs 解压目标路径**：解压到 App Container 内（`~/Documents/ish-rootfs/`）还是利用 `AppDataContainers` entitlement 放到共享路径（如 `/var/mobile/Documents/`）？影响磁盘占用和后续迁移。 | ISHEngine |
| Q4 | **ISHShellExecutor 对 ish AppDelegate 的依赖**：当前 `.m` 实现 import 了 `AppDelegate.h` 且依赖 `current` task、`ProcessExitedNotification`。作为 SwiftUI App（非 iSH 原版 AppDelegate），这些依赖如何满足？是否需要自己提供替代的 `current` task 和通知机制？ | ISHShellBridge |
| Q5 | **Bind mount 是否支持运行时动态挂载？** 当前 ish fakefs 的 bind mount 通常在根文件系统初始化时配置。是否支持 `mount()` syscall 在运行时从 iOS 层触发新的 bind mount？ | BindMountService |
| Q6 | **多进程并发安全**：ISHShellExecutor 的全局状态（`_activeExecutions`、通知观察）是否线程安全？是否支持多个 guest process 同时运行？ | ISHShellBridge |
| Q7 | **SpawnRoot 和 ISHShellBridge 的执行环境隔离**：SpawnRoot 在 iOS 原生环境执行，ISHShellBridge 在 ish Linux guest 执行。两者的文件路径空间不同，是否需要明确的设计文档说明调用方应选择哪个？ | 全模块 |

---

## 6. 里程碑与依赖关系

```
[ISHEngine.init] ──── 前置依赖 ──→ [ISHShellBridge] ──→ [E2E 验证]
                                        │
[SpawnRoot] ─── 无依赖（纯 iOS 原生）
[FileSystemAccess] ─── 无依赖（纯 iOS 原生）
[BindMountService] ─── 依赖 [ISHEngine.init]
```

- **里程碑 M1 (Day 1-3)**：SpawnRoot + FileSystemAccess 完成（可独立验证，不依赖 ish）
- **里程碑 M2 (Day 3-6)**：ISHEngine.init 完成（rootfs 解压 + 内核启动）
- **里程碑 M3 (Day 6-8)**：ISHShellBridge + BindMountService 完成
- **里程碑 M4 (Day 8-9)**：E2E 验证 + 缓冲

---

*本文档由 Alice (Product Manager) 产出，通过 SendMessage 回传主理人。*
