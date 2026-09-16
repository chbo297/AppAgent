//
//  SessionManageTool.swift
//  AppAgent
//
//  Lets the agent introspect and manage its own sessions: enumerate every
//  session it owns, read the full content and runtime state of any one of
//  them (including the current session), and rename a session. This is the
//  "codex-like" self-awareness capability — the agent knows which
//  conversations exist and can read across them.
//

import Foundation

public struct SessionManageTool: ToolProtocol {
    public let name = "session_manage"
    public let description = """
        Introspect and manage your own conversation sessions. Choose an 'op':
        - 'list': list every session you own (id, title, message count, created/updated time, \
        whether it is the current session, its runtime status, and whether it is currently streaming).
        - 'read': read the full message history and runtime state of one session. \
        Requires 'session_id'. Returns each message's role and text plus status/streaming/error state.
        - 'rename': rename a session. Requires 'session_id' and 'title'.
        - 'delete': delete a session permanently. Requires 'session_id'. You cannot delete \
        the session you are currently running in.
        Use this to recall what was discussed in other conversations or to organize them.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(
                description: "Operation to perform.",
                enumValues: ["list", "read", "rename", "delete"]
            ),
            "session_id": .string(description: "Target session id. Required for 'read', 'rename', 'delete'."),
            "title": .string(description: "New title. Required for 'rename'."),
            "max_messages": .integer(
                description: "For 'read': cap the number of most-recent messages returned (default 50).",
                minimum: 1,
                maximum: 500
            )
        ],
        required: ["op"]
    )
    public let group = "session"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let agent = session.agentMask?.agent else {
            return .error("Session is not attached to an agent; session management is unavailable.")
        }
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "list":
            return listSessions(agent: agent, current: session)
        case "read":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'read'.")
            }
            let cap = arguments["max_messages"]?.numberValue.map { Int($0) } ?? 50
            return readSession(id: sid, agent: agent, maxMessages: cap)
        case "rename":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'rename'.")
            }
            guard let title = arguments["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("'title' is required and must be non-empty for 'rename'.")
            }
            return await renameSession(id: sid, title: title, agent: agent)
        case "delete":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'delete'.")
            }
            return await deleteSession(id: sid, agent: agent, current: session)
        default:
            return .error("Unknown op: '\(op)'. Use 'list', 'read', 'rename', or 'delete'.")
        }
    }

    // MARK: - Runtime status

    /// A coarse, human-readable runtime status for a session, derived from its
    /// streaming / error / running state (there is no persisted status enum).
    private func status(of s: AISession) -> String {
        if s.uiState.isStreaming || s.isRunning { return "running" }
        if s.uiState.lastError != nil { return "error" }
        return "idle"
    }

    // MARK: - Ops

    private func listSessions(agent: AIAgent, current: AISession) -> Tool.Output {
        let iso = ISO8601DateFormatter()
        let items: [JSONValue] = agent.allSessions.map { s in
            .object([
                "session_id": .string(s.id),
                "title": .string(s.title),
                "message_count": .number(Double(s.messages.count)),
                "created_at": .string(iso.string(from: s.createdAt)),
                "updated_at": .string(iso.string(from: s.updatedAt)),
                "is_current": .bool(s.id == current.id),
                "status": .string(status(of: s)),
                "is_streaming": .bool(s.uiState.isStreaming)
            ])
        }
        return .json(.object([
            "count": .number(Double(items.count)),
            "current_session_id": .string(current.id),
            "sessions": .array(items)
        ]))
    }

    private func readSession(id: String, agent: AIAgent, maxMessages: Int) -> Tool.Output {
        guard let target = agent.session(id: id) else {
            return .error("No session found with id '\(id)'.")
        }
        let iso = ISO8601DateFormatter()
        let all = target.messages
        let slice = all.suffix(maxMessages)
        let messages: [JSONValue] = slice.map { msg in
            .object([
                "role": .string(msg.role == .user ? "user" : "assistant"),
                "text": .string(msg.text),
                "created_at": .string(iso.string(from: msg.createdAt))
            ])
        }
        let lastError = target.uiState.lastError?.localizedDescription
        return .json(.object([
            "session_id": .string(target.id),
            "title": .string(target.title),
            "message_count": .number(Double(all.count)),
            "returned": .number(Double(messages.count)),
            "status": .string(status(of: target)),
            "is_streaming": .bool(target.uiState.isStreaming),
            "last_error": lastError.map { JSONValue.string($0) } ?? .null,
            "messages": .array(messages)
        ]))
    }

    private func renameSession(id: String, title: String, agent: AIAgent) async -> Tool.Output {
        guard let target = agent.session(id: id) else {
            return .error("No session found with id '\(id)'.")
        }
        target.rename(title)
        try? await agent.sessionManager.saveSession(target)
        return .json(.object([
            "success": .bool(true),
            "session_id": .string(target.id),
            "title": .string(target.title)
        ]))
    }

    private func deleteSession(id: String, agent: AIAgent, current: AISession) async -> Tool.Output {
        guard agent.session(id: id) != nil else {
            return .error("No session found with id '\(id)'.")
        }
        guard id != current.id else {
            return .error("Cannot delete the current session you are running in. Switch to or create another session first.")
        }
        do {
            try await agent.deleteSession(id)
        } catch {
            return .error("Failed to delete session '\(id)': \(error.localizedDescription)")
        }
        return .json(.object([
            "success": .bool(true),
            "deleted_session_id": .string(id)
        ]))
    }
}
