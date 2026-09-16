//
//  OpenAIResponsesMapper.swift
//  AppAgent
//

import Foundation

/// Maps provider-agnostic types to and from the OpenAI Responses API wire format
/// (`POST /v1/responses`). Unlike Chat Completions, the Responses API uses a typed
/// `input` array (`input_text` / `output_text` / `function_call` / `function_call_output`),
/// a top-level `instructions` field for the system prompt, flat `function` tools, and a
/// typed streaming event protocol (`response.output_text.delta`, `response.function_call_arguments.delta`,
/// `response.completed`, …) instead of chat-completions choices/deltas.
///
/// Tool-call accumulation reuses `OpenAIChatCompletionsMapper.ActiveToolCall`
/// (`(id, name, arguments)`) keyed by `output_index`, so the provider can thread the same
/// accumulator dictionary through `parseProviderSSEEvent`.
enum OpenAIResponsesMapper {

    // MARK: - Request

    /// The system prompt is carried in the top-level `instructions` field, not in `input`.
    static func toInstructions(_ system: [ContentOrCacheControl<SystemPrompt>]) -> String {
        system.compactMap { segment -> String? in
            if case .content(let prompt) = segment { return prompt.text }
            return nil
        }.joined(separator: "\n\n")
    }

    static func toInput(_ messages: [AIAgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
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
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": buildInputSchema(tool.parameters)
                ])
            }
        }
        return tools
    }

    private static func appendUserMessage(_ message: AIAgentMessage, to result: inout [[String: Any]]) {
        var content: [[String: Any]] = []

        func flushContent() {
            guard !content.isEmpty else { return }
            result.append(["role": "user", "content": content])
            content = []
        }

        for part in message.content {
            switch part {
            case .text(let text):
                content.append(["type": "input_text", "text": text])
            case .toolResult(let resultPart):
                // function_call_output is a top-level input item, not nested in a role message.
                flushContent()
                result.append([
                    "type": "function_call_output",
                    "call_id": resultPart.toolCallId,
                    "output": resultPart.content
                ])
            case .toolUse:
                break
            }
        }

        flushContent()
    }

    private static func appendAssistantMessage(_ message: AIAgentMessage, to result: inout [[String: Any]]) {
        let textContent = message.content.compactMap { part -> [String: Any]? in
            guard case .text(let text) = part, !text.isEmpty else { return nil }
            return ["type": "output_text", "text": text]
        }
        if !textContent.isEmpty {
            result.append(["role": "assistant", "content": textContent])
        }

        for part in message.content {
            guard case .toolUse(let call) = part else { continue }
            result.append([
                "type": "function_call",
                "call_id": call.id,
                "name": call.name,
                "arguments": argumentsJSONString(call.arguments)
            ])
        }
    }

    // MARK: - Response

    /// Parse one Responses-API SSE event. Tool-call state is keyed by `output_index` and
    /// reuses the Chat Completions `ActiveToolCall` tuple so the provider can share one
    /// accumulator across protocols.
    static func parseSSEEvent(
        _ sseEvent: SSEEvent,
        activeToolCalls: inout [Int: OpenAIChatCompletionsMapper.ActiveToolCall]
    ) -> [ProviderStreamEvent] {
        let payload = sseEvent.data.trimmingCharacters(in: .whitespacesAndNewlines)
        // Responses API terminates with `response.completed`; `[DONE]` is only emitted by
        // some proxies. Flush any dangling tool calls defensively.
        guard payload != "[DONE]" else {
            return flushToolCalls(&activeToolCalls)
        }

        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(ResponsesStreamEvent.self, from: data) else {
            return []
        }

        switch event.type {
        case "response.output_text.delta":
            if let delta = event.delta, !delta.isEmpty {
                return [.textDelta(delta)]
            }

        case "response.output_item.added":
            if let item = event.item, item.type == "function_call" {
                let index = event.outputIndex ?? activeToolCalls.count
                activeToolCalls[index] = (
                    id: item.callId ?? item.id ?? "call_\(index)",
                    name: item.name ?? "",
                    arguments: item.arguments ?? ""
                )
            }

        case "response.function_call_arguments.delta":
            if let index = event.outputIndex, let delta = event.delta {
                var active = activeToolCalls[index] ?? (id: "call_\(index)", name: "", arguments: "")
                active.arguments += delta
                activeToolCalls[index] = active
            }

        case "response.function_call_arguments.done":
            // Backfill the full arguments string if we never saw incremental deltas.
            if let index = event.outputIndex, let arguments = event.arguments {
                var active = activeToolCalls[index] ?? (id: "call_\(index)", name: "", arguments: "")
                if active.arguments.isEmpty { active.arguments = arguments }
                activeToolCalls[index] = active
            }

        case "response.completed", "response.incomplete":
            var events: [ProviderStreamEvent] = []
            if let usage = event.response?.usage {
                events.append(.usage(
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0
                ))
            }
            let hadToolCalls = !activeToolCalls.isEmpty
            events.append(contentsOf: flushToolCalls(&activeToolCalls))
            if event.type == "response.incomplete" {
                let maxedOut = event.response?.incompleteDetails?.reason == "max_output_tokens"
                events.append(.done(stopReason: maxedOut ? .maxTokens : .unknown))
            } else if hadToolCalls {
                events.append(.done(stopReason: .toolUse))
            } else {
                events.append(.done(stopReason: .endTurn))
            }
            return events

        case "response.failed", "error":
            return [.done(stopReason: .unknown)]

        default:
            return []
        }

        return []
    }

    private static func flushToolCalls(
        _ activeToolCalls: inout [Int: OpenAIChatCompletionsMapper.ActiveToolCall]
    ) -> [ProviderStreamEvent] {
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

// MARK: - Streaming event decoding

private struct ResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let arguments: String?
    let outputIndex: Int?
    let item: ResponsesOutputItem?
    let response: ResponsesResponseObject?

    enum CodingKeys: String, CodingKey {
        case type
        case delta
        case arguments
        case outputIndex = "output_index"
        case item
        case response
    }
}

private struct ResponsesOutputItem: Decodable {
    let type: String?
    let id: String?
    let callId: String?
    let name: String?
    let arguments: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case callId = "call_id"
        case name
        case arguments
    }
}

private struct ResponsesResponseObject: Decodable {
    let status: String?
    let usage: ResponsesUsage?
    let incompleteDetails: ResponsesIncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case status
        case usage
        case incompleteDetails = "incomplete_details"
    }
}

private struct ResponsesUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct ResponsesIncompleteDetails: Decodable {
    let reason: String?
}
