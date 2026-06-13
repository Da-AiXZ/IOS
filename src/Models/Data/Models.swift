import Foundation

// MARK: - 持久化模型（Codable, 非 SwiftData）
// iOS 16.6.1 不支持 SwiftData，使用 Codable + FileManager

struct ConversationRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [MessageRecord] = []
    var providerTypeRaw: String = "anthropic"
    var selectedModel: String = "claude-sonnet-4-20250514"
}

struct MessageRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var roleRaw: String = "user"
    var contentJSON: String = ""
    var timestamp: Date = Date()
    var toolCallsJSON: String?
    var tokenCount: Int?
}

struct AgentSessionRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var toolCallCount: Int = 0
}

struct SkillConfigRecord: Codable, Identifiable {
    var id: String = ""
    var name: String = ""
    var descText: String = ""
    var version: String = "1.0"
    var isActive: Bool = true
    var promptExtension: String = ""
}

struct LLMConfigRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var providerTypeRaw: String = "anthropic"
    var apiKeyIdentifier: String = ""
    var selectedModel: String = ""
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
    var isActive: Bool = false
}
