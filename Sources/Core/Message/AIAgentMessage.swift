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

    public init(id: String = UUID().uuidString,
         role: AIAgentMessageRole,
         content: [Content],
         createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    // MARK: - Convenience initializers

    /// Create a simple text message.
    public static func user(_ text: String) -> AIAgentMessage {
        AIAgentMessage(role: .user, content: [.text(text)])
    }

    public static func assistant(_ text: String) -> AIAgentMessage {
        AIAgentMessage(role: .assistant, content: [.text(text)])
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

        public init(toolCallId: String, content: String) {
            self.toolCallId = toolCallId
            self.content = content
        }
    }
}
