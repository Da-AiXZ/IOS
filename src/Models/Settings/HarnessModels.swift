import Foundation

// MARK: - Agent 快照（检查点）

struct AgentSnapshot: Codable {
    let sessionId: UUID
    let turnCount: Int
    let messageIDs: [UUID]
    let toolCallHistory: [ToolCallRecord]
    let transition: LoopTransition
    let compactBoundary: UUID?
    let timestamp: Date
    let tokenUsage: TokenUsage
}

struct ToolCallRecord: Codable {
    let toolName: String
    let arguments: [String: AnyCodable]
    let result: String
    let isError: Bool
    let duration: TimeInterval
}

struct TokenUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
}

// MARK: - 过渡类型

enum LoopTransition: String, Codable {
    case nextTurn
    case stopHookBlocking
    case maxOutputTokensRecovery
    case reactiveCompactRetry
    case tokenBudgetContinuation
    case toolError
    case userInterrupted
    case maxIterationsReached
    case streamingFailed
}

// MARK: - 权限决策

enum PermissionDecision: Sendable {
    case allow
    case deny(reason: String)
    case ask(question: String, tool: String)
}

struct PermissionRule: Codable, Sendable {
    let toolName: String
    let pattern: String?
    let behavior: PermissionBehavior
    let source: RuleSource
}

enum PermissionBehavior: String, Codable, Sendable {
    case allow
    case deny
    case ask
}

enum RuleSource: String, Codable, Sendable {
    case session
    case localSettings
    case userSettings
    case policy
}

enum PermissionMode: String, Codable, Sendable {
    case `default`
    case plan
    case auto
    case bypass
}

// MARK: - Bash 安全结果

struct BashSafetyResult: Sendable {
    let isDestructive: Bool
    let warnings: [String]
    let commandCategory: CommandCategory
}

enum CommandCategory: String, Sendable {
    case read
    case write
    case destructive
    case network
    case unknown
}

// MARK: - 度量

struct MetricsReport: Codable, Sendable {
    let successRate: Double
    let efficiency: Double
    let costUSD: Double
    let robustness: Double
    let security: Double
    let consistency: Double
    let timestamp: Date
}

struct ErrorCategory: Codable, Hashable {
    let name: String
}

// MARK: - 钩子

enum HookEvent: String, Sendable {
    case preToolUse
    case postToolUse
    case postToolUseFailure
    case prePermissionCheck
    case postPermissionDenied
    case sessionStart
    case sessionEnd
    case stop
}

enum HookResult: Sendable {
    case allow
    case deny(reason: String)
    case modify(input: [String: AnyCodable])
}

enum StopHookResult: Sendable {
    case `continue`
    case injectMessage(String)
    case block
}

// MARK: - Shell 输出

struct ShellOutput: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}
