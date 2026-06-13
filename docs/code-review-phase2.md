# AgentBox Phase 2 — QA 代码审查报告

| 属性 | 值 |
|------|-----|
| 版本 | 1.0 |
| 审查人 | 严过关 (Edward)，QA Engineer |
| 日期 | 2025-07-17 |
| 审查范围 | 10 个文件（7 新增 + 3 修改） |
| **路由判定** | 🔴 **Send To: Engineer（需修复 4 个 CRITICAL + 3 个 MEDIUM Bug）** |

---

## 一、审查维度检查结果

| 维度 | 结果 |
|------|------|
| 1. 类型引用 / 跨文件引用 | ❌ `@MainActor` 隔离违例 ×2 模块 |
| 2. 错误处理完整性 | ⚠️ 1 处就绪检查失败后状态不一致 |
| 3. API 签名 vs PRD | ✅ 签名一致，增加合理的扩展参数 |
| 4. 并发安全性 (actor/@MainActor) | ❌ 6 处缺少 `await` 的跨 actor 调用 |
| 5. C-Swift 互操作 | ❌ `@_silgen_name` block 类型不匹配 |
| 6. 内存管理 | ✅ 无 retain cycle，malloc/free 配对正确 |
| 7. 逻辑错误 / 死代码 | ⚠️ 2 处语义错误 + 1 处死代码 |

---

## 二、Bug 清单

### 🔴 CRITICAL（必须修复，否则编译/运行失败）

#### BUG-1：`@MainActor` 隔离违例 — ISHShellBridge 访问 ISHEngine

**位置**：`src/Core/ISHBridge/ISHShellBridge.swift`

| 行号 | 代码 |
|------|------|
| 129 | `guard ISHEngine.shared.isInitialized else {` |
| 246 | `guard ISHEngine.shared.isInitialized else {` |
| 405 | `guard ISHEngine.shared.isInitialized else {` |

**问题**：`ISHShellBridge` 是 `actor`，`ISHEngine` 是 `@MainActor`。从 actor 上下文访问 `@MainActor` 隔离的属性 `isInitialized` 需要 `await`。

**预期修正**：
```swift
guard await ISHEngine.shared.isInitialized else {
```
或改用 `await ISHEngine.shared.validateEngine()`（该函数会 throw）

---

#### BUG-2：`@MainActor` 隔离违例 — BindMountService 访问 ISHEngine

**位置**：`src/Core/ISHBridge/BindMountService.swift`

| 行号 | 代码 |
|------|------|
| 156 | `guard ISHEngine.shared.isInitialized else {` |
| 236 | `guard ISHEngine.shared.isInitialized else {` |
| 282 | `guard ISHEngine.shared.isInitialized else {` |

**问题**：与 BUG-1 相同模式。`actor BindMountService` 访问 `@MainActor ISHEngine`。

**预期修正**：同上，添加 `await`。

---

#### BUG-3：`ISHEngine.isInitialized` 就绪检查失败后误报 `true`

**位置**：`src/Core/ISHBridge/ISHEngine.swift`

```swift
// Line 122-125 (当前代码)
var isInitialized: Bool {
    if case .ready = state { return true }
    return bootCompleted  // ← BUG: verifyReadiness 失败后 bootCompleted 仍为 true
}

// Line 201-222 (流程)
bootCompleted = true           // Line 203 ← 先设为 true
state = .extracting(progress: "验证引擎就绪...")  // Line 208
do {
    try await verifyReadiness()  // Line 211 ← 如果这里失败...
} catch ... {
    state = .error(...)          // Line 213 ← state 变成 .error
    throw error
}
// 此时：state=.error, bootCompleted=true
// isInitialized 返回 true！但引擎实际不可用！
```

**问题**：就绪检查失败后 `isInitialized` 仍返回 `true`，ISHShellBridge 和 BindMountService 会尝试在故障引擎上执行命令。

**预期修正**：
```swift
var isInitialized: Bool {
    if case .ready = state { return true }
    return false  // 仅在 state == .ready 时视为已初始化
}
```
或在 `catch` 块中设置 `bootCompleted = false`。

---

#### BUG-4：`@_silgen_name` callback 类型不匹配

**位置**：`src/Core/ISHBridge/ISHShellBridge.swift`，行 372-377

```swift
@_silgen_name("ISHShellExecutor_executeCommand")
private func ish_execute_command(
    _ command: String,
    _ lineCallback: @escaping @convention(block) (String, Bool) -> Void,
    _ completion: @escaping @convention(block) (ISHShellExecutionResultBridge) -> Void
    //                                           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //                                           Swift struct — 内存布局 ≠ Obj-C struct
) -> Int32
```

**问题**：`ISHShellExecutionResultBridge` 是 Swift struct（定义在行 391-397），但 C 侧 `ISHShellExecutor` 的回调期望 `ISHShellExecutionResult`（Obj-C struct，来自 `ISHShellExecutor.h`）。二者的内存布局（alignment、padding、引用计数）不兼容，运行时传递会导致数据损坏或 crash。

**预期修正**：二选一 —
- A) 将 `ISHShellExecutionResult` 的定义放在 Bridging Header 中，Swift 侧直接用 Obj-C 类型
- B) 用 `@convention(c)` 函数指针替代 block，手动解包 C 结构体字段

---

### 🟡 MEDIUM（逻辑错误，影响语义正确性）

#### BUG-5：ISHEngine 就绪检查阶段错误使用 `.extracting` 状态

**位置**：`src/Core/ISHBridge/ISHEngine.swift`，行 208

```swift
state = .extracting(progress: "验证引擎就绪...")
```

**问题**：就绪验证阶段不属于 `extracting`。语义上应属于 `booting` 或新增一个中间状态。当前虽然 UI 显示正确（也显示 ProgressView），但日志和状态监控会误报。

**预期修正**：保持 `state = .booting`，或新增 `.verifying` case。

---

#### BUG-6：`SpawnRoot.execute(executable:)` 使用 FileManager 检查路径

**位置**：`src/Core/TrollStore/SpawnRoot.swift`，行 169

```swift
guard FileManager.default.fileExists(atPath: executable) else {
```

**问题**：架构设计明确要求使用 POSIX API 绕过 iOS 沙盒。`FileManager` 在某些路径（如 `/var/root/`）可能返回 false 即使路径实际存在。

**预期修正**：
```swift
guard access(executable, F_OK) == 0 else {
```

---

#### BUG-7：`ISHShellBridge.executeSync` 中死代码 (`shellError`)

**位置**：`src/Core/ISHBridge/ISHShellBridge.swift`，行 262 & 306

```swift
var shellError: ISHShellError?   // Line 262 — 声明但从未赋值

// ... semaphore wait ...

if let error = shellError {      // Line 306 — 永远为 nil
    throw error
}
```

**问题**：`shellError` 在上面的 completion block 中从未被赋值（block 只设置 `shellResult`）。这段代码是死代码。

**预期修正**：删除死代码，或在 completion block 的合适位置赋值 `shellError`（如进程被 kill 时）。

---

### 🔵 MINOR（可延后修复）

#### BUG-8（文档）：架构文档与实现文件路径不一致

架构设计指定 `src/Core/ISHBridge/ISHAppShim.m` + `.h`（Obj-C），实际实现为单一的 `src/Core/ISHBridge/ISHAppShim.swift`（Swift + `@objc`）。功能等效，但文档需更新。

#### BUG-9（注释）：`agentbox_spawn_root_simple` 误导性注释

**位置**：`src/Core/TrollStore/PersonaSpawn.c`，行 247

注释说 "caller should have already tried fork path, but we handle here"，但实际上该函数在 persona 失败时直接返回 -1，不做 fork fallback（fork fallback 在 Swift 层处理）。

---

## 三、已验证无问题的维度

| 维度 | 验证结果 |
|------|---------|
| **内存管理** | ✅ `strdup` 全部在 `defer` 中 `free`；C 层 malloc 失败有正确清理；无 retain cycle |
| **Pipe 生命周期** | ✅ pipe 创建失败时正确关闭已创建的 pipe；父进程端正确关闭写端；错误路径关闭全部 fd |
| **API 签名一致性** | ✅ 所有公开方法与 PRD 接口契约一致（仅在合理范围内增加了 timeout 等扩展参数） |
| **SpawnResult / ISHShellResult** | ✅ Sendable 标记正确 |
| **ContentView Tab 切换** | ✅ enum + TabView 结构正确 |
| **Bridging Header** | ✅ 包含所有需要的 C 声明和 ish 头文件 |
| **错误描述中文化** | ✅ 所有 `errorDescription` 实现完整 |
| **defer cleanup 模式** | ✅ 资源释放正确使用 defer |

---

## 四、最终路由判定

```
┌─────────────────────────────────────────────────┐
│                                                 │
│   🔴 路由判定：Send To: Engineer（寇豆码）        │
│                                                 │
│   源码存在 4 个 CRITICAL + 3 个 MEDIUM Bug      │
│   测试设计正确，无缺陷                            │
│                                                 │
│   需修复文件：                                    │
│   • ISHShellBridge.swift  (BUG-1, BUG-4, BUG-7) │
│   • BindMountService.swift (BUG-2)               │
│   • ISHEngine.swift        (BUG-3, BUG-5)        │
│   • SpawnRoot.swift        (BUG-6)               │
│                                                 │
│   修复后可进入 Round 2 回归测试                   │
└─────────────────────────────────────────────────┘
```

---

*本文档由 Edward (QA Engineer) 产出，通过 SendMessage 回传主理人。*
