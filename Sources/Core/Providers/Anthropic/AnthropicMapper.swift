//
//  AnthropicMapper.swift
//  AppAgent
//

import Foundation

/// Maps between provider-agnostic types and Anthropic wire format.
enum AnthropicMapper {

    // MARK: - Messages: Agnostic → Anthropic

    static func toAnthropicMessages(_ messages: [AIAgentMessage]) -> [AnthropicMessage] {
        messages.map { msg in
            let role = msg.role == .user ? "user" : "assistant"
            let blocks = msg.content.map(toAnthropicBlock)

            if blocks.count == 1, case .text(let tb) = blocks[0] {
                return AnthropicMessage(role: role, content: .text(tb.text))
            }
            return AnthropicMessage(role: role, content: .blocks(blocks))
        }
    }

    private static func toAnthropicBlock(_ part: AIAgentMessage.Content) -> AnthropicContentBlock {
        switch part {
        case .text(let s):
            return .text(AnthropicTextBlock(text: s))
        case .toolUse(let call):
            return .toolUse(AnthropicToolUseBlock(id: call.id, name: call.name, input: call.arguments))
        case .toolResult(let result):
            return .toolResult(AnthropicToolResultBlock(
                toolUseId: result.toolCallId,
                content: result.content,
                images: result.images.map {
                    AnthropicImageBlock(base64: $0.base64, mediaType: $0.mediaType)
                }
            ))
        }
    }

    // MARK: - System Prompt: ContentOrCacheControl → Anthropic JSON

    /// Convert system prompt segments to Anthropic system array format.
    /// Each .content becomes a { type: "text", text: "..." } block.
    /// A .cacheControl attaches cache_control to the preceding block.
    static func toAnthropicSystem(_ segments: [ContentOrCacheControl<SystemPrompt>]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        for segment in segments {
            switch segment {
            case .content(let prompt):
                blocks.append(["type": "text", "text": prompt.text])

            case .cacheControl:
                if !blocks.isEmpty {
                    blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
                }
            }
        }

        return blocks
    }

    // MARK: - Tools: ContentOrCacheControl → Anthropic JSON

    /// Convert tool segments to Anthropic tools array format.
    /// Each .content(Tool) becomes a tool definition dict.
    /// A .cacheControl attaches cache_control to the preceding tool.
    static func toAnthropicTools(_ segments: [ContentOrCacheControl<any ToolProtocol>]) -> [[String: Any]] {
        var tools: [[String: Any]] = []

        for segment in segments {
            switch segment {
            case .content(let tool):
                let toolDict: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": buildInputSchema(tool.parameters)
                ]
                tools.append(toolDict)

            case .cacheControl:
                if !tools.isEmpty {
                    tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
                }
            }
        }

        return tools
    }

    /// Build the JSON Schema dict from an Tool.Schema.
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

    /// Build a single property's JSON Schema dict from a JSONSchema enum.
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

    /// Convert JSONValue to Any for JSON serialization.
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

    // MARK: - SSE Events → Provider Events

    /// Parse an SSE event and return zero or more `ProviderStreamEvent`s.
    ///
    /// Returns an array because some SSE events (e.g. `message_delta`) can
    /// carry both a usage report and a stop reason in a single payload.
    static func parseSSEEvent(
        _ sseEvent: SSEEvent,
        activeToolCalls: inout [Int: (id: String, name: String, jsonAccumulator: String)]
    ) -> [ProviderStreamEvent] {
        let decoder = JSONDecoder()

        guard let data = sseEvent.data.data(using: .utf8) else { return [] }

        switch sseEvent.event {
        case "content_block_start":
            guard let parsed = try? decoder.decode(SSEContentBlockStart.self, from: data) else { return [] }
            if parsed.contentBlock.type == "tool_use",
               let id = parsed.contentBlock.id,
               let name = parsed.contentBlock.name {
                activeToolCalls[parsed.index] = (id: id, name: name, jsonAccumulator: "")
                Logger.debug("AnthropicMapper", "SSE content_block_start: tool_use index=\(parsed.index), id=\(id), name=\(name)")
            }
            return []

        case "content_block_delta":
            guard let parsed = try? decoder.decode(SSEContentBlockDelta.self, from: data) else { return [] }

            if parsed.delta.type == "text_delta", let text = parsed.delta.text {
                return [.textDelta(text)]
            }
            // 扩展思考：thinking_delta 只用于展示「思考过程」，不参与历史。
            if parsed.delta.type == "thinking_delta", let thinking = parsed.delta.thinking {
                return [.reasoningDelta(thinking)]
            }
            if parsed.delta.type == "input_json_delta", let json = parsed.delta.partialJson {
                activeToolCalls[parsed.index]?.jsonAccumulator += json
            }
            return []

        case "content_block_stop":
            // Check if a tool call completed at this index
            struct BlockStop: Decodable { let index: Int }
            guard let parsed = try? decoder.decode(BlockStop.self, from: data) else { return [] }

            if let toolInfo = activeToolCalls.removeValue(forKey: parsed.index) {
                let arguments: [String: JSONValue]
                if let jsonData = toolInfo.jsonAccumulator.data(using: .utf8),
                   let decoded = try? decoder.decode([String: JSONValue].self, from: jsonData) {
                    arguments = decoded
                } else {
                    arguments = [:]
                }
                Logger.debug("AnthropicMapper", "SSE content_block_stop: tool completed, name=\(toolInfo.name), id=\(toolInfo.id), argKeys=[\(arguments.keys.sorted().joined(separator: ", "))]")
                return [.toolCall(AIAgentMessage.ToolCall(id: toolInfo.id, name: toolInfo.name, arguments: arguments))]
            }
            return []

        case "message_delta":
            guard let parsed = try? decoder.decode(SSEMessageDelta.self, from: data) else { return [] }
            var events: [ProviderStreamEvent] = []

            if let usage = parsed.usage, let input = usage.inputTokens, let output = usage.outputTokens {
                Logger.debug("AnthropicMapper", "SSE message_delta: usage inputTokens=\(input), outputTokens=\(output)")
                events.append(.usage(inputTokens: input, outputTokens: output))
            }

            if let stop = parsed.delta.stopReason {
                let reason = ProviderStreamEvent.StopReason(rawValue: stop) ?? .unknown
                Logger.debug("AnthropicMapper", "SSE message_delta: stopReason=\(stop), reason=\(reason)")
                events.append(.done(stopReason: reason))
            }
            return events

        default:
            return []
        }
    }
}
