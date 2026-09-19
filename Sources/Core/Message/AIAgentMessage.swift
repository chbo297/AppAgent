//
//  AIAgentMessage.swift
//  AppAgent
//

import Foundation

// MARK: - Message Role

public enum AIAgentMessageRole: String, Sendable, Codable {
    case user
    case assistant
}

// MARK: - Message

/// A provider-agnostic conversation message.
public struct AIAgentMessage: Sendable, Codable {
    public let id: String
    public let role: AIAgentMessageRole
    public let content: [Content]
    public let createdAt: Date

    /// 这条消息属于哪一轮「用户提问 → agent 答复」。
    ///
    /// 与 LLM 的来回（assistant 的工具调用、user 角色的工具结果）都属于**同一轮**：
    /// 它们是一次提问内部的过程，不是用户又说了话。UI 依赖这个归属把过程收进
    /// agent 自己的过程区，而不是把工具结果渲染成用户气泡。
    ///
    /// `nil` = 本字段引入之前持久化的旧快照；UI 侧按顺序回退推导，不影响解码
    /// （Optional 的合成 Decodable 用 `decodeIfPresent`，缺键即 nil）。
    public let turnID: Int?

    public init(id: String = UUID().uuidString,
         role: AIAgentMessageRole,
         content: [Content],
         createdAt: Date = Date(),
         turnID: Int? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.turnID = turnID
    }

    // MARK: - Convenience initializers

    /// Create a simple text message.
    public static func user(_ text: String, turnID: Int? = nil) -> AIAgentMessage {
        AIAgentMessage(role: .user, content: [.text(text)], turnID: turnID)
    }

    public static func assistant(_ text: String, turnID: Int? = nil) -> AIAgentMessage {
        AIAgentMessage(role: .assistant, content: [.text(text)], turnID: turnID)
    }

    /// 这条消息是不是「用户真的说了话」。
    ///
    /// 工具结果在 wire 上同样走 `.user` 角色（两家协议都这么要求），所以不能只看
    /// role——带 toolResult 的 user 消息是 agent 内部来回，不是用户输入。
    public var isGenuineUserInput: Bool {
        role == .user && !content.contains { if case .toolResult = $0 { return true }; return false }
    }

    /// Extract the concatenated text from all `.text` parts.
    public var text: String {
        content.compactMap {
            if case .text(let s) = $0 { return s }
            return nil
        }.joined()
    }

    /// Extract all tool calls from this message.
    public var toolCalls: [ToolCall] {
        content.compactMap {
            if case .toolUse(let tc) = $0 { return tc }
            return nil
        }
    }
}

// MARK: - Nested Types

extension AIAgentMessage {

    /// A single part of a message's content.
    public enum Content: Sendable, Codable {
        /// Plain text content.
        case text(String)
        /// A tool invocation requested by the assistant.
        case toolUse(ToolCall)
        /// The result of a tool invocation, sent back to the model.
        case toolResult(ToolCallResult)

        // MARK: - Codable

        private enum ContentType: String, Codable {
            case text
            case toolUse
            case toolResult
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case toolCall
            case toolResult
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(ContentType.self, forKey: .type)
            switch type {
            case .text:
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case .toolUse:
                let call = try container.decode(ToolCall.self, forKey: .toolCall)
                self = .toolUse(call)
            case .toolResult:
                let result = try container.decode(ToolCallResult.self, forKey: .toolResult)
                self = .toolResult(result)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(ContentType.text, forKey: .type)
                try container.encode(text, forKey: .text)
            case .toolUse(let call):
                try container.encode(ContentType.toolUse, forKey: .type)
                try container.encode(call, forKey: .toolCall)
            case .toolResult(let result):
                try container.encode(ContentType.toolResult, forKey: .type)
                try container.encode(result, forKey: .toolResult)
            }
        }
    }

    /// Represents a tool invocation from the assistant.
    public struct ToolCall: Sendable, Codable {
        public let id: String
        public let name: String
        public let arguments: [String: JSONValue]

        public init(id: String, name: String, arguments: [String: JSONValue]) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    /// Represents the result sent back after executing a tool.
    public struct ToolCallResult: Sendable, Codable {
        public let toolCallId: String
        public let content: String
        /// 工具随结果附带的图片（截图等）。走 provider 的多模态通道，不占文本预算。
        public let images: [ImageAttachment]
        /// 这一步是不是失败了。展示层据此把过程区里的步骤标红，别再去嗅 `content` 的
        /// `Error:` 前缀——那串文案是给模型看的，工具正常返回的正文也可能这么开头。
        public let isError: Bool

        public init(toolCallId: String, content: String,
                    images: [ImageAttachment] = [], isError: Bool = false) {
            self.toolCallId = toolCallId
            self.content = content
            self.images = images
            self.isError = isError
        }

        // 手写 decode：`images` / `isError` 都是后加的键，旧 session 快照里没有，
        // 合成的 Codable 会直接解码失败。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
            self.content = try container.decode(String.self, forKey: .content)
            self.images = try container.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
            // 缺键的旧快照只能回退到当年那条「`Error:` 前缀即失败」的约定。
            let decodedContent = self.content
            self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
                ?? Self.looksLikeError(decodedContent)
        }

        /// 旧快照兜底判定，仅在缺 `isError` 键时使用。
        public static func looksLikeError(_ content: String) -> Bool {
            content.hasPrefix("Error:") || content.hasPrefix("Error：")
        }
    }

    /// 一张随 tool result 回传的图片。存 base64 以便随 session 快照一起持久化。
    public struct ImageAttachment: Sendable, Codable, Equatable {
        public let base64: String
        public let mediaType: String

        public init(base64: String, mediaType: String) {
            self.base64 = base64
            self.mediaType = mediaType
        }

        public init(data: Data, mediaType: String) {
            self.base64 = data.base64EncodedString()
            self.mediaType = mediaType
        }
    }
}
