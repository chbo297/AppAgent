//
//  AnthropicMapper.swift
//  AppAgent
//

import Foundation

/// Maps between provider-agnostic types and Anthropic wire format.
enum AnthropicMapper {

    // MARK: - Messages: Agnostic → Anthropic

    static func toAnthropicMessages(_ messages: [AIAgentMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []
        for message in messages {
            let role = message.role == .user ? "user" : "assistant"
            let messageBlocks = message.content.map(toAnthropicBlock)
            guard !messageBlocks.isEmpty else {
                continue
            }

            if let lastIndex = result.indices.last,
               result[lastIndex].role == role {
                let previousBlocks = Self.blocks(from: result[lastIndex].content)
                result[lastIndex] = AnthropicMessage(
                    role: role,
                    content: .blocks(previousBlocks + messageBlocks)
                )
            } else if messageBlocks.count == 1,
                      case .text(let textBlock) = messageBlocks[0] {
                result.append(
                    AnthropicMessage(
                        role: role,
                        content: .text(textBlock.text)
                    )
                )
            } else {
                result.append(
                    AnthropicMessage(
                        role: role,
                        content: .blocks(messageBlocks)
                    )
                )
            }
        }
        return result
    }

    private static func blocks(
        from content: AnthropicMessageContent
    ) -> [AnthropicContentBlock] {
        switch content {
        case .text(let text):
            return [.text(AnthropicTextBlock(text: text))]
        case .blocks(let blocks):
            return blocks
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
        case .hostContext(let payload):
            return .text(AnthropicTextBlock(text: payload.modelText))
        case .attachment(let attachment):
            guard let image = attachment.image else {
                return .text(AnthropicTextBlock(text: attachment.modelText))
            }
            return .image(AnthropicImageBlock(base64: image.base64, mediaType: image.mediaType))
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
                    "input_schema": ToolSchemaMapper.inputSchema(tool.parameters)
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

    // MARK: - SSE Events → Provider Events

    /// Parse an SSE event and return zero or more `ProviderStreamEvent`s.
    ///
    /// Returns an array because some SSE events (e.g. `message_delta`) can
    /// carry both a usage report and a stop reason in a single payload.
    static func parseSSEEvent(
        _ sseEvent: SSEEvent,
        activeToolCalls: inout [Int: (id: String, name: String, jsonAccumulator: String)]
    ) throws -> [ProviderStreamEvent] {
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
                // A tool with no parameters may have no input_json_delta at all.
                let raw = toolInfo.jsonAccumulator.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    arguments = [:]
                } else if let jsonData = raw.data(using: .utf8),
                   let decoded = try? decoder.decode([String: JSONValue].self, from: jsonData) {
                    arguments = decoded
                } else {
                    // 参数 JSON 不完整：多半是撞到 max_tokens 被截断。先放回去，等 message_delta
                    // 的 stop_reason 再定性——是 max_tokens 就丢掉这个调用让上层续写，否则才算协议错误。
                    activeToolCalls[parsed.index] = toolInfo
                    Logger.debug("AnthropicMapper", "SSE content_block_stop: incomplete tool arguments, name=\(toolInfo.name), deferred until stop_reason")
                    return []
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
                // 还留着的都是参数不完整的调用（见 content_block_stop），一律不执行。
                if !activeToolCalls.isEmpty {
                    let names = activeToolCalls.keys.sorted().compactMap { activeToolCalls[$0]?.name }
                    activeToolCalls.removeAll()
                    guard reason == .maxTokens else {
                        throw ModelError.malformedToolCall("Anthropic 工具参数不是完整的 JSON 对象（\(names.joined(separator: ", "))）")
                    }
                    events.append(contentsOf: names.map { ProviderStreamEvent.discardedToolCall(name: $0) })
                }
                events.append(.done(stopReason: reason))
            }
            return events

        default:
            return []
        }
    }
}
