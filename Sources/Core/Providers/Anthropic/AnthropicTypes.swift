//
//  AnthropicTypes.swift
//  AppAgent
//

import Foundation

// MARK: - Anthropic Message Types

struct AnthropicMessage: Codable, Sendable {
    let role: String
    let content: AnthropicMessageContent
}

enum AnthropicMessageContent: Codable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.typeMismatch(
                AnthropicMessageContent.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or array")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
}

// MARK: - Content Blocks

enum AnthropicContentBlock: Codable, Sendable {
    case text(AnthropicTextBlock)
    case toolUse(AnthropicToolUseBlock)
    case toolResult(AnthropicToolResultBlock)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try AnthropicTextBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try AnthropicToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try AnthropicToolResultBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Unknown block type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block): try block.encode(to: encoder)
        case .toolUse(let block): try block.encode(to: encoder)
        case .toolResult(let block): try block.encode(to: encoder)
        }
    }
}

struct AnthropicTextBlock: Codable, Sendable {
    let type: String
    let text: String

    init(text: String) { self.type = "text"; self.text = text }
}

struct AnthropicToolUseBlock: Codable, Sendable {
    let type: String
    let id: String
    let name: String
    let input: [String: JSONValue]

    init(id: String, name: String, input: [String: JSONValue]) {
        self.type = "tool_use"; self.id = id; self.name = name; self.input = input
    }
}

struct AnthropicToolResultBlock: Codable, Sendable {
    let type: String
    let toolUseId: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case type, content
        case toolUseId = "tool_use_id"
    }

    init(toolUseId: String, content: String) {
        self.type = "tool_result"; self.toolUseId = toolUseId; self.content = content
    }
}

// MARK: - SSE Response Types

struct SSEContentBlockStart: Decodable {
    let type: String
    let index: Int
    let contentBlock: SSEContentBlock

    enum CodingKeys: String, CodingKey {
        case type, index
        case contentBlock = "content_block"
    }
}

struct SSEContentBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
}

struct SSEContentBlockDelta: Decodable {
    let type: String
    let index: Int
    let delta: SSEDelta
}

struct SSEDelta: Decodable {
    let type: String
    let text: String?
    let partialJson: String?
    /// 扩展思考增量（`thinking_delta`）。
    let thinking: String?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking
        case partialJson = "partial_json"
    }
}

struct SSEMessageDelta: Decodable {
    let type: String
    let delta: SSEMessageDeltaPayload
    let usage: AnthropicUsage?
}

struct SSEMessageDeltaPayload: Decodable {
    let stopReason: String?
    enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" }
}

struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - Error Response

struct AnthropicErrorResponse: Decodable {
    let type: String
    let error: AnthropicErrorDetail
}

struct AnthropicErrorDetail: Decodable {
    let type: String
    let message: String
}
