//
//  MemoryTool.swift
//  AppAgent
//

import Foundation

/// Tool that exposes the agent's persistent memory to the LLM.
///
/// Wraps the existing `MemoryStore` for add/search/remove operations.
/// Reference: hermes-agent `memory` tool.
public struct MemoryTool: ToolProtocol {
    public let name = "memory"
    public let description = """
        Save durable information to persistent memory that survives across sessions. \
        Use action 'add' to store new facts, 'search' to recall past memories, 'remove' to delete an entry. \
        Save user preferences, environment details, and stable conventions proactively. \
        Do NOT save task progress or temporary state.
        """
    public let parameters = Tool.Schema(
        properties: [
            "action": .string(
                description: "The action to perform.",
                enumValues: ["add", "search", "remove"]
            ),
            "content": .string(
                description: "The entry content. Required for 'add'."
            ),
            "query": .string(
                description: "Search query. Required for 'search'."
            ),
            "tags": .array(
                description: "Tags for the entry (optional, for 'add').",
                items: .string()
            ),
            "id": .string(
                description: "Entry ID to remove. Required for 'remove'."
            )
        ],
        required: ["action"]
    )
    public let group: String = "core"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["action"]?.stringValue {
        case "search": return .safe
        case "add": return .moderate
        case "remove": return .sensitive
        default: return .moderate
        }
    }

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let actionStr = arguments["action"]?.stringValue else {
            return .error("Missing required parameter: action")
        }

        guard let memoryStore = session.agentMask?.agent?.memoryStore else {
            return .error("Memory store not available")
        }

        switch actionStr {
        case "add":
            guard let content = arguments["content"]?.stringValue, !content.isEmpty else {
                return .error("Missing required parameter: content (for action 'add')")
            }
            let maxLength = memoryStore.config.maxEntryLength
            if content.count > maxLength {
                return .error("Memory entry exceeds max length of \(maxLength) characters (\(content.count) provided)")
            }
            let tags = arguments["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let entry = MemoryEntry(content: content, tags: tags, source: .aiAgent)
            try await memoryStore.addLongTerm(entry)
            return .json(.object([
                "success": .bool(true),
                "id": .string(entry.id),
                "message": .string("Memory saved: \(content.prefix(100))")
            ]))

        case "search":
            guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
                return .error("Missing required parameter: query (for action 'search')")
            }
            let results = await memoryStore.searchLongTerm(query: query, limit: 10)
            if results.isEmpty {
                return .json(.object([
                    "matches": .array([]),
                    "message": .string("No memories found matching '\(query)'")
                ]))
            }
            let items: [JSONValue] = results.map { entry in
                .object([
                    "id": .string(entry.id),
                    "content": .string(entry.content),
                    "tags": .array(entry.tags.map { .string($0) })
                ])
            }
            return .json(.object(["matches": .array(items)]))

        case "remove":
            guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
                return .error("Missing required parameter: id (for action 'remove')")
            }
            guard try await memoryStore.removeLongTerm(id: id) else {
                return .error("No memory entry with id '\(id)'. Use action 'search' to look up ids first.")
            }
            return .json(.object([
                "success": .bool(true),
                "message": .string("Memory entry '\(id)' removed")
            ]))

        default:
            return .error("Unknown action: '\(actionStr)'. Use 'add', 'search', or 'remove'.")
        }
    }
}
