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
    /// **每一轮的状态只有一个来源：`turnRecords`**（Core 落盘的 `AIAgentTurnRecord`）。
    /// 「这轮跑到哪一步 / 是否还在跑 / 最终是答了还是空了还是炸了」全部从记录里读，
    /// 不再从 `uiState` 的临时字段（`isStreaming` / `lastError` / `runStage`）另开一路——
    /// 那条双源路线正是「loading 显示到上一条回复上」「转圈停不下来」「失败了界面上
    /// 什么都没有」这几个真机 bug 的共同成因。
    ///
    /// - Parameters:
    ///   - messages: 会话的完整 wire 记录（`session.messages`）。
    ///   - turnRecords: 每一轮的持久状态（`session.turnRecords`）。没有记录的轮次
    ///     （旧快照 / 灌进来的样例对话）按「已结束、无阶段信息」渲染。
    ///   - streamingText: 进行中那一轮尚未落库的正文（`uiState.streamingText`）。
    ///     只有这一项仍来自 uiState——它是还没落盘的内容本身，不是状态。
    ///   - expandedTurnIDs: 用户手动展开过的轮次。每轮结束后过程区默认折叠，但用户
    ///     自己点开的要在后续重建里保持展开。
    ///   - collapsedTurnIDs: 用户手动收起过的轮次，优先于运行中默认展开。
    ///   - alwaysShowThinkingProcess: 「总是显示思考过程」设置。默认 `true` = 老行为（成功轮
    ///     也保留过程入口）。为 `false` 时，仅对**成功完成**（`.answered`）的轮次隐藏过程入口，
    ///     只留最终结果；报错 / 取消 / 中断 / 空回合不受影响，仍保留入口。
    public static func assemble(
        _ messages: [AIAgentMessage],
        turnRecords: [Int: AIAgentTurnRecord] = [:],
        streamingText: String = "",
        expandedTurnIDs: Set<Int> = [],
        collapsedTurnIDs: Set<Int> = [],
        alwaysShowThinkingProcess: Bool = true
    ) -> [ChatMessage] {
        let turns = group(messages)
        var out: [ChatMessage] = []

        for turn in turns {
            let record = turnRecords[turn.key]
            // 「还在跑」= 这一轮有记录且还没写终局。没有记录的历史轮次一律算已结束。
            let isStreamingTurn = record.map { !$0.isFinished } ?? false
            let turnError = record?.failureMessage.map { "Error: \($0)" }

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

            let timeline = timeline(for: turn, record: record)
            // 三种轮次即便「既无正文又无 item」也必须留下来：
            // ① 正在跑的那一轮（刚提问、还没有任何产出）——丢掉它，`applyActivity` 的
            //    「最后一条 assistant 气泡」就会落到**上一轮**的回复上，loading 和过程区
            //    显示到上一条答案上面（真机实测踩过）；
            // ② 带阶段信息的一轮（指示条要有地方挂）；
            // ③ 失败的一轮（得让人看见卡在哪一步）。
            let hasStageInfo = timeline.stage != nil || timeline.failedStage != nil
            guard !text.isEmpty || !timeline.isEmpty || isStreamingTurn || hasStageInfo else { continue }

            // 已经结束、却既没正文也没过程的一轮：按终局给一句占位，否则界面上是彻底的
            // 静默（模型回了空内容 / 说要调工具却没给调用 / 用户按了停止，都会长这样）。
            if text.isEmpty, !isStreamingTurn {
                text = placeholder(for: record?.outcome, hasActivity: !timeline.isEmpty) ?? text
            }

            let status: ChatMessage.Status
            if turnError != nil {
                status = .error
            } else if isStreamingTurn {
                status = .streaming
            } else {
                status = .complete
            }

            // 是否已经开始输出「最终结果」文案：已落库的 finalText，或流式中 streamingText 已有内容。
            let finalAnswerStarted = !turn.finalText.isEmpty
                || !liveStream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // 「总是显示思考过程」关闭时，成功完成、或流式中已开始输出最终结果的轮次隐藏过程入口；
            // 报错 / 取消 / 中断 / 空回合与旧快照（nil）都保留入口。
            let isAnsweredTurn: Bool
            switch record?.outcome {
            case .answered?: isAnsweredTurn = true
            default: isAnsweredTurn = false
            }
            let hasFinalResult = isAnsweredTurn || (isStreamingTurn && finalAnswerStarted)
            let suppressResolved = hasFinalResult && !alwaysShowThinkingProcess

            // 流式期间：开始输出最终结果前默认展开思考过程；结果一开始输出就自动收起，
            // 让结果显示在收起后的过程入口下方（用户手动展开过该轮的除外）。
            let autoExpandWhileStreaming = isStreamingTurn && !finalAnswerStarted

            out.append(ChatMessage(
                role: .assistant,
                text: text,
                status: status,
                turnID: turn.key,
                // 时间线始终保留在展示快照中供状态合并使用；cell 会隐藏没有明细的
                // 已完成纯文本回复，避免显示空的「处理过程」入口。
                activity: timeline,
                // 进行中且还没有最终结果时默认展开让人看到它在干什么；一旦开始输出结果
                // 或本轮结束就自动折叠成一行摘要，除非用户自己点开过。
                isActivityExpanded: !collapsedTurnIDs.contains(turn.key)
                    && (autoExpandWhileStreaming || expandedTurnIDs.contains(turn.key)),
                suppressResolvedActivity: suppressResolved
            ))
        }

        return out
    }

    // MARK: - turnRecord → 展示层

    /// 把一轮的持久状态叠到时间线上（阶段指示条 + 失败那一格）。
    ///
    /// 流式期间 VC 的 `applyActivity` 和重建时的 `assemble` 都走这一个函数，
    /// 两条路径的口径因此不可能各说各话。
    static func apply(_ record: AIAgentTurnRecord?, to timeline: inout AppAgentActivityTimeline) {
        guard let record = record else { return }
        timeline.setStage(record.stage)
        if let failedStage = record.failedStage {
            timeline.markFailed(stage: failedStage, message: record.failureMessage ?? "")
        }
        // 已有终局但 stage 还没到 .finished（失败 / 取消 / 中断）时也要收尾，
        // 否则折叠行会一直转圈。
        if record.isFinished, timeline.isRunning {
            timeline.finish(at: record.endedAt ?? record.startedAt)
        }
        timeline.setRunMetrics(
            startedAt: record.startedAt,
            endedAt: record.isFinished ? record.endedAt : nil,
            roundCount: record.roundCount
        )
    }

    /// 终局占位文案：让用户无论成功、空、停止还是中断都能看到一个结果。
    ///
    /// 返回 nil = 不需要占位（有过程区可看，或这一轮还没有终局记录）。
    static func placeholder(for outcome: AIAgentTurnRecord.Outcome?, hasActivity: Bool) -> String? {
        switch outcome {
        case .empty, .answered:
            return "（本轮没有返回任何内容）"
        case .cancelled:
            return "（已停止）"
        case .interrupted:
            return "（上次运行被中断，未完成。可以重新提问。）"
        case .failed:
            // 失败文案由 `failureMessage` 接在正文后面，这里不再重复。
            return nil
        case nil:
            // 没有记录的历史轮次：只有连过程区都空的时候才补一句。
            return hasActivity ? nil : "（本轮没有返回任何内容）"
        }
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
        /// 按 wire 顺序保留中间发言和工具往返，不能把所有思考先排完再排工具。
        var activityContents: [(id: String, content: AIAgentMessage.Content)] = []
        /// 旧历史没有执行计数时的回退：一条 assistant 回复计一轮，多个 toolUse 不重复计。
        var assistantRoundCount: Int = 0
        var startedAt: Date
        var lastAt: Date

        var lastInterimText: String { interimTexts.last ?? "" }

        var isEmpty: Bool {
            userText == nil && interimTexts.isEmpty && finalText.isEmpty
                && activityContents.isEmpty
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
        if message.role == .assistant { turn.assistantRoundCount += 1 }
        let hasToolCalls = !message.toolCalls.isEmpty
        for (index, content) in message.content.enumerated() {
            switch content {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                // 带工具调用的那条 assistant 正文是「准备调用工具前的说明」，属于过程。
                if hasToolCalls {
                    turn.interimTexts.append(text)
                    turn.activityContents.append(("\(message.id)-\(index)", content))
                } else if turn.finalText.isEmpty {
                    turn.finalText = text
                } else {
                    // 一条消息里可以有多个 text block（也可能同一轮先后来了两条纯文本），
                    // 直接覆盖会丢正文，所以按段落接起来。
                    turn.finalText += "\n\n" + text
                }
            case .toolUse, .toolResult:
                turn.activityContents.append(("\(message.id)-\(index)", content))
            case .hostContext:
                // 宿主状态/事件消息只进模型的逻辑历史，**不进展示层**：既不是用户气泡，
                // 也不是过程明细（见 liji_server docs/HOST_APP_CONTEXT_DESIGN.md §9.3）。
                break
            }
        }
        turn.lastAt = max(turn.lastAt, message.createdAt)
    }

    // MARK: - Activity timeline

    static func timeline(for turn: Turn, record: AIAgentTurnRecord?) -> AppAgentActivityTimeline {
        // 这里**不能**对「没有思考文本也没有工具往返」的一轮提前 return：那样返回的是
        // 一条没收尾的时间线（`finishedAt == nil` ⇒ `isRunning`），折叠行会永远显示
        // 「思考中…」并一直转圈。问一句「几点了」这种一问一答的轮次正是这种形状，
        // 真机上踩过。空轮同样要走下面的 `finish(at:)`。
        var timeline = AppAgentActivityTimeline(
            startedAt: turn.startedAt, roundCount: turn.assistantRoundCount
        )
        for (id, content) in turn.activityContents {
            switch content {
            case .text(let text):
                timeline.appendRecordedThinking(text, id: id)
            case .toolUse(let call):
                timeline.setStage(.streaming)
                timeline.startTool(id: call.id, name: call.name,
                                   argumentsPreview: activityDetail(arguments: call.arguments))
            case .toolResult(let result):
                // 后续请求失败时仍保留已经执行过的工具阶段，包括从历史重建的路径。
                timeline.setStage(.tooling)
                // 压缩过上下文可能只剩结果；仍按 isError 判状态，不把缺调用等同于工具失败。
                if !timeline.items.contains(where: { $0.id == result.toolCallId && $0.kind == .tool }) {
                    timeline.startTool(id: result.toolCallId, name: "tool", argumentsPreview: "")
                }
                // 失败与否只看 `isError`：不嗅 `Error:` 前缀（那串文案是给模型看的，
                // 正常返回的正文也可能这么开头）。
                if result.isError {
                    timeline.failTool(id: result.toolCallId, name: "tool", message: result.content)
                } else {
                    timeline.finishTool(id: result.toolCallId, resultPreview: result.content)
                }
            case .hostContext:
                // append(_:to:) 不会把宿主状态消息放进 activityContents，这里只是把分支补全，
                // 保证以后真有人塞进来也不会被渲染成过程明细。
                break
            }
        }

        // 有记录时必须先应用失败阶段再收尾；提前 finish 会把 furthestStage 错推到完成。
        // 无记录的旧历史仍按消息时间收尾，空时间线也不能遗漏。
        if let record {
            apply(record, to: &timeline)
        } else {
            timeline.finish(at: turn.lastAt)
        }
        return timeline
    }

    // MARK: - Activity content / display preview

    static func activityDetail(arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "" }
        return arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(jsonText($0.value))" }
            .joined(separator: ", ")
    }

    /// 只在折叠视图裁剪预览。原始错误/换行必须留着，否则点击展开也看不到真正原因。
    static func activityDetail(output: Tool.Output) -> String {
        switch output {
        case .text(let text): return text
        case .json(let value): return jsonText(value)
        case .error(let message): return message
        case .image(let image): return "🖼 \(image.caption)"
        }
    }

    private static func jsonText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}

#endif
