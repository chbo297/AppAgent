//
//  SessionTool.swift
//  AppAgent
//

import Foundation

/// Unified session discovery, search, and lifecycle tool.
///
/// The model sees one session capability. Internally the read/search and lifecycle
/// implementations remain separate so persistence and UI mutation rules stay local.
public struct SessionTool: ToolProtocol {
    public let name = "session"
    public let description = """
        Discover, search, and manage AppAgent sessions. Use op='search' to find \
        previous conversation content, op='list' to browse sessions, and the other \
        operations to read, create, switch, rename, archive, restore, or merge sessions.
        Use op='models' for the current session's model, protocol and sanitized base/request URLs. \
        URLs omit credentials, query and fragment; unsafe or unknown URLs are null. \
        Request URLs describe the current configuration, not a past request or redirect. \
        API keys and authentication headers are not returned.
        Use op='chat_panel' with state collapsed / half / full to set how far this conversation's chat panel \
        opens (the workspace has its own workspace tool).
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(
                description: "Operation.",
                enumValues: [
                    "search", "list", "read", "create", "switch", "set_model", "models",
                    "rename", "archive", "delete", "archived", "restore", "merge", "chat_panel"
                ],
                defaultValue: .string("list")
            ),
            "query": .string(description: "Search text for op='search'."),
            "session_id": .string(description: "Target session ID."),
            "title": .string(description: "Session title for create or rename."),
            "model": .string(description: "providerName/modelId model reference."),
            "source_session_ids": .array(
                description: "Two or more source IDs for merge.",
                items: .string()
            ),
            "offset": .integer(description: "Zero-based message offset for read.", minimum: 0),
            "message_byte_offset": .integer(
                description: "UTF-8 byte offset for a fragmented message.",
                minimum: 0
            ),
            "limit": .integer(
                description: "Maximum result count or page size. op='search' returns 1-10 results (default 5).",
                minimum: 1,
                maximum: 500,
                defaultValue: .number(50)
            ),
            "max_messages": .integer(
                description: "Legacy tail page size for read.",
                minimum: 1,
                maximum: 500
            ),
            "state": .string(
                description: "op='chat_panel': collapsed (input bar only), half or full.",
                enumValues: SessionChatPanel.allCases.map(\.rawValue)
            )
        ],
        required: []
    )
    public let group = ToolGroups.session
    public let safetyLevel: Tool.SafetyLevel = .safe
    public let outputMaxBytes: Int? = 64 * 1024

    public init() {}

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue ?? "list" {
        case "search", "list", "read", "models", "archived":
            return .safe
        case "create", "rename", "switch", "set_model", "merge", "restore", "chat_panel":
            return .moderate
        case "delete", "archive":
            return .sensitive
        default:
            return .sensitive
        }
    }

    public func execute(
        arguments: [String: JSONValue],
        session: AISession
    ) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? "list"
        if op == "search" {
            var searchArguments = arguments
            searchArguments.removeValue(forKey: "op")
            return try await SessionSearchExecutor().execute(
                arguments: searchArguments,
                session: session
            )
        }
        if op == "chat_panel" {
            var panelArguments = arguments
            panelArguments.removeValue(forKey: "op")
            return try await SessionChatPanelExecutor().execute(
                arguments: panelArguments,
                session: session
            )
        }
        var manageArguments = arguments
        if op == "list" {
            manageArguments["op"] = .string("list")
        }
        return try await SessionLifecycleExecutor().execute(
            arguments: manageArguments,
            session: session
        )
    }
}
