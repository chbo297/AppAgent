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
                // Chat Completions 的 `role:"tool"` 只接受字符串 content，图片放不进去。
                // 官方做法是紧跟一条 user 消息，用 image_url + data URL 带图。
                var toolContent = resultPart.content
                if !resultPart.images.isEmpty {
                    toolContent += "\n[\(resultPart.images.count) image(s) attached in the next message]"
                }
                result.append([
                    "role": "tool",
                    "tool_call_id": resultPart.toolCallId,
                    "content": toolContent
                ])
                if !resultPart.images.isEmpty {
                    var parts: [[String: Any]] = [[
                        "type": "text",
                        "text": "Image(s) returned by tool call \(resultPart.toolCallId)."
                    ]]
                    for image in resultPart.images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64)"]
                        ])
                    }
                    result.append(["role": "user", "content": parts])
                }
            case .toolUse:
                break
            case .hostContext(let payload):
                if !textBuffer.isEmpty {
                    textBuffer += "\n\n"
                }
                textBuffer += payload.modelText
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
            let delta = choice.payload
            if let reasoning = delta?.reasoningContent ?? delta?.reasoning, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let content = delta?.content, !content.isEmpty {
                events.append(.textDelta(content))
            }

            for toolCall in delta?.toolCalls ?? [] {
                let index = toolCall.index ?? 0
                var active = activeToolCalls[index] ?? (
                    id: nonEmpty(toolCall.id) ?? "call_\(index)",
                    name: "",
                    arguments: ""
                )
                // 续传分片里 `id` / `name` 常是**空字符串**而不是缺键（实测 GLM 系的 OneAPI
                // 端点就这样：首片给全名，后续每片都带 `"id":"","name":""`）。`if let` 挡不住
                // 空串，直接覆盖会把首片的名字擦掉，收尾时 `flushToolCalls` 又按「名字为空」
                // 整条丢掉 —— 于是 `finish_reason=tool_calls` 却解析出 0 个调用，界面上就是
                // loading 转一圈什么都没有。空串一律当「这一片没给」。
                if let id = nonEmpty(toolCall.id) {
                    active.id = id
                }
                if let name = nonEmpty(toolCall.function?.name) {
                    active.name = name
                }
                if let arguments = toolCall.function?.arguments {
                    active.arguments += arguments
                }
                activeToolCalls[index] = active
            }

            // 老式 `function_call`：并到 0 号槽，和 `tool_calls` 走同一套收尾。
            if let legacy = delta?.functionCall {
                var active = activeToolCalls[0] ?? (id: "call_0", name: "", arguments: "")
                if let name = nonEmpty(legacy.name) { active.name = name }
                if let arguments = legacy.arguments { active.arguments += arguments }
                activeToolCalls[0] = active
            }

            if let finishReason = choice.finishReason {
                switch finishReason {
                case "tool_calls", "function_call":
                    let flushed = flushToolCalls(&activeToolCalls)
                    if flushed.isEmpty {
                        // 端点说这一轮是工具调用、却没给出可用的调用。留一条日志，
                        // 否则上层只看到「空回复」，根因在诊断包里无迹可寻。
                        Logger.warning(
                            "OpenAIChatCompletions",
                            "finish_reason=\(finishReason) 但没有解析到任何工具调用，chunk=\(payload.prefix(500))"
                        )
                    }
                    events.append(contentsOf: flushed)
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

    /// 空字符串按「这一片没给这个字段」处理：流式续传分片里 `id` / `name` 经常是 `""`。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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
    let delta: OpenAIDelta?
    /// 有些 OpenAI 兼容端点在**流式**分片里用 `message` 而不是 `delta`（非标准，但确实存在）。
    /// `delta` 以前是非 Optional，这类分片会整块解码失败被静默丢掉 —— 模型带着
    /// `finish_reason: "tool_calls"` 回来、我们却一个调用都没解析到，就是这么来的。
    let message: OpenAIDelta?
    let finishReason: String?

    /// 这一片真正承载内容的那个字段。
    var payload: OpenAIDelta? { delta ?? message }

    enum CodingKeys: String, CodingKey {
        case delta, message
        case finishReason = "finish_reason"
    }
}

private struct OpenAIDelta: Decodable {
    let content: String?
    let toolCalls: [OpenAIToolCallDelta]?
    /// 老式单函数调用。新端点都用 `tool_calls`，但兼容层里仍有发这个的。
    let functionCall: OpenAIFunctionDelta?
    /// 推理模型的思考增量：DeepSeek / OneAPI 系用 `reasoning_content`，部分网关用 `reasoning`。
    let reasoningContent: String?
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case content, reasoning
        case toolCalls = "tool_calls"
        case functionCall = "function_call"
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
