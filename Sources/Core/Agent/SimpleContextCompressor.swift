//
//  SimpleContextCompressor.swift
//  AppAgent
//

import Foundation

/// Default context compressor using a three-phase algorithm:
///
/// 1. **Prune tool results** — truncate old tool result content (keep first 200 chars).
/// 2. **Protect head + tail** — preserve the first 2 messages and last N messages.
/// 3. **Summarize middle** — replace the middle portion with a compact placeholder.
///
/// Token estimation uses a rough heuristic of ~4 UTF-8 bytes per token,
/// matching hermes-agent's `_CHARS_PER_TOKEN = 4`.
public struct SimpleContextCompressor: ContextCompressor, Sendable {

    /// Characters per token estimate.
    private static let charsPerToken = 4

    /// Number of leading messages to always preserve.
    private let headCount: Int

    /// Maximum characters to keep in truncated tool results.
    private let toolResultMaxChars: Int

    public init(headCount: Int = 2, toolResultMaxChars: Int = 200) {
        self.headCount = headCount
        self.toolResultMaxChars = toolResultMaxChars
    }

    public func estimateTokens(messages: [AIAgentMessage]) -> Int {
        var totalChars = 0
        for message in messages {
            for part in message.content {
                switch part {
                case .text(let text):
                    totalChars += text.utf8.count
                case .toolUse(let call):
                    totalChars += call.name.utf8.count
                    for (key, value) in call.arguments {
                        totalChars += key.utf8.count + String(describing: value).utf8.count
                    }
                case .toolResult(let result):
                    totalChars += result.content.utf8.count
                }
            }
        }
        return totalChars / Self.charsPerToken
    }

    public func compress(messages: [AIAgentMessage], targetTokens: Int) async -> [AIAgentMessage] {
        guard !messages.isEmpty else { return messages }

        // Phase 1: Prune old tool results
        let pruned = pruneToolResults(messages)

        // Check if pruning was enough
        if estimateTokens(messages: pruned) <= targetTokens {
            return pruned
        }

        // Phase 2 & 3: Protect head + tail, summarize middle
        let head = min(headCount, pruned.count)

        // Determine how many tail messages we can keep within budget
        let headMessages = Array(pruned.prefix(head))
        let headTokens = estimateTokens(messages: headMessages)
        let remainingBudget = targetTokens - headTokens - 50 // 50 tokens for summary placeholder

        var tailCount = 0
        var tailTokens = 0
        for msg in pruned.reversed() {
            let msgTokens = estimateTokens(messages: [msg])
            if tailTokens + msgTokens > remainingBudget {
                break
            }
            tailTokens += msgTokens
            tailCount += 1
        }
        tailCount = max(1, tailCount) // Always keep at least the last message

        // If head + tail covers everything, no compression needed
        if head + tailCount >= pruned.count {
            return pruned
        }

        let middleRange = head..<(pruned.count - tailCount)
        let middleCount = middleRange.count

        // Extract topics from middle messages for the summary
        let topics = extractTopics(from: Array(pruned[middleRange]))

        let summaryText = """
            [CONTEXT COMPACTED: \(middleCount) earlier messages were summarized.\
            \(topics.isEmpty ? "" : " Key topics discussed: \(topics.joined(separator: ", ")).")\
             Respond ONLY to the latest user message.]
            """
        let summaryMessage = AIAgentMessage(
            role: .assistant,
            content: [.text(summaryText)]
        )

        var result = Array(pruned.prefix(head))
        result.append(summaryMessage)
        result.append(contentsOf: pruned.suffix(tailCount))

        return result
    }

    // MARK: - Private

    /// Phase 1: Truncate tool result content in older messages.
    private func pruneToolResults(_ messages: [AIAgentMessage]) -> [AIAgentMessage] {
        // Only prune messages that are not in the last 4
        let protectedTail = 4
        guard messages.count > protectedTail else { return messages }

        var result = [AIAgentMessage]()
        for (index, message) in messages.enumerated() {
            if index >= messages.count - protectedTail {
                result.append(message)
                continue
            }

            var newContent = [AIAgentMessage.Content]()
            var modified = false
            for part in message.content {
                if case .toolResult(let toolResult) = part,
                   toolResult.content.count > toolResultMaxChars {
                    let truncated = String(toolResult.content.prefix(toolResultMaxChars)) + " [truncated]"
                    newContent.append(.toolResult(AIAgentMessage.ToolCallResult(
                        toolCallId: toolResult.toolCallId,
                        content: truncated
                    )))
                    modified = true
                } else {
                    newContent.append(part)
                }
            }

            if modified {
                result.append(AIAgentMessage(
                    id: message.id,
                    role: message.role,
                    content: newContent,
                    createdAt: message.createdAt
                ))
            } else {
                result.append(message)
            }
        }
        return result
    }

    /// Extract key topic words from messages for the summary placeholder.
    private func extractTopics(from messages: [AIAgentMessage]) -> [String] {
        var topics = Set<String>()
        for message in messages {
            for part in message.content {
                if case .toolUse(let call) = part {
                    topics.insert(call.name)
                }
            }
        }
        return Array(topics.sorted().prefix(5))
    }
}
