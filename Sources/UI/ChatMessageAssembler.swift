//
//  ChatMessageAssembler.swift
//  AppAgentUI
//
//  把「与大模型的完整往返记录」整理成「用户视角的对话列表」。
//
//  这两层不是一回事，混在一起就会出问题：
//   - wire 层（`AIAgentMessage`）：一次提问会展开成多轮 assistant ↔ tool 往返，
//     而且工具结果在协议上必须是 user 角色。这是**给模型看的**。
//   - 展示层（`ChatMessage`）：一次提问 = 一个用户气泡 + 一个 agent 气泡。
//     agent 内部的多轮往返属于它自己的处理过程，收进那个气泡的过程区，
//     结束后折叠成一行，点开才看全过程。这是**给用户看的**。
//
//  归属关系取自 Core 打好的 `AIAgentMessage.turnID`，不靠位置猜：工具结果与
//  中间轮次的 assistant 消息都带着发起它们的那个 turnID，所以哪怕上下文压缩
//  改写过消息列表，也不会把过程错挂到别的提问下面。
//
//  旧快照（turnID 为 nil）按顺序回退：带 toolResult 的 user 消息永远不是用户输入，
//  落进当前这一轮的过程里。
//

#if canImport(UIKit)
import Foundation

public enum ChatMessageAssembler {

    /// 组装可见列表。
    ///
    /// - Parameters:
    ///   - messages: 会话的完整 wire 记录（`session.messages`）。
    ///   - streamingText: 进行中那一轮尚未落库的正文（`uiState.streamingText`）。
    ///   - isRunning: 会话是否正在跑。
    ///   - errorText: 本轮的失败原因（`uiState.lastError`）。错误不进 wire 记录，
    ///     所以必须从这里带进来挂到最后一轮上——否则「没配 API Key / 没有 provider」
    ///     这种一步都没跑起来的失败会因为该轮既无正文又无过程而被整轮丢掉，界面上
    ///     什么都不显示。
    ///   - expandedTurnIDs: 用户手动展开过的轮次。每轮结束后过程区默认折叠，但用户
    ///     自己点开的要在后续重建里保持展开。
    public static func assemble(
        _ messages: [AIAgentMessage],
        streamingText: String = "",
        isRunning: Bool = false,
        errorText: String? = nil,
        expandedTurnIDs: Set<Int> = []
    ) -> [ChatMessage] {
        let turns = group(messages)
        var out: [ChatMessage] = []

        for (offset, turn) in turns.enumerated() {
            let isLastTurn = offset == turns.count - 1
            let isStreamingTurn = isRunning && isLastTurn
            // 错误只属于最后一轮：更早的轮次已经有自己的结局了。
            let turnError = isLastTurn ? errorText : nil

            if let userText = turn.userText {
                out.append(ChatMessage(role: .user, text: userText, turnID: turn.key))
            }

            // 流式文本只属于正在跑的那一轮，且只在它还没落进记录时补上。
            let liveStream = isStreamingTurn && turn.finalText.isEmpty ? streamingText : ""
            // 正文优先级：本轮的最终答案 → 进行中的流式文本 → 还没有最终答案时用最后一段中间发言垫着。
            var text: String
            if !turn.finalText.isEmpty {
                text = turn.finalText
            } else if !liveStream.isEmpty {
                text = liveStream
            } else {
                text = turn.lastInterimText
            }

            // 失败信息接在已经吐出来的正文后面，不覆盖：半截答案本身也是线索。
            if let turnError = turnError, !turnError.isEmpty {
                text = text.isEmpty ? turnError : text + "\n\n" + turnError
            }

            let timeline = timeline(for: turn, isRunning: isStreamingTurn)
            guard !text.isEmpty || !timeline.isEmpty else { continue }

            let status: ChatMessage.Status
            if turnError != nil {
                status = .error
            } else if isStreamingTurn {
                status = .streaming
            } else {
                status = .complete
            }

            out.append(ChatMessage(
                role: .assistant,
                text: text,
                status: status,
                turnID: turn.key,
                activity: timeline.isEmpty ? nil : timeline,
                // 进行中默认展开让人看到它在干什么；本轮结束后自动折叠成一行摘要，
                // 除非用户自己点开过。
                isActivityExpanded: isStreamingTurn || expandedTurnIDs.contains(turn.key)
            ))
        }

        return out
    }

    // MARK: - Turn grouping

    /// 一轮「用户提问 → agent 答复」。
    struct Turn {
        var key: Int
        var userText: String?
        /// agent 在工具调用前的中间发言（属于过程，不是最终答案）。
        var interimTexts: [String] = []
        /// 最终答案：最后一条不含工具调用的 assistant 正文。
        var finalText: String = ""
        var calls: [(call: AIAgentMessage.ToolCall, result: AIAgentMessage.ToolCallResult?)] = []
        /// 结果先于调用出现（上下文压缩裁掉过调用）时单独留着，别丢。
        var orphanResults: [AIAgentMessage.ToolCallResult] = []
        var startedAt: Date
        var lastAt: Date

        var lastInterimText: String { interimTexts.last ?? "" }

        var isEmpty: Bool {
            userText == nil && interimTexts.isEmpty && finalText.isEmpty
                && calls.isEmpty && orphanResults.isEmpty
        }
    }

    static func group(_ messages: [AIAgentMessage]) -> [Turn] {
        var turns: [Turn] = []

        for message in messages {
            if message.isGenuineUserInput {
                // 只有真的用户发言才开新的一轮。turnID 缺失（旧快照）时接着上一个编号。
                let key = message.turnID ?? ((turns.last?.key ?? 0) + 1)
                turns.append(Turn(key: key, userText: message.text,
                                  startedAt: message.createdAt, lastAt: message.createdAt))
                continue
            }

            guard !turns.isEmpty else {
                // 记录开头就是 agent 消息（异常数据）：开一个没有提问的轮次兜住它。
                turns.append(Turn(key: 0, userText: nil,
                                  startedAt: message.createdAt, lastAt: message.createdAt))
                append(message, to: &turns[turns.count - 1])
                continue
            }

            // 有归属就精确落位，否则落在当前这一轮。
            if let id = message.turnID,
               let index = turns.lastIndex(where: { $0.key == id }) {
                append(message, to: &turns[index])
            } else {
                append(message, to: &turns[turns.count - 1])
            }
        }

        return turns.filter { !$0.isEmpty }
    }

    private static func append(_ message: AIAgentMessage, to turn: inout Turn) {
        let hasToolCalls = !message.toolCalls.isEmpty
        for content in message.content {
            switch content {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                // 带工具调用的那条 assistant 正文是「准备调用工具前的说明」，属于过程。
                if hasToolCalls {
                    turn.interimTexts.append(text)
                } else if turn.finalText.isEmpty {
                    turn.finalText = text
                } else {
                    // 一条消息里可以有多个 text block（也可能同一轮先后来了两条纯文本），
                    // 直接覆盖会丢正文，所以按段落接起来。
                    turn.finalText += "\n\n" + text
                }
            case .toolUse(let call):
                turn.calls.append((call, nil))
            case .toolResult(let result):
                if let index = turn.calls.lastIndex(where: { $0.call.id == result.toolCallId }) {
                    turn.calls[index].result = result
                } else {
                    turn.orphanResults.append(result)
                }
            }
        }
        turn.lastAt = max(turn.lastAt, message.createdAt)
    }

    // MARK: - Activity timeline

    static func timeline(for turn: Turn, isRunning: Bool) -> AppAgentActivityTimeline {
        guard !turn.interimTexts.isEmpty || !turn.calls.isEmpty || !turn.orphanResults.isEmpty else {
            return AppAgentActivityTimeline(startedAt: turn.startedAt)
        }

        var timeline = AppAgentActivityTimeline(startedAt: turn.startedAt)
        for text in turn.interimTexts {
            timeline.appendThinking(text)
        }
        for entry in turn.calls {
            timeline.startTool(
                id: entry.call.id,
                name: entry.call.name,
                argumentsPreview: preview(arguments: entry.call.arguments)
            )
            if let result = entry.result {
                // 失败与否只看 `isError`：不嗅 `Error:` 前缀（那串文案是给模型看的，
                // 正常返回的正文也可能这么开头）。
                if result.isError {
                    timeline.failTool(id: entry.call.id, name: entry.call.name,
                                      message: preview(text: result.content))
                } else {
                    timeline.finishTool(id: entry.call.id, resultPreview: preview(text: result.content))
                }
            }
        }
        for result in turn.orphanResults {
            timeline.failTool(id: result.toolCallId, name: "tool", message: preview(text: result.content))
        }

        // 时间线本身的起止取自消息时间戳，而不是「渲染这一刻」——否则恢复出来的
        // 历史会显示成「已思考 0.0 秒」。进行中的一轮故意不收尾，好让折叠行显示
        // 「思考中… / 执行 x…」。
        if !isRunning {
            timeline.finish(at: turn.lastAt)
        }
        return timeline
    }

    // MARK: - Preview helpers

    static func preview(arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "" }
        let text = arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(compact(String(describing: $0.value)))" }
            .joined(separator: ", ")
        return compact(text)
    }

    static func preview(text: String) -> String {
        compact(text)
    }

    static func preview(output: Tool.Output) -> String {
        switch output {
        case .text(let text): return compact(text)
        case .json(let value): return compact(String(describing: value))
        case .error(let message): return "错误：\(compact(message))"
        case .image(let image): return compact("🖼 \(image.caption)")
        }
    }

    static func compact(_ text: String, limit: Int = 160) -> String {
        let single = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count <= limit ? single : String(single.prefix(limit)) + "…"
    }
}

#endif
