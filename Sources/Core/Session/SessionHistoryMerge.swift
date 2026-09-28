import Foundation

/// Copies only historical data. System prompts, tools, grants and providers are deliberately absent.
enum SessionHistoryMerge {
    static func merge(_ sources: [SessionSnapshot]) throws
        -> (messages: [AIAgentMessage], records: [AIAgentTurnRecord]) {
        var messages: [AIAgentMessage] = []
        var records: [AIAgentTurnRecord] = []
        var nextTurn = 0

        for source in sources {
            var turns: [Int: Int] = [:]
            var legacyTurn: Int?
            var calls: [String: String] = [:]
            func mapTurn(_ old: Int) -> Int {
                if let new = turns[old] { return new }
                nextTurn += 1
                turns[old] = nextTurn
                return nextTurn
            }
            func remappedCallID(_ old: String, turn: Int) -> String {
                // Compatible endpoints sometimes reuse "call_0" on different turns.
                let key = "\(turn):\(old)"
                if let new = calls[key] { return new }
                let new = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                calls[key] = new
                return new
            }
            for message in source.messages {
                let turn: Int
                if let old = message.turnID {
                    turn = mapTurn(old)
                    legacyTurn = turn
                } else {
                    if message.isGenuineUserInput || legacyTurn == nil {
                        nextTurn += 1
                        legacyTurn = nextTurn
                    }
                    turn = legacyTurn!
                }
                let content: [AIAgentMessage.Content] = message.content.map {
                    switch $0 {
                    case .text(let text):
                        return .text(text)
                    case .toolUse(let call):
                        return .toolUse(
                            .init(
                                id: remappedCallID(call.id, turn: turn),
                                name: call.name,
                                arguments: call.arguments
                            )
                        )
                    case .toolResult(let result):
                        return .toolResult(
                            .init(
                                toolCallId: remappedCallID(result.toolCallId, turn: turn),
                                content: result.content,
                                images: result.images,
                                isError: result.isError
                            )
                        )
                    case .hostContext(let payload):
                        return .hostContext(payload)
                    }
                }
                // Block identity in this model is messageID + block index; a fresh message ID
                // also makes all block identities fresh without dropping/reordering any block.
                messages.append(
                    .init(
                        role: message.role,
                        content: content,
                        createdAt: message.createdAt,
                        turnID: turn,
                        messageType: message.messageType,
                        source: message.source,
                        displayPolicy: message.displayPolicy,
                        trigger: message.trigger,
                        eventId: message.eventId,
                        stateCursor: message.stateCursor,
                        causedByToolCallId: message.causedByToolCallId.map {
                            remappedCallID($0, turn: turn)
                        }
                    )
                )
            }
            var seenRecords = Set<Int>()
            for record in source.turnRecords ?? [] {
                guard record.isFinished else { throw SessionLifecycleError.running(source.id) }
                guard seenRecords.insert(record.turnID).inserted else {
                    throw SessionLifecycleError.invalid("Duplicate turn record in source '\(source.id)'.")
                }
                var copy = record
                copy.turnID = mapTurn(record.turnID)
                records.append(copy)
            }
        }
        return (messages, records.sorted { $0.turnID < $1.turnID })
    }
}
