//
//  SessionSearchTool.swift
//  AppAgent
//

import Foundation

/// Tool for searching past conversation sessions.
///
/// Reference: hermes-agent `session_search` tool.
public struct SessionSearchTool: ToolProtocol {
    public let name = "session_search"

    private static let isoFormatter = ISO8601DateFormatter()
    public let description = """
        Search past conversation sessions or browse recent sessions. \
        With no query: returns recent sessions with titles and timestamps. \
        With a query: searches message content across all past sessions. \
        Use this proactively when the user references something from a past conversation.
        """
    public let parameters = Tool.Schema(
        properties: [
            "query": .string(
                description: "Search keywords. Omit to browse recent sessions."
            ),
            "limit": .integer(
                description: "Maximum sessions to return (default: 5).",
                maximum: 10,
                defaultValue: .number(5)
            )
        ],
        required: []
    )
    public let group: String = "session"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let agent = session.agentMask?.agent else {
            return .error("No agent available for session search.")
        }

        let limit = Int(arguments["limit"]?.numberValue ?? 5)
        let query = arguments["query"]?.stringValue

        let allSessions = agent.allSessions

        if let query, !query.isEmpty {
            // Search mode: find sessions containing the query in message text
            let lowered = query.lowercased()
            var matches: [JSONValue] = []

            for s in allSessions {
                guard matches.count < limit else { break }
                // Skip the current session
                if s.id == session.id { continue }

                let matchingMessages = s.messages.filter { msg in
                    msg.text.lowercased().contains(lowered)
                }

                if !matchingMessages.isEmpty {
                    let preview = matchingMessages.first?.text.prefix(200) ?? ""
                    matches.append(.object([
                        "session_id": .string(s.id),
                        "title": .string(s.title),
                        "updated_at": .string(Self.isoFormatter.string(from: s.updatedAt)),
                        "match_count": .number(Double(matchingMessages.count)),
                        "preview": .string(String(preview))
                    ]))
                }
            }

            return .json(.object([
                "query": .string(query),
                "matches": .array(matches),
                "count": .number(Double(matches.count))
            ]))
        } else {
            // Browse mode: return recent sessions
            let recent = allSessions
                .filter { $0.id != session.id }
                .prefix(limit)

            let items: [JSONValue] = recent.map { s in
                let lastMessage = s.messages.last?.text.prefix(200) ?? ""
                return .object([
                    "session_id": .string(s.id),
                    "title": .string(s.title),
                    "updated_at": .string(ISO8601DateFormatter().string(from: s.updatedAt)),
                    "message_count": .number(Double(s.messages.count)),
                    "preview": .string(String(lastMessage))
                ])
            }

            return .json(.object([
                "sessions": .array(items),
                "count": .number(Double(items.count))
            ]))
        }
    }
}
