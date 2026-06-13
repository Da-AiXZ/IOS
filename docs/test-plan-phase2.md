# AgentBox Phase 2 — 测试用例规格

| 属性 | 值 |
|------|-----|
| 版本 | 1.0 |
| 作者 | 严过关 (Edward)，QA Engineer |
| 日期 | 2025-07-17 |
| 目标 | iOS 16.6.1, ARM64, TrollStore 2 |
| 依据 | PRD Phase 2 + Architecture Phase 2 + 10 文件源码审查 |

---

## 一、测试策略概述

由于是在 iOS 上运行且无法在标准 XCTest 环境中执行（依赖 TrollStore entitlements），本规格文档为每个模块定义**可手动执行**的验证用例和**可自动化**的单元测试用例设计。

- **单元测试**：验证函数级别行为、状态机转换、错误映射
- **集成测试**：验证跨模块协作（如 ISHEngine → ISHShellBridge → BindMountService）
- **边界测试**：空输入、极限值、并发冲突
- **错误路径测试**：每个 throw 路径必须有对应测试用例

---

## 二、模块测试用例

### 2.1 PersonaSpawn.c（C 层测试）

> **测试环境**：需要在 TrollStore 签名的 App 中调用，可通过 SpawnRoot Swift 层间接测试。

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| C-01 | `agentbox_persona_alloc_root` — 正常分配 | 传入有效 `out_persona_id` 指针 | 返回 0，`*out_persona_id` > 0 | P0 |
| C-02 | `agentbox_persona_alloc_root` — NULL 指针 | `out_persona_id = NULL` | 返回 -1，`errno = EINVAL` | P1 |
| C-03 | `agentbox_persona_dealloc` — 正常释放 | 传入已分配的 persona_id | 返回 0 | P0 |
| C-04 | `agentbox_persona_dealloc` — 无效 ID | 传入不存在的 persona_id (如 99999) | 返回 -1，`errno != 0` | P1 |
| C-05 | `agentbox_spawn_with_persona` — 正常 spawn | 有效 persona_id + "/bin/sh" + ["-c", "echo ok"] | 返回 0，stdout pipe 读到 "ok\n" | P0 |
| C-06 | `agentbox_spawn_with_persona` — 空参数 | `binary_path = NULL` | 返回 -1，`errno = EINVAL` | P1 |
| C-07 | `agentbox_spawn_with_persona` — 无效 binary | 指向不存在的路径 | 返回 -1，`errno != 0` | P1 |
| C-08 | `agentbox_spawn_root_simple` — 正常执行 | `command = "whoami"` | 返回 0，stdout 包含 "root"，exit_code = 0 | P0 |
| C-09 | `agentbox_spawn_root_simple` — malloc 失败模拟 | 注入 OOM 条件（需 mock） | 返回 -1，`errno = ENOMEM`，无内存泄漏 | P2 |
| C-10 | `agentbox_fork_root_spawn` — 正常 fork | 有效 binary_path + argv | 返回 0，子进程以 UID=0 执行 | P0 |
| C-11 | `agentbox_fork_root_spawn` — fork 失败模拟 | 注入 fork 返回 -1（需 mock） | 返回 -1，pipes 已正确关闭 | P2 |
| C-12 | `agentbox_boot_ish_kernel` — 正常启动 | 传入有效 rootfs 路径 | 返回 0 | P0 |
| C-13 | `agentbox_boot_ish_kernel` — NULL 路径 | `root_path = NULL` | 返回 -1，`errno = EINVAL` | P1 |
| C-14 | `agentbox_boot_ish_kernel` — 无效路径 | 传入不存在的目录 | 返回 -1，`errno = ENOENT` | P1 |

### 2.2 SpawnRoot.swift

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| SR-01 | `execute("whoami")` — persona 路径 | persona 可用 | 返回 `SpawnResult(exitCode=0, stdoutString="root")` | P0 |
| SR-02 | `execute("whoami")` — fork fallback | persona 不可用（模拟 `personaFailed`） | 自动走 fork 路径，同样返回 exitCode=0 | P0 |
| SR-03 | `execute("")` — 空命令 | 传入空字符串 | `throw SpawnError.commandEmpty` | P1 |
| SR-04 | `execute("   ")` — 仅空白 | 传入仅空白的字符串 | `throw SpawnError.commandEmpty` | P1 |
| SR-05 | `execute("sleep 10", timeout: 1)` — 超时 | 命令运行超过设定的超时 | `throw SpawnError.timeout(seconds: 1)` | P0 |
| SR-06 | `execute("sleep 0.1", timeout: 5)` — 不超时 | 命令在超时前完成 | 正常返回，exitCode=0 | P1 |
| SR-07 | `execute(executable: "/bin/ls", arguments: ["/tmp"])` | 直接可执行文件路径 | 返回 stdout 包含目录列表 | P0 |
| SR-08 | `execute(executable: "/nonexistent/binary")` | 可执行文件不存在 | `throw SpawnError.executableNotFound(path:)` | P1 |
| SR-09 | `execute("env", environment: ["FOO": "BAR"])` | 带自定义环境变量 | stdout 包含 "FOO=BAR" | P1 |
| SR-10 | `execute("ls /root")` — 验证 UID=0 | 读取通常无权限的目录 | stdout 非空（root 权限验证） | P0 |
| SR-11 | stdoutString 解码 — 正常 UTF-8 | stdout 包含有效 UTF-8 | 正确解码为 String | P2 |
| SR-12 | stdoutString 解码 — 非 UTF-8 | stdout 是二进制数据 | 返回 `""`，不崩溃 | P2 |
| SR-13 | 并发执行 — 多个独立命令 | 同时执行 3 个不同命令 | 每个都返回正确结果，无 data race | P2 |
| SR-14 | `SpawnError` 描述字符串 | 每个 case | `errorDescription` 非空，包含有用诊断信息 | P2 |

### 2.3 FileSystemAccess.swift

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| FS-01 | `writeFile` → `readFile` → 内容一致 | 写入 "Hello World" 到 /tmp/fs-test.txt | 读回 "Hello World" | P0 |
| FS-02 | `writeFile` 自动创建父目录 | 路径 `/tmp/a/b/c/test.txt`，父目录不存在 | 文件写入成功，中间目录被创建 | P0 |
| FS-03 | `writeFile` → `deleteFile` → `fileExists`=false | 写入后删除 | `fileExists` 返回 false | P0 |
| FS-04 | `readFile` — 文件不存在 | 读取不存在的路径 | `throw FileSystemError.fileNotFound` | P1 |
| FS-05 | `readFile` — 空路径 | `path = ""` | `throw FileSystemError.emptyPath` | P1 |
| FS-06 | `writeFile` — 空路径 | `path = ""` | `throw FileSystemError.emptyPath` | P1 |
| FS-07 | `createDirectory` — 递归创建 | 路径 `/tmp/dir-a/dir-b/dir-c` | 所有层级都被创建 | P0 |
| FS-08 | `createDirectory` — 路径指向文件 | 路径指向已有文件 | `throw FileSystemError.notDirectory` | P1 |
| FS-09 | `listDirectory` — 正常目录 | 含多个文件和子目录 | 返回所有文件名（不含 `.` `..`） | P0 |
| FS-10 | `listDirectory` — 空目录 | 空目录 | 返回 `[]` | P1 |
| FS-11 | `listDirectory` — 路径不存在 | 不存在的路径 | `throw FileSystemError.fileNotFound` | P1 |
| FS-12 | `deleteDirectory` — 递归删除 | 含文件和子目录的目录 | 全部删除，路径不存在 | P0 |
| FS-13 | `moveFile` — 重命名 | from `/tmp/a.txt` to `/tmp/b.txt` | 原路径不存在，新路径存在且内容一致 | P0 |
| FS-14 | `moveFile` — 跨目录移动 | from `/tmp/a.txt` to `/tmp/sub/b.txt` | 自动创建目标父目录 | P1 |
| FS-15 | `copyFile` — 正常复制 | 复制文件到新路径 | 两路径内容一致 | P0 |
| FS-16 | `attributes` — 正常文件 | 已知文件 | size 正确，isDirectory=false | P0 |
| FS-17 | `attributes` — 符号链接 | 指向文件的 symlink | isSymlink=true，isDirectory=false | P1 |
| FS-18 | `attributes` — 不存在的路径 | 不存在路径 | `throw FileSystemError.fileNotFound` | P1 |
| FS-19 | `fileExists` — 存在/不存在 | 两种场景 | 正确返回 true/false | P1 |
| FS-20 | `isDirectory` — 文件/目录/symlink | 三种场景 | 正确区分 | P1 |
| FS-21 | `FileSystemError.fromErrno` 映射 | 每个 errno (ENOENT, EACCES, ENOSPC, EEXIST, ENOTDIR, EISDIR, EINTR, EIO) | 映射到正确的 case | P0 |
| FS-22 | `writeString` → `readString` | 写入/读取 UTF-8 字符串 | 字符串一致 | P0 |
| FS-23 | `readString` — 非 UTF-8 数据 | 读取二进制文件 | `throw FileSystemError.systemError(errno: EILSEQ)` | P1 |
| FS-24 | `fileSize` — 已知大小 | 写入 1024 字节文件 | 返回 1024 | P1 |
| FS-25 | `fileSize` — 不存在 | 不存在的路径 | 返回 nil，不抛异常 | P1 |
| FS-26 | `directorySize` — 递归计算 | 含文件和子目录 | 总大小等于所有文件大小之和 | P1 |
| FS-27 | 大文件（>64KB）写入/读取 | 写入 1MB 数据 | 读回完全一致 | P1 |
| FS-28 | 特殊字符路径 | 路径含空格、中文、emoji | 操作成功 | P2 |
| FS-29 | `/var/root/` 路径写入 | 需要 root 权限的路径 | 需 SpawnRoot 配合，写入成功（验证无沙盒） | P0 |

### 2.4 ISHEngine.swift

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| EN-01 | 首次初始化 — 完整流程 | rootfs.tar.gz 存在，磁盘充足 | 状态：uninitialized → extracting → booting → ready | P0 |
| EN-02 | 重复初始化 — 幂等 | 引擎已 ready | 直接返回，不重复解压/启动 | P0 |
| EN-03 | 并发初始化保护 | 同时调用 initialize 两次 | 第二次被 `isInitializing` 挡住，直接返回 | P0 |
| EN-04 | rootfs 未找到 | 捆绑包中缺少 alpine-aarch64.tar.gz | `throw EngineError.rootfsNotFound`，状态 → error | P0 |
| EN-05 | rootfs 损坏 — 关键文件缺失 | 解压后缺少 /bin/sh | `throw EngineError.rootfsCorrupted` | P0 |
| EN-06 | rootfs 损坏 — 缺少 /etc/passwd | 解压后缺少 /etc/passwd | `throw EngineError.rootfsCorrupted` | P0 |
| EN-07 | 磁盘空间不足 | 可用空间 < 需要的 4x 压缩大小 | `throw EngineError.diskSpaceInsufficient` | P1 |
| EN-08 | 内核启动失败 | `actuate_kernel()` 返回非 0 | `throw EngineError.kernelBootFailed`，状态 → error | P0 |
| EN-09 | ish 环境初始化失败 | `ISHAppShim.current.initISH()` 返回 false | `throw EngineError.kernelBootFailed` | P1 |
| EN-10 | 就绪检查失败 — /bin/sh 缺失 | rootfs 解压后但 /bin/sh 不存在 | `throw EngineError.rootfsCorrupted` | P1 |
| EN-11 | 就绪检查失败 — /etc/passwd 缺失 | rootfs 解压后但 /etc/passwd 不存在 | `throw EngineError.rootfsCorrupted` | P1 |
| EN-12 | `validateEngine()` — 已就绪 | engine.state = .ready | 不 throw | P0 |
| EN-13 | `validateEngine()` — 未初始化 | engine.state = .uninitialized | `throw EngineError.notInitialized` | P0 |
| **EN-14** | **`isInitialized` — 就绪检查失败后** | bootCompleted=true 但 state=.error | **⚠️ 预期 FAIL：当前返回 true，应返回 false** | P0 |
| EN-15 | `resetEngine()` | 引擎已就绪 | 状态重置为 .uninitialized，所有标志清空 | P1 |
| EN-16 | `reinitialize()` | 引擎已就绪 | 清理旧 rootfs → 重新初始化 | P1 |
| EN-17 | RootFSManager — 已存在 rootfs | rootfs 已解压 | 跳过解压，直接返回路径 | P0 |
| EN-18 | RootFSManager — cleanupRootFS | rootfs 存在 | 删除整个 rootfs 目录 | P1 |
| EN-19 | EngineState description 字符串 | 每个 case | 返回中文描述，非空 | P2 |
| EN-20 | EngineError errorDescription | 每个 case | 非空，包含诊断信息 | P2 |

### 2.5 ISHShellBridge.swift

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| SH-01 | `execute("echo hello")` — 异步 | 引擎就绪 | exitCode=0, stdout="hello\n" | P0 |
| SH-02 | `execute("")` — 空命令 | 引擎就绪 | exitCode=0, stdout="", stderr="" | P1 |
| SH-03 | `execute` — 引擎未初始化 | 引擎未就绪 | `throw ISHShellError.engineNotInitialized` | P0 |
| SH-04 | `execute` — lineCallback | 执行 `echo -e "a\nb\nc"` | callback 被调用 3 次，lines=["a","b","c"] | P1 |
| SH-05 | `execute(executable:...)` — 直接执行 | executable="/usr/bin/env", args=[] | stdout 包含环境变量 | P1 |
| SH-06 | `execute(executable:..., environment:)` | 传入 `["FOO": "BAR"]` | stdout 包含 "FOO=BAR" | P1 |
| SH-07 | `executeSync("echo sync")` — 同步 | 引擎就绪，timeout=0 | exitCode=0, stdout="sync\n" | P0 |
| SH-08 | `executeSync("sleep 10", timeout: 1)` — 超时 | 引擎就绪 | `throw ISHShellError.timeout` | P0 |
| SH-09 | `executeSync("echo ok", timeout: 5)` — 不超时 | 快速命令 | 正常返回 | P1 |
| SH-10 | `executeSync` — 引擎未初始化 | 引擎未就绪 | `throw ISHShellError.engineNotInitialized` | P1 |
| SH-11 | `kill(pid:signal:)` — 正常终止 | 正在运行的进程 | 返回 true，进程从 activeProcesses 移除 | P0 |
| SH-12 | `kill(pid:signal:)` — 无效 PID | 不存在的 PID | 返回 false（由 C 层决定） | P1 |
| SH-13 | `killAll()` | 3 个活跃进程 | 全部终止，activeProcessCount = 0 | P1 |
| SH-14 | processTracking — track/remove | 执行一个命令 | 执行期间 activeProcessCount=1，完成后=0 | P1 |
| SH-15 | 空命令 — async | `execute("   ")` 仅空白 | exitCode=0, pid=0, duration≈0 | P1 |
| SH-16 | 空命令 — sync | `executeSync("   ")` 仅空白 | exitCode=0, pid=0, stdout="" | P1 |
| SH-17 | `validateReady()` — 就绪 | 引擎就绪 | 不 throw | P1 |
| SH-18 | `validateReady()` — 未初始化 | 引擎未就绪 | `throw ISHShellError.engineNotInitialized` | P1 |
| SH-19 | ISHShellResult.combinedOutput | stdout="a", stderr="b" | "a\nb" | P2 |
| SH-20 | ISHShellResult.combinedOutput — 仅 stdout | stdout="a", stderr="" | "a" | P2 |
| SH-21 | ISHShellResult.combinedOutput — 仅 stderr | stdout="", stderr="b" | "b" | P2 |

### 2.6 BindMountService.swift

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| BM-01 | `mount` → 验证 → `unmount` | hostPath="/tmp/mount-src", guestPath="/mnt/test" | 挂载成功，guest 内 ls 可见；卸载成功 | P0 |
| BM-02 | `mount` — 引擎未初始化 | 引擎未就绪 | `throw MountError.engineNotInitialized` | P0 |
| BM-03 | `mount` — 主机路径不存在 | hostPath 指向不存在的目录 | `throw MountError.hostPathNotFound` | P1 |
| BM-04 | `mount` — 重复挂载 | 同一 guestPath 挂载两次 | 第二次 `throw MountError.alreadyMounted` | P0 |
| BM-05 | `unmount` — 路径未挂载 | guestPath 未在挂载表中 | `throw MountError.notMounted` | P1 |
| BM-06 | `unmount` — 引擎未初始化 | 引擎未就绪 | `throw MountError.engineNotInitialized` | P1 |
| BM-07 | `unmountAll` — 多个挂载 | 3 个活跃挂载 | 全部卸载，LIFO 顺序 | P0 |
| BM-08 | `unmountAll` — 引擎未初始化 | 引擎未就绪 | `throw MountError.engineNotInitialized` | P1 |
| BM-09 | `unmountAll` — 部分卸载失败 | 其中一个卸载失败 | 继续卸载其余，不中断，报告错误 | P1 |
| BM-10 | `isMounted(guestPath:)` — 已挂载 | 挂载后查询 | 返回 true | P1 |
| BM-11 | `isMounted(guestPath:)` — 未挂载 | 卸载后查询 | 返回 false | P1 |
| BM-12 | `isHostMounted(hostPath:)` — 已挂载 | 挂载后查询 | 返回 true | P1 |
| BM-13 | `mountForGuestPath` / `mountForHostPath` | 挂载后查询 | 返回正确的 BindMount 记录 | P1 |
| BM-14 | 只读挂载 | isReadOnly=true | 挂载成功，guest 内写操作应失败（取决于 fakefs） | P2 |
| BM-15 | `mountBatch` | 3 个挂载规格 | 全部挂载成功 | P1 |
| BM-16 | `mountBatch` — 中途失败 | 第 2 个失败 | 第 1 个保持挂载，抛出错误 | P1 |
| BM-17 | `reset()` | 2 个活跃挂载 | 全部卸载，内部表清空 | P1 |
| BM-18 | `registerStaticMount` | 直接注册 | 添加到挂载表，不实际执行 mount | P2 |
| BM-19 | 路径索引一致性 | 挂载/卸载操作 | guestPathIndex 和 hostPathIndex 始终保持一致 | P0 |
| BM-20 | `escapePath` — 特殊字符 | 路径包含单引号 | 正确转义，不造成 shell 注入 | P1 |
| BM-21 | mounts 属性返回排序副本 | 按 createdAt 排序 | 最早创建的排在最前 | P2 |

### 2.7 AgentBoxApp.swift（启动集成测试）

| ID | 用例名 | 输入/前置条件 | 预期结果 | 优先级 |
|----|--------|--------------|---------|--------|
| AP-01 | App 启动 — rootfs 存在 | alpine-aarch64.tar.gz 在 Bundle 中 | 引擎自动初始化，状态 → ready | P0 |
| AP-02 | App 启动 — rootfs 不存在 | 缺少 rootfs 资源 | 打印警告，SpawnRoot/FileSystemAccess 仍可用 | P0 |
| AP-03 | App 启动 — 初始化失败 | rootfs 损坏 | 打印错误，UI 显示错误状态 | P1 |
| AP-04 | engine 通过 environmentObject 注入 | ContentView 中 | `@EnvironmentObject var engine` 非 nil | P1 |

### 2.8 ContentView.swift（UI 验证测试）

| ID | 用例名 | 前置条件 | 预期结果 | 优先级 |
|----|--------|---------|---------|--------|
| CV-01 | Terminal Tab — 引擎未初始化 | engine.state = .uninitialized | 显示 "引擎未初始化"，无 quickTestPanel | P1 |
| CV-02 | Terminal Tab — 引擎就绪 | engine.state = .ready | 显示 "Engine Ready" + quickTestPanel | P1 |
| CV-03 | Terminal Tab — 引擎错误 | engine.state = .error("...") | 显示 "初始化失败" + 错误详情 | P1 |
| CV-04 | Terminal Tab — 解压中 | engine.state = .extracting(...) | 显示进度 + ProgressView | P1 |
| CV-05 | Terminal Tab — 启动中 | engine.state = .booting | 显示进度 + ProgressView | P1 |
| CV-06 | quickTestPanel — 执行命令 | 引擎就绪，输入 `echo test` | testOutput 显示正确结果 | P0 |
| CV-07 | quickTestPanel — 空命令 | 输入为空 | 执行按钮禁用 | P1 |
| CV-08 | quickTestPanel — 清空输出 | testOutput 非空 | 点击清空后 testOutput 为空 | P1 |
| CV-09 | SpawnRoot Test — whoami | 点击 whoami 按钮 | testOutput 显示 "root" | P0 |
| CV-10 | FileSystemAccess Test — 文件 IO | 点击文件 IO 按钮 | testOutput 显示写入/读取/清理成功 | P0 |
| CV-11 | Tab 切换 | 点击不同 Tab | 视图正确切换 | P1 |

### 2.9 端到端集成测试

| ID | 用例名 | 流程 | 预期结果 | 优先级 |
|----|--------|------|---------|--------|
| E2E-01 | 完整启动 → Shell 执行 | App 启动 → 引擎初始化 → `echo "test" > /tmp/test.txt` → `cat /tmp/test.txt` | stdout = "test" | P0 |
| E2E-02 | 挂载 + 文件共享 | mount /tmp/host → /mnt/host → guest 内 touch /mnt/host/new.txt → iOS 宿主 FileSystemAccess.fileExists | true | P0 |
| E2E-03 | SpawnRoot + FileSystemAccess 独立可用 | 引擎未初始化时 | SpawnRoot.execute("whoami") 和 FileSystemAccess.writeFile 正常 | P0 |
| E2E-04 | 错误恢复 | 引擎初始化失败 → UI 显示错误 → 修复 rootfs → 重启 App | 第二次初始化成功 | P1 |

---

## 三、发现的问题 + 测试预期 FAIL 的用例

以下用例预期会失败（对应该源码的已知 Bug，已标记在审查报告中）：

| 失败用例 ID | 对应 Bug | 严重级别 |
|-------------|---------|---------|
| **EN-14** | `ISHEngine.isInitialized` 在就绪检查失败后误报 true | 🔴 CRITICAL |
| (编译时) | ISHShellBridge + BindMountService 中 `ISHEngine.shared.isInitialized` 缺少 `await` | 🔴 CRITICAL |
| (编译时) | `@_silgen_name` callback 类型 `ISHShellExecutionResultBridge` 与 Obj-C 结构体布局不匹配 | 🔴 CRITICAL |
| SH-16-p2 | `executeSync` 中 `shellError` 死代码（永远为 nil） | 🟡 MEDIUM |
| (语义) | `ISHEngine.initialize()` 就绪检查阶段错误地设置 `state = .extracting` | 🟡 MEDIUM |
| (语义) | `SpawnRoot.execute(executable:)` 使用 `FileManager.fileExists` 而非 POSIX API | 🟡 MEDIUM |

---

## 四、测试覆盖率目标

| 模块 | 目标覆盖率 | 说明 |
|------|-----------|------|
| PersonaSpawn.c | 90% | 关键 C 函数，所有分支需覆盖 |
| SpawnRoot.swift | 90% | 核心 root 执行路径 |
| FileSystemAccess.swift | 95% | 所有 CRUD + errno 映射 |
| ISHEngine.swift | 90% | 所有状态转换 + 错误路径 |
| ISHShellBridge.swift | 85% | async/sync/timeout/kill 四条路径 |
| BindMountService.swift | 85% | mount/unmount/query 三条路径 |
| App 层 | 60% | 主要是 UI 状态验证 |

---

## 五、测试环境要求

| 条件 | 说明 |
|------|------|
| 设备 | iPhone/iPad 运行 iOS 16.6.1 |
| 安装方式 | TrollStore 2 签名安装 |
| Entitlements | `no-sandbox` + `persona-mgmt` + `AppDataContainers` |
| 资源 | `alpine-aarch64.tar.gz` 已添加到 Bundle Resources |
| 网络 | 不需要（所有测试离线） |

---

*本文档由 Edward (QA Engineer) 产出，通过 SendMessage 回传主理人。*
