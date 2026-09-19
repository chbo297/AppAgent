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
        whether it is the current session, its runtime status, whether it is streaming, and its model).
        - 'read': read the full message history and runtime state of one session. \
        Requires 'session_id'. Returns each message's role and text plus status/streaming/error state.
        - 'create': create a new empty session. Optional 'title' and 'model' \
        ("providerName/modelId"); without 'model' the agent's default model is used.
        - 'switch': ask the host UI to display a session (make it the current one). Requires 'session_id'.
        - 'set_model': point a session at another model. Requires 'model'; \
        defaults to the current session when 'session_id' is omitted. Takes effect on the next turn.
        - 'models': list the model references available right now (registered providers × their models), \
        marking which one this session uses.
        - 'clear': wipe a session's message history (the session itself is kept). Requires 'session_id'.
        - 'rename': rename a session. Requires 'session_id' and 'title'.
        - 'delete': delete a session permanently. Requires 'session_id'. You cannot delete \
        the session you are currently running in.
        Use this to recall what was discussed in other conversations, to organize them, \
        or to move work onto a different model.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(
                description: "Operation to perform.",
                enumValues: ["list", "read", "create", "switch", "set_model", "models", "clear", "rename", "delete"]
            ),
            "session_id": .string(description: "Target session id. Required for 'read', 'switch', 'clear', 'rename', 'delete'."),
            "title": .string(description: "New title. Required for 'rename', optional for 'create'."),
            "model": .string(description: "Model reference \"providerName/modelId\". Required for 'set_model', optional for 'create'."),
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

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "list", "read", "models": return .safe
        case "create", "rename", "switch", "set_model": return .moderate
        case "clear", "delete": return .sensitive     // 会丢对话历史
        default: return .moderate
        }
    }

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
        case "create":
            return await createSession(
                title: arguments["title"]?.stringValue,
                model: arguments["model"]?.stringValue,
                agent: agent
            )
        case "switch":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'switch'.")
            }
            return activateSession(id: sid, agent: agent)
        case "set_model":
            guard let model = arguments["model"]?.stringValue, !model.isEmpty else {
                return .error("'model' is required for 'set_model' (format: \"providerName/modelId\").")
            }
            let target = arguments["session_id"]?.stringValue.flatMap { agent.session(id: $0) } ?? session
            return await setModel(model, on: target)
        case "models":
            return await listModels(agent: agent, current: session)
        case "clear":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'clear'.")
            }
            return await clearSession(id: sid, agent: agent)
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
            return .error("Unknown op: '\(op)'. Use 'list', 'read', 'create', 'switch', 'set_model', 'models', 'clear', 'rename', or 'delete'.")
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

    /// 会话当前使用的模型描述。会话只持有 provider 实例与 modelId，
    /// 注册名不一定等于 `provider.name`，所以额外带上协议帮助区分。
    private func modelDescription(of s: AISession) -> String {
        guard let modelId = s.modelId else { return "(未配置)" }
        guard let proto = s.provider?.apiProtocol.rawValue else { return modelId }
        return "\(modelId)@\(proto)"
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
                "is_streaming": .bool(s.uiState.isStreaming),
                "model": .string(modelDescription(of: s))
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

    /// 新建会话。可指定标题与模型引用；不指定模型时用 agent 的默认模型。
    private func createSession(title: String?, model: String?, agent: AIAgent) async -> Tool.Output {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = await agent.createSession(
            title: (name?.isEmpty == false) ? name! : "新对话",
            modelReference: model
        )
        try? await agent.sessionManager.saveSession(created)
        if let model = model, created.modelId == nil {
            return .error("Session created (\(created.id)) but model '\(model)' could not be resolved; it has no model configured.")
        }
        return .json(.object([
            "success": .bool(true),
            "session_id": .string(created.id),
            "title": .string(created.title),
            "model": .string(modelDescription(of: created))
        ]))
    }

    /// 请求宿主 UI 把某个会话切成当前展示的会话（核心无 current session 概念）。
    private func activateSession(id: String, agent: AIAgent) -> Tool.Output {
        guard agent.session(id: id) != nil else {
            return .error("No session found with id '\(id)'.")
        }
        guard let handler = agent.activateSessionHandler else {
            return .error("The host UI did not install a session activation handler; cannot switch sessions from here.")
        }
        let accepted = handler(id)
        return .json(.object([
            "success": .bool(accepted),
            "session_id": .string(id)
        ]))
    }

    /// 把某个会话指向另一个模型（下一轮生效）。
    private func setModel(_ reference: String, on target: AISession) async -> Tool.Output {
        let ok = await target.switchModel(reference: reference)
        guard ok else {
            return .error("Could not resolve model '\(reference)'. Use op='models' to see what is available.")
        }
        return .json(.object([
            "success": .bool(true),
            "session_id": .string(target.id),
            "model": .string(modelDescription(of: target)),
            "note": .string("Takes effect on the next turn; an in-flight turn keeps its current model.")
        ]))
    }

    /// 列出当前注册中心里可用的模型引用（provider 名 × 其模型）。
    private func listModels(agent: AIAgent, current: AISession) async -> Tool.Output {
        let central = agent.providerCentral
        let names = await central.registeredNames
        var items: [JSONValue] = []
        for name in names {
            guard let provider = await central.provider(named: name) else { continue }
            for spec in provider.models {
                items.append(.object([
                    "reference": .string("\(name)/\(spec.id)"),
                    "api_protocol": .string(provider.apiProtocol.rawValue),
                    "context_window": .number(Double(spec.contextWindow)),
                    "max_tokens": .number(Double(spec.maxTokens)),
                    "is_current": .bool(
                        provider.apiProtocol == current.provider?.apiProtocol && spec.id == current.modelId
                    )
                ]))
            }
        }
        let policy = agent.modelPolicy
        return .json(.object([
            "count": .number(Double(items.count)),
            "current_model": .string(modelDescription(of: current)),
            "policy_primary": policy.map { JSONValue.string($0.primary) } ?? .null,
            "policy_fallbacks": .array((policy?.fallbacks ?? []).map { JSONValue.string($0) }),
            "models": .array(items)
        ]))
    }

    /// 清空某个会话的消息历史（会话本身保留）。
    private func clearSession(id: String, agent: AIAgent) async -> Tool.Output {
        guard let target = agent.session(id: id) else {
            return .error("No session found with id '\(id)'.")
        }
        let removed = target.messages.count
        target.clearHistory()
        try? await agent.sessionManager.saveSession(target)
        return .json(.object([
            "success": .bool(true),
            "session_id": .string(target.id),
            "removed_messages": .number(Double(removed))
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
