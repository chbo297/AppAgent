//
//  OpenAIChatCompletionsMapper.swift
//  AppAgent
//

import Foundation

/// Maps provider-agnostic types to and from the OpenAI Chat Completions wire format.
enum OpenAIChatCompletionsMapper {
    typealias ActiveToolCall = (id: String, name: String, arguments: String)

    // MARK: - Request

    static func toMessages(
        _ messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>]
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []

        let systemText = system.compactMap { segment -> String? in
            if case .content(let prompt) = segment { return prompt.text }
            return nil
        }.joined(separator: "\n\n")

        if !systemText.isEmpty {
            result.append(["role": "system", "content": systemText])
        }

        for message in messages {
            switch message.role {
            case .user:
                appendUserMessage(message, to: &result)
            case .assistant:
                appendAssistantMessage(message, to: &result)
            }
        }

        return result
    }

    static func toTools(_ segments: [ContentOrCacheControl<any ToolProtocol>]) -> [[String: Any]] {
        var tools: [[String: Any]] = []

        for segment in segments {
            if case .content(let tool) = segment {
                tools.append([
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": buildInputSchema(tool.parameters)
                    ]
                ])
            }
        }

        return tools
    }

    private static func appendUserMessage(_ message: AIAgentMessage, to result: inout [[String: Any]]) {
        var textBuffer = ""

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            result.append(["role": "user", "content": textBuffer])
            textBuffer = ""
        }

        for part in message.content {
            switch part {
            case .text(let text):
                textBuffer += text
            case .toolResult(let resultPart):
                flushText()
                result.append([
                    "role": "tool",
                    "tool_call_id": resultPart.toolCallId,
                    "content": resultPart.content
                ])
            case .toolUse:
                break
            }
        }

        flushText()
    }

    private static func appendAssistantMessage(_ message: AIAgentMessage, to result: inout [[String: Any]]) {
        let text = message.content.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()

        let toolCalls = message.content.compactMap { part -> [String: Any]? in
            guard case .toolUse(let call) = part else { return nil }
            return [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": argumentsJSONString(call.arguments)
                ]
            ]
        }

        guard !text.isEmpty || !toolCalls.isEmpty else { return }

        var item: [String: Any] = ["role": "assistant"]
        item["content"] = text.isEmpty ? NSNull() : text
        if !toolCalls.isEmpty {
            item["tool_calls"] = toolCalls
        }
        result.append(item)
    }

    // MARK: - Response

    static func parseSSEEvent(
        _ sseEvent: SSEEvent,
        activeToolCalls: inout [Int: ActiveToolCall]
    ) -> [ProviderStreamEvent] {
        let payload = sseEvent.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]" else {
            return flushToolCalls(&activeToolCalls)
        }

        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
            return []
        }

        var events: [ProviderStreamEvent] = []

        if let usage = chunk.usage {
            events.append(.usage(
                inputTokens: usage.promptTokens ?? 0,
                outputTokens: usage.completionTokens ?? 0
            ))
        }

        for choice in chunk.choices {
            if let reasoning = choice.delta.reasoningContent ?? choice.delta.reasoning, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let content = choice.delta.content, !content.isEmpty {
                events.append(.textDelta(content))
            }

            for toolCall in choice.delta.toolCalls ?? [] {
                let index = toolCall.index ?? 0
                var active = activeToolCalls[index] ?? (
                    id: toolCall.id ?? "call_\(index)",
                    name: "",
                    arguments: ""
                )
                if let id = toolCall.id {
                    active.id = id
                }
                if let name = toolCall.function?.name {
                    active.name = name
                }
                if let arguments = toolCall.function?.arguments {
                    active.arguments += arguments
                }
                activeToolCalls[index] = active
            }

            if let finishReason = choice.finishReason {
                switch finishReason {
                case "tool_calls", "function_call":
                    events.append(contentsOf: flushToolCalls(&activeToolCalls))
                    events.append(.done(stopReason: .toolUse))
                case "stop":
                    events.append(.done(stopReason: .endTurn))
                case "length":
                    events.append(.done(stopReason: .maxTokens))
                default:
                    events.append(.done(stopReason: .unknown))
                }
            }
        }

        return events
    }

    private static func flushToolCalls(_ activeToolCalls: inout [Int: ActiveToolCall]) -> [ProviderStreamEvent] {
        let calls = activeToolCalls
            .sorted { $0.key < $1.key }
            .compactMap { _, toolCall -> ProviderStreamEvent? in
                guard !toolCall.name.isEmpty else { return nil }
                return .toolCall(AIAgentMessage.ToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    arguments: decodeArguments(toolCall.arguments)
                ))
            }
        activeToolCalls.removeAll()
        return calls
    }

    private static func decodeArguments(_ raw: String) -> [String: JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: - Schema Helpers

    private static func buildInputSchema(_ schema: Tool.Schema) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, prop) in schema.properties {
            properties[key] = buildJSONSchema(prop)
        }

        return [
            "type": "object",
            "properties": properties,
            "required": schema.required
        ]
    }

    private static func buildJSONSchema(_ schema: JSONSchema) -> [String: Any] {
        switch schema {
        case .string(let desc, let enumValues, let defaultValue):
            var dict: [String: Any] = ["type": "string"]
            if let desc { dict["description"] = desc }
            if let enumValues { dict["enum"] = enumValues }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .number(let desc, let minimum, let maximum, let defaultValue):
            var dict: [String: Any] = ["type": "number"]
            if let desc { dict["description"] = desc }
            if let minimum { dict["minimum"] = minimum }
            if let maximum { dict["maximum"] = maximum }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .integer(let desc, let minimum, let maximum, let defaultValue):
            var dict: [String: Any] = ["type": "integer"]
            if let desc { dict["description"] = desc }
            if let minimum { dict["minimum"] = minimum }
            if let maximum { dict["maximum"] = maximum }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .boolean(let desc, let defaultValue):
            var dict: [String: Any] = ["type": "boolean"]
            if let desc { dict["description"] = desc }
            if let defaultValue { dict["default"] = jsonValueToAny(defaultValue) }
            return dict

        case .array(let desc, let items, let maxItems):
            var dict: [String: Any] = ["type": "array"]
            if let desc { dict["description"] = desc }
            if let items { dict["items"] = buildJSONSchema(items) }
            if let maxItems { dict["maxItems"] = maxItems }
            return dict

        case .object(let desc, let properties, let required):
            var dict: [String: Any] = ["type": "object"]
            if let desc { dict["description"] = desc }
            if let properties {
                var nested: [String: Any] = [:]
                for (key, prop) in properties {
                    nested[key] = buildJSONSchema(prop)
                }
                dict["properties"] = nested
            }
            if let required { dict["required"] = required }
            return dict
        }
    }

    private static func argumentsJSONString(_ arguments: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(arguments),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = jsonValueToAny(v) }
            return dict
        }
    }
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

private struct OpenAIChoice: Decodable {
    let delta: OpenAIDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct OpenAIDelta: Decodable {
    let content: String?
    let toolCalls: [OpenAIToolCallDelta]?
    /// 推理模型的思考增量：DeepSeek / OneAPI 系用 `reasoning_content`，部分网关用 `reasoning`。
    let reasoningContent: String?
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case content, reasoning
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
    }
}

private struct OpenAIToolCallDelta: Decodable {
    let index: Int?
    let id: String?
    let function: OpenAIFunctionDelta?
}

private struct OpenAIFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

private struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}
