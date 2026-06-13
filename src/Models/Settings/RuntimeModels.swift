import Foundation

// MARK: - 消息角色

enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - 消息内容

enum MessageContent: Sendable, Codable {
    case text(String)
    case multimodal(text: String, images: [ImageData])
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    case toolResult(id: String, content: String, isError: Bool)

    // Codable
    enum CodingKeys: String, CodingKey {
        case type, text, images, id, name, input, content, isError
    }
    enum ContentType: String, Codable { 
        case text, multimodal, toolUse, toolResult 
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(ContentType.self, forKey: .type) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .multimodal:
            self = .multimodal(
                text: try c.decode(String.self, forKey: .text),
                images: try c.decode([ImageData].self, forKey: .images)
            )
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode([String: AnyCodable].self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                id: try c.decode(String.self, forKey: .id),
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decode(Bool.self, forKey: .isError)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode(ContentType.text, forKey: .type)
            try c.encode(text, forKey: .text)
        case .multimodal(let text, let images):
            try c.encode(ContentType.multimodal, forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(images, forKey: .images)
        case .toolUse(let id, let name, let input):
            try c.encode(ContentType.toolUse, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let id, let content, let isError):
            try c.encode(ContentType.toolResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }
}

// MARK: - 图片数据

struct ImageData: Codable, Sendable {
    let data: Data
    let mimeType: String
}

// MARK: - 运行时消息（非 SwiftData）

struct ChatMessage: Sendable, Codable {
    let role: MessageRole
    let content: MessageContent
    let toolCallId: String?
    let name: String?
    
    init(role: MessageRole, content: MessageContent, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.name = name
    }
}

// MARK: - AnyCodable

struct AnyCodable: Codable, Sendable {
    let value: Any
    
    init(_ value: Any) { self.value = value }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyCodable].self) { value = array.map { $0.value } }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict.mapValues { $0.value } }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let int = value as? Int { try container.encode(int) }
        else if let double = value as? Double { try container.encode(double) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else if let string = value as? String { try container.encode(string) }
        else if let array = value as? [Any] { try container.encode(array.map { AnyCodable($0) }) }
        else if let dict = value as? [String: Any] { try container.encode(dict.mapValues { AnyCodable($0) }) }
    }
}

// MARK: - 工具定义

struct ToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
}

struct JSONSchema: Codable, Sendable {
    let type: String
    let properties: [String: PropertySchema]?
    let required: [String]?
}

struct PropertySchema: Codable, Sendable {
    let type: String
    let description: String
    let `enum`: [String]?
    let items: PropertySchema?
    
    init(type: String, description: String, enum: [String]? = nil, items: PropertySchema? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
        self.items = items
    }
}

// MARK: - 工具调用

struct ToolCall: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let arguments: [String: AnyCodable]
}

struct ToolCallStart: Codable, Sendable {
    let id: String
    let name: String
}

struct ToolCallDelta: Codable, Sendable {
    let id: String
    let argumentsDelta: String
}

struct ToolResult: Codable, Sendable {
    let callId: String
    let output: String
    let isError: Bool
}

// MARK: - 流事件

enum LLMStreamEvent: Sendable {
    case textDelta(String)
    case toolCallStart(ToolCallStart)
    case toolCallDelta(ToolCallDelta)
    case toolCallEnd(ToolCall)
    case thinking(String)
    case error(Error)
    case done
}

enum AgentEvent: Sendable {
    case thinking(String)
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolCallCompleted(ToolResult)
    case done(ChatMessage)
    case error(Error)
}

// MARK: - Provider 配置

enum ProviderType: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai
    case gemini
    case deepseek
    case openrouter
    case groq
    case custom
    
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI GPT"
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .custom: return "自定义 (OpenAI 兼容)"
        }
    }
    
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .deepseek: return "https://api.deepseek.com"
        case .openrouter: return "https://openrouter.ai/api"
        case .groq: return "https://api.groq.com"
        case .custom: return ""
        }
    }
    
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-pro"
        case .deepseek: return "deepseek-chat"
        case .openrouter: return "anthropic/claude-sonnet-4"
        case .groq: return "llama-3.3-70b"
        case .custom: return ""
        }
    }
}

struct ProviderConfig: Codable, Sendable {
    let providerType: ProviderType
    let apiKey: String
    let baseURL: String?
    var selectedModel: String
    var parameters: ModelParameters
}

struct ModelParameters: Codable, Sendable {
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
    var topP: Double = 1.0
    var systemPrompt: String?
}

// MARK: - Agent 状态

enum AgentState: Sendable {
    case idle
    case thinking
    case streaming
    case executingTool(name: String)
    case error(String)
}
