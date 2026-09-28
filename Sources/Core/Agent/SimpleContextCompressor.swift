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

        let headUnitCount = headUnits(units)
        let head = Array(units.prefix(headUnitCount))
        let headTokens = estimateTokens(messages: head.flatMap(\.messages))
        let summaryBudget = 50
        let remainingBudget = targetTokens - headTokens - summaryBudget

        var tailUnitCount = 0
        var tailTokens = 0
        if remainingBudget > 0 {
            for unit in units.dropFirst(headUnitCount).reversed() {
                let unitTokens = estimateTokens(messages: unit.messages)
                guard tailTokens + unitTokens <= remainingBudget else {
                    break
                }
                tailTokens += unitTokens
                tailUnitCount += 1
            }
        }
        tailUnitCount = max(1, tailUnitCount)

        let coveredUnitCount = headUnitCount + tailUnitCount
        guard coveredUnitCount < units.count else {
            return pruned
        }

        let middleStart = headUnitCount
        let middleEnd = units.count - tailUnitCount
        let middleUnits = Array(units[middleStart..<middleEnd])
        let middleMessages = middleUnits.flatMap(\.messages)
        let topics = extractTopics(from: middleMessages)
        let summaryText = makeSummary(
            messageCount: middleMessages.count,
            topics: topics
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
        result.append(
            contentsOf: units
                .suffix(tailUnitCount)
                .flatMap(\.messages)
        )
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
                      result.content.count > toolResultMaxChars else {
                    return part
                }

                modified = true
                let truncated = String(result.content.prefix(toolResultMaxChars))
                    + " [truncated]"
                return .toolResult(
                    AIAgentMessage.ToolCallResult(
                        toolCallId: result.toolCallId,
                        content: truncated,
                        images: result.images,
                        isError: result.isError
                    )
                )
            }

            guard modified else {
                return message
            }

            return AIAgentMessage(
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
                stateCursor: message.stateCursor,
                causedByToolCallId: message.causedByToolCallId
            )
        }
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
                total += result.images.reduce(into: 0) { imageTotal, image in
                    imageTotal += image.base64.utf8.count
                    imageTotal += image.mediaType.utf8.count
                }
            case .hostContext(let payload):
                total += payload.modelText.utf8.count
            }
        }
    }

    private func makeSummary(messageCount: Int, topics: [String]) -> String {
        let topicText = topics.isEmpty
            ? ""
            : " Key topics discussed: \(topics.joined(separator: ", "))."
        return """
            [CONTEXT COMPACTED: \(messageCount) earlier messages were summarized.\
            \(topicText)\
             Respond ONLY to the latest user message.]
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
