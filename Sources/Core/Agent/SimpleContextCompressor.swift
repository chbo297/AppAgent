//
//  SimpleContextCompressor.swift
//  AppAgent
//

import Foundation

/// Default context compressor using transaction-aware message units.
///
/// Tool calls and their immediately following results are kept together so a
/// provider never receives a dangling tool transaction after compression.
public struct SimpleContextCompressor: ContextCompressor, Sendable {

    private static let charsPerToken = 4

    /// 一张图按 provider 实际计费估：Anthropic 约 宽×高/750，长边缩放后封顶约 1.6k tokens。
    /// 不能按 base64 长度算——真机一张 1MB 截图被估成 ~345k tokens，误触发压缩把当轮请求挤掉了。
    static let tokensPerImage = 1_600

    private let headCount: Int
    private let toolResultMaxChars: Int

    public init(headCount: Int = 2, toolResultMaxChars: Int = 200) {
        self.headCount = headCount
        self.toolResultMaxChars = toolResultMaxChars
    }

    public func estimateTokens(messages: [AIAgentMessage]) -> Int {
        let totalBytes = messages.reduce(into: 0) { total, message in
            total += estimateBytes(message)
        }
        return totalBytes / Self.charsPerToken
    }

    public func compress(
        messages: [AIAgentMessage],
        targetTokens: Int
    ) async -> [AIAgentMessage] {
        guard !messages.isEmpty else {
            return messages
        }

        let pruned = pruneToolResults(messages)
        if estimateTokens(messages: pruned) <= targetTokens {
            return pruned
        }

        let units = makeUnits(pruned)
        guard !units.isEmpty else {
            return pruned
        }

        // 开头一两条通常是任务交代，便宜就留；它本身就很大时让位给最近的内容。
        // 实测（gpt-5.6-sol，2026-11）：开头那条长材料把预算占满，最近几轮全被丢，
        // 问「最后一段的暗号」模型答成了第一段的。
        let rawHeadCount = headUnits(units)
        let rawHeadTokens = estimateTokens(messages: units.prefix(rawHeadCount).flatMap(\.messages))
        let headUnitCount = rawHeadTokens <= targetTokens / 4 ? rawHeadCount : 0
        let head = Array(units.prefix(headUnitCount))
        let headTokens = headUnitCount > 0 ? rawHeadTokens : 0
        // 用户最新一条请求必须留下：摘要只说「省略了什么」，丢了它模型就会去回答更早的话。
        let pinnedIndex = latestUserRequestUnit(units).flatMap { index in
            index >= headUnitCount ? index : nil
        }
        let pinnedTokens = pinnedIndex.map { index in
            estimateTokens(messages: units[index].messages)
        } ?? 0
        let summaryBudget = 80
        let remainingBudget = targetTokens - headTokens - pinnedTokens - summaryBudget

        // 从最新往回留，能留多少留多少；可以越过最新请求继续往前（保住前几轮的上下文）。
        var tailStart = units.count
        var tailTokens = 0
        while tailStart > headUnitCount {
            let index = tailStart - 1
            let unitTokens = index == pinnedIndex ? 0 : estimateTokens(messages: units[index].messages)
            guard tailTokens + unitTokens <= remainingBudget else {
                break
            }
            tailTokens += unitTokens
            tailStart -= 1
        }
        // 最新一个单元（通常是刚拿到的工具结果）同样必留，超预算也留：丢了它模型看不到
        // 刚调用的结果，会重复同一个调用，下一次压缩又丢，直到循环检测判失败。
        if tailStart == units.count, tailStart > headUnitCount {
            tailStart -= 1
        }

        // 最新请求落在保留窗口之外时单独留下，被丢的内容分成它前后两段。
        let pinnedOutsideTail = pinnedIndex.flatMap { index in
            index < tailStart ? index : nil
        }
        let droppedBefore = Array(units[headUnitCount..<(pinnedOutsideTail ?? tailStart)])
        let droppedAfter = pinnedOutsideTail.map { index in
            Array(units[(index + 1)..<tailStart])
        } ?? []
        guard !droppedBefore.isEmpty || !droppedAfter.isEmpty else {
            return pruned
        }

        let beforeMessages = droppedBefore.flatMap(\.messages)
        let afterMessages = droppedAfter.flatMap(\.messages)
        let summaryText = makeSummary(
            earlierCount: beforeMessages.count,
            currentTurnCount: afterMessages.count,
            topics: extractTopics(from: beforeMessages + afterMessages)
        )
        let summary = AIAgentMessage(
            role: .assistant,
            content: [.text(summaryText)],
            messageType: .assistant,
            source: .agent,
            displayPolicy: .hidden
        )

        var result = head.flatMap(\.messages)
        result.append(summary)
        if let pinnedOutsideTail {
            result.append(contentsOf: units[pinnedOutsideTail].messages)
        }
        result.append(contentsOf: units[tailStart...].flatMap(\.messages))
        return result
    }

    private struct MessageUnit: Sendable {
        let messages: [AIAgentMessage]
    }

    private func makeUnits(_ messages: [AIAgentMessage]) -> [MessageUnit] {
        var units: [MessageUnit] = []
        var index = 0

        while index < messages.count {
            let message = messages[index]
            if index + 1 < messages.count,
               message.role == .assistant,
               !message.toolCalls.isEmpty,
               messages[index + 1].role == .user,
               hasToolResult(messages[index + 1], matching: message.toolCalls) {
                units.append(
                    MessageUnit(
                        messages: [
                            message,
                            messages[index + 1]
                        ]
                    )
                )
                index += 2
                continue
            }

            units.append(MessageUnit(messages: [message]))
            index += 1
        }

        return units
    }

    private func headUnits(_ units: [MessageUnit]) -> Int {
        guard headCount > 0 else {
            return 0
        }

        var messageCount = 0
        var unitCount = 0
        for unit in units {
            messageCount += unit.messages.count
            unitCount += 1
            if messageCount >= headCount {
                break
            }
        }
        return unitCount
    }

    private func hasToolResult(
        _ message: AIAgentMessage,
        matching calls: [AIAgentMessage.ToolCall]
    ) -> Bool {
        let callIDs = Set(calls.map(\.id))
        let resultIDs: Set<String> = Set(
            message.content.compactMap { part in
                guard case .toolResult(let result) = part else {
                    return nil
                }
                return result.toolCallId
            }
        )
        return !callIDs.isEmpty && callIDs.isSubset(of: resultIDs)
    }

    private func pruneToolResults(
        _ messages: [AIAgentMessage]
    ) -> [AIAgentMessage] {
        let protectedTail = 4
        guard messages.count > protectedTail else {
            return messages
        }

        return messages.enumerated().map { index, message in
            guard index < messages.count - protectedTail else {
                return message
            }

            var modified = false
            let content = message.content.map { part in
                guard case .toolResult(let result) = part,
                      result.content.count > toolResultMaxChars || !result.images.isEmpty else {
                    return part
                }

                modified = true
                var text = result.content
                if text.count > toolResultMaxChars {
                    text = String(text.prefix(toolResultMaxChars)) + " [truncated]"
                }
                // 旧截图模型已经看过，先于文字被丢：留一句占位，告诉模型需要时重新截。
                if !result.images.isEmpty {
                    text += " [\(result.images.count) image(s) omitted to save context]"
                }
                return .toolResult(
                    AIAgentMessage.ToolCallResult(
                        toolCallId: result.toolCallId,
                        content: text,
                        isError: result.isError
                    )
                )
            }

            guard modified else {
                return message
            }

            return Self.replacingContent(of: message, with: content)
        }
    }

    /// 只保留最近 `keep` 个带图的工具结果的图片，更早的换成占位文字。
    /// 传了 `currentTurnID` 时，用户附图只保留当前轮的，更早轮次的附图同样换成占位文字。
    ///
    /// 不等压缩阈值：真机一次「看图画马」留了 7 张截图，请求体 4.7MB，单轮从 ~15s 涨到 ~75s，
    /// 而按 1.6k tokens/张估算远没到压缩线。旧截图模型已经看过，需要时让它重新截。
    /// 用户附图同理：一次发 4 张，之后每轮都整批重发约 1.3–2.7MB。会话快照里的原图不动，界面照常显示。
    public static func retainingRecentImages(
        _ messages: [AIAgentMessage],
        keep: Int,
        currentTurnID: Int? = nil
    ) -> [AIAgentMessage] {
        var remaining = max(0, keep)
        var result = messages
        for index in messages.indices.reversed() {
            let message = messages[index]
            var modified = false
            let dropsUserImages = currentTurnID.map { turnID in
                message.role == .user && message.turnID != turnID
            } ?? false
            let content = message.content.map { part -> AIAgentMessage.Content in
                if dropsUserImages, case .attachment(let attachment) = part, attachment.image != nil {
                    modified = true
                    return .text(
                        "[User attached image \"\(attachment.name)\" in an earlier turn; omitted to save context. "
                            + "Ask the user to send it again if you need to see it.]"
                    )
                }
                guard case .toolResult(let toolResult) = part, !toolResult.images.isEmpty else {
                    return part
                }
                if remaining > 0 {
                    remaining -= 1
                    return part
                }
                modified = true
                return .toolResult(
                    AIAgentMessage.ToolCallResult(
                        toolCallId: toolResult.toolCallId,
                        content: toolResult.content
                            + " [\(toolResult.images.count) image(s) omitted to save context; capture again if needed]",
                        isError: toolResult.isError
                    )
                )
            }
            if modified {
                result[index] = replacingContent(of: message, with: content)
            }
        }
        return result
    }

    private static func replacingContent(
        of message: AIAgentMessage,
        with content: [AIAgentMessage.Content]
    ) -> AIAgentMessage {
        AIAgentMessage(
            id: message.id,
            role: message.role,
            content: content,
            createdAt: message.createdAt,
            turnID: message.turnID,
            messageType: message.messageType,
            source: message.source,
            displayPolicy: message.displayPolicy,
            trigger: message.trigger,
            eventId: message.eventId,
            causedByToolCallId: message.causedByToolCallId
        )
    }

    private func estimateBytes(_ message: AIAgentMessage) -> Int {
        message.content.reduce(into: 0) { total, part in
            switch part {
            case .text(let text):
                total += text.utf8.count
            case .toolUse(let call):
                total += call.name.utf8.count
                for (key, value) in call.arguments {
                    total += key.utf8.count
                    total += String(describing: value).utf8.count
                }
            case .toolResult(let result):
                total += result.content.utf8.count
                total += result.images.count * Self.tokensPerImage * Self.charsPerToken
            case .hostContext(let payload):
                total += payload.modelText.utf8.count
            case .attachment(let attachment):
                if attachment.image != nil {
                    total += Self.tokensPerImage * Self.charsPerToken
                } else {
                    total += attachment.modelText.utf8.count
                }
            }
        }
    }

    /// 最后一个含这一轮请求原文的单元（用户原话或 App 代发的请求；不是 tool result、不是宿主上下文）。
    private func latestUserRequestUnit(_ units: [MessageUnit]) -> Int? {
        units.lastIndex { unit in
            unit.messages.contains { message in
                message.role == .user
                    && (message.source == .user || message.isAppRequest)
                    && message.content.contains { part in
                        switch part {
                        case .text, .attachment:
                            return true
                        default:
                            return false
                        }
                    }
            }
        }
    }

    private func makeSummary(earlierCount: Int, currentTurnCount: Int, topics: [String]) -> String {
        let topicText = topics.isEmpty
            ? ""
            : " Tools used in omitted steps: \(topics.joined(separator: ", "))."
        let currentText = currentTurnCount > 0
            ? " \(currentTurnCount) intermediate messages of the current request were also omitted;"
                + " re-check app state with tools instead of assuming their results."
            : ""
        return """
            [CONTEXT COMPACTED: \(earlierCount) earlier messages were omitted.\
            \(currentText)\(topicText)\
             Keep working on the user's latest request below.]
            """
    }

    private func extractTopics(from messages: [AIAgentMessage]) -> [String] {
        var topics = Set<String>()
        for message in messages {
            for call in message.toolCalls {
                topics.insert(call.name)
            }
        }
        return Array(topics.sorted().prefix(5))
    }
}
