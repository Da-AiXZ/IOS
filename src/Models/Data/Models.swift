import Foundation
import SwiftData

/// 对话（会话）模型
@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade) var messages: [Message]?
    var providerTypeRaw: String   // ProviderType.rawValue
    var selectedModel: String
    var workspacePath: String?

    init(
        title: String = "新对话",
        providerType: String = "anthropic",
        selectedModel: String = "claude-sonnet-4-20250514",
        workspacePath: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
        self.providerTypeRaw = providerType
        self.selectedModel = selectedModel
        self.workspacePath = workspacePath
    }
}

/// 消息模型
@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var roleRaw: String           // MessageRole.rawValue
    var contentJSON: String       // 序列化 MessageContent (JSON)
    var timestamp: Date
    var conversation: Conversation?
    var toolCallsJSON: String?    // 序列化 tool calls (JSON)
    var tokenCount: Int?

    init(
        role: MessageRole,
        content: String,          // JSON-serialized MessageContent
        conversation: Conversation? = nil,
        toolCalls: String? = nil,
        tokenCount: Int? = nil
    ) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.contentJSON = content
        self.timestamp = Date()
        self.conversation = conversation
        self.toolCallsJSON = toolCalls
        self.tokenCount = tokenCount
    }
}

/// Agent 会话记录
@Model
final class AgentSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var toolCallCount: Int
    var providerTypeRaw: String
    var success: Bool?

    init(
        providerType: String,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0
    ) {
        self.id = UUID()
        self.startedAt = Date()
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.toolCallCount = 0
        self.providerTypeRaw = providerType
    }
}

/// 技能配置
@Model
final class SkillConfig {
    @Attribute(.unique) var id: String
    var name: String
    var descText: String
    var version: String
    var author: String?
    var iconName: String
    var isBuiltIn: Bool
    var isActive: Bool
    var installedAt: Date
    var setupScript: String?
    var promptExtension: String
    var toolDefinitionsJSON: String

    init(
        id: String,
        name: String,
        description: String,
        version: String,
        author: String? = nil,
        iconName: String = "gearshape",
        isBuiltIn: Bool = false,
        setupScript: String? = nil,
        promptExtension: String = "",
        toolDefinitionsJSON: String = "[]"
    ) {
        self.id = id
        self.name = name
        self.descText = description
        self.version = version
        self.author = author
        self.iconName = iconName
        self.isBuiltIn = isBuiltIn
        self.isActive = true
        self.installedAt = Date()
        self.setupScript = setupScript
        self.promptExtension = promptExtension
        self.toolDefinitionsJSON = toolDefinitionsJSON
    }
}

/// LLM 配置
@Model
final class LLMConfiguration {
    @Attribute(.unique) var id: UUID
    var providerTypeRaw: String
    var apiKeyIdentifier: String  // Keychain key
    var baseURL: String?
    var selectedModel: String
    var temperature: Double
    var maxTokens: Int
    var topP: Double
    var isActive: Bool

    init(
        providerType: String,
        apiKeyIdentifier: String,
        baseURL: String? = nil,
        selectedModel: String = "",
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        topP: Double = 1.0,
        isActive: Bool = false
    ) {
        self.id = UUID()
        self.providerTypeRaw = providerType
        self.apiKeyIdentifier = apiKeyIdentifier
        self.baseURL = baseURL
        self.selectedModel = selectedModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.isActive = isActive
    }
}
