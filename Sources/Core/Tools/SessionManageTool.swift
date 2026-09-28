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
        Requires 'session_id'. Page from the beginning with offset/limit (default 0/50). \
        Legacy max_messages returns a clamped recent page. Returns full content blocks and cursors. \
        Pages also respect a byte budget. An oversized message returns message_json_fragment; \
        concatenate its UTF-8 fragments using next_message_byte_offset at the same offset, \
        then follow next_offset after the last fragment.
        - 'create': create a new empty session. Optional 'title' and 'model' \
        ("providerName/modelId"); without 'model' the agent's default model is used.
        - 'switch': ask the host UI to display a session (make it the current one). Requires 'session_id'.
        - 'set_model': point a session at another model. Requires 'model'; \
        defaults to the current session when 'session_id' is omitted. Takes effect on the next turn.
        - 'models': list the model references available right now (registered providers × their models), \
        marking which one this session uses.
        - 'rename': rename a session. Requires 'session_id' and 'title'.
        - 'archive' ('delete' is an alias): recoverably archive an idle session by session_id. \
        Cannot archive your current session. No automatic expiry.
        - 'archived': list your recoverable archives.
        - 'restore': restore an archive by session_id.
        - 'merge': copy 2+ idle sessions into a NEW session in source_session_ids order. \
        Sources remain unchanged, full history is kept, no LLM is called, current agent policy is used.
        Permanent deletion and clear are unavailable. To start over use archive + create.
        Use this to recall what was discussed in other conversations, to organize them, \
        or to move work onto a different model.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(
                description: "Operation to perform.",
                enumValues: ["list", "read", "create", "switch", "set_model", "models", "rename",
                             "archive", "delete", "archived", "restore", "merge"]
            ),
            "session_id": .string(description: "Owned target session ID for read/switch/rename/archive/delete/restore."),
            "title": .string(description: "New title. Required for 'rename', optional for 'create'."),
            "model": .string(description: "Model reference \"providerName/modelId\". Required for 'set_model', optional for 'create'."),
            "source_session_ids": .array(description: "Two or more distinct owned idle session IDs for merge.",
                                         items: .string()),
            "offset": .integer(description: "Read: zero-based message index (default 0).", minimum: 0),
            "message_byte_offset": .integer(description: "Read: UTF-8 byte cursor within an oversized message's JSON. Use the returned next_message_byte_offset with the same offset.", minimum: 0),
            "limit": .integer(description: "Read: page size, default 50, clamped 1...500.", minimum: 1, maximum: 500),
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
    public let outputMaxBytes: Int? = 64 * 1024

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "list", "read", "models", "archived": return .safe
        case "create", "rename", "switch", "set_model", "merge", "restore": return .moderate
        case "clear", "delete", "archive": return .sensitive
        default: return .moderate
        }
    }

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let agent = session.agentMask?.agent else {
            return .error("Session is not attached to an agent; session management is unavailable.")
        }
        let op = arguments["op"]?.stringValue ?? ""
        let known: Set<String> = ["op", "session_id", "title", "model", "max_messages",
                                  "offset", "limit", "message_byte_offset", "source_session_ids"]
        guard arguments.keys.allSatisfy({ known.contains($0) }) else {
            return .error("Unsupported parameter. Permanent deletion is not available; delete only archives.")
        }
        for key in ["op", "session_id", "title", "model"] where arguments[key] != nil {
            guard arguments[key]?.stringValue != nil else { return .error("'\(key)' must be a string.") }
        }
        if safetyLevel(for: arguments) != .safe, SessionToolAccess.isReadOnly(session) {
            return .error("Session mutations are disabled by the current or parent session's readOnly policy.")
        }
        do {
        switch op {
        case "list":
            return listSessions(agent: agent, current: session)
        case "read":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'read'.")
            }
            return try readSession(id: sid, agent: agent, arguments: arguments)
        case "create":
            return try await createSession(
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
            let target: AISession
            if let sid = arguments["session_id"]?.stringValue {
                guard let owned = agent.session(id: sid) else {
                    return .error("No owned session found with id '\(sid)'.")
                }
                target = owned
            } else { target = session }
            return await setModel(model, on: target)
        case "models":
            return await listModels(agent: agent, current: session)
        case "clear":
            return .error("clear is disabled because it irreversibly removes history. Use archive + create instead.")
        case "rename":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'rename'.")
            }
            guard let title = arguments["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("'title' is required and must be non-empty for 'rename'.")
            }
            return try await renameSession(id: sid, title: title, agent: agent)
        case "delete", "archive":
            guard let sid = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'delete'.")
            }
            return await deleteSession(id: sid, agent: agent, current: session)
        case "archived":
            let snapshots = try await agent.sessionManager.archivedSessions()
            return .json(.object([
                "count": .number(Double(snapshots.count)),
                "sessions": .array(snapshots.map { snapshot in .object([
                    "session_id": .string(snapshot.id), "title": .string(snapshot.title),
                    "message_count": .number(Double(snapshot.messages.count)),
                    "archived_at": snapshot.archivedAt.map {
                        .string(ISO8601DateFormatter().string(from: $0))
                    } ?? .null
                ]) })
            ]))
        case "restore":
            guard let id = arguments["session_id"]?.stringValue else {
                return .error("'session_id' is required for 'restore'.")
            }
            let restored = try await agent.sessionManager.restoreArchivedSession(id)
            agent.delegate?.aiAgent(agent, didCreateSession: restored)
            return .json(.object(["success": .bool(true), "session_id": .string(restored.id)]))
        case "merge":
            guard let values = arguments["source_session_ids"]?.arrayValue,
                  values.allSatisfy({ $0.stringValue?.isEmpty == false }) else {
                return .error("'source_session_ids' must be an array of at least two session ID strings.")
            }
            let ids = values.compactMap(\.stringValue)
            guard !ids.contains(session.id) else {
                return .error("Cannot merge the current executing session; use completed source sessions.")
            }
            let merged = try await agent.sessionManager.mergeSessions(
                ids, title: arguments["title"]?.stringValue ?? "Merged Chat"
            )
            agent.delegate?.aiAgent(agent, didCreateSession: merged)
            return .json(.object(["success": .bool(true), "session_id": .string(merged.id),
                                  "source_session_ids": .array(values),
                                  "message_count": .number(Double(merged.messages.count))]))
        default:
            return .error("Unknown op: '\(op)'. Use list/read/create/switch/set_model/models/rename/archive/archived/restore/merge. Permanent deletion is unavailable.")
        }
        } catch {
            return .error("Session operation failed: \(error.localizedDescription)")
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

    private func readSession(id: String, agent: AIAgent, arguments: [String: JSONValue]) throws -> Tool.Output {
        guard let target = agent.session(id: id) else {
            return .error("No session found with id '\(id)'.")
        }
        let iso = ISO8601DateFormatter()
        let all = target.messages
        let legacy = try SessionToolAccess.integer(arguments, "max_messages", default: 50, clamp: 1...500)
        let limit = try SessionToolAccess.integer(arguments, "limit", default: legacy, clamp: 1...500)
        let requestedOffset = try SessionToolAccess.integer(arguments, "offset", default: 0)
        guard requestedOffset >= 0 else { return .error("'offset' must be nonnegative.") }
        let legacyTail = arguments["max_messages"] != nil && arguments["offset"] == nil && arguments["limit"] == nil
        let offset = min(all.count, legacyTail ? max(0, all.count - limit) : requestedOffset)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        func encodeMessage(_ msg: AIAgentMessage) throws -> JSONValue {
            let full = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(msg))
            var fields = full.objectValue ?? [:]
            fields["text"] = .string(msg.text)
            fields["created_at"] = .string(iso.string(from: msg.createdAt))
            return .object(fields)
        }
        let lastError = target.uiState.lastError?.localizedDescription
        func page(_ messages: [JSONValue]) -> Tool.Output {
            let end = offset + messages.count
            return .json(.object([
                "session_id": .string(target.id),
                "title": .string(target.title),
                "message_count": .number(Double(all.count)),
                "returned": .number(Double(messages.count)),
                "offset": .number(Double(offset)),
                "limit": .number(Double(limit)),
                "next_offset": end < all.count ? .number(Double(end)) : .null,
                "previous_offset": offset > 0 ? .number(Double(max(0, offset - limit))) : .null,
                "status": .string(status(of: target)),
                "is_streaming": .bool(target.uiState.isStreaming),
                "last_error": lastError.map { JSONValue.string($0) } ?? .null,
                "messages": .array(messages)
            ]))
        }
        func fragment(_ message: JSONValue, start: Int) throws -> Tool.Output {
            let data = try encoder.encode(message)
            guard start >= 0, start < data.count, (data[start] & 0xC0) != 0x80 else {
                throw SessionLifecycleError.invalid("'message_byte_offset' must be a valid UTF-8 boundary within the message JSON.")
            }
            // JSON escaping can expand a byte to six bytes. Leave room for the envelope as well.
            var end = start + min(8 * 1024, data.count - start)
            while end < data.count, (data[end] & 0xC0) == 0x80 { end -= 1 }
            let hasMore = end < data.count
            return .json(.object([
                "session_id": .string(target.id), "message_id": .string(all[offset].id),
                "message_count": .number(Double(all.count)), "offset": .number(Double(offset)),
                "message_byte_offset": .number(Double(start)),
                "message_json_bytes": .number(Double(data.count)),
                "message_json_fragment": .string(String(decoding: data[start..<end], as: UTF8.self)),
                "next_message_byte_offset": hasMore ? .number(Double(end)) : .null,
                "next_offset": hasMore ? .number(Double(offset))
                    : (offset + 1 < all.count ? .number(Double(offset + 1)) : .null),
                "note": .string("Concatenate message_json_fragment values before parsing JSON. While next_message_byte_offset is non-null, read the same offset with that message_byte_offset; otherwise follow next_offset.")
            ]))
        }
        if arguments["message_byte_offset"] != nil {
            let start = try SessionToolAccess.integer(arguments, "message_byte_offset", default: 0)
            guard offset < all.count else { return .error("No message exists at this offset.") }
            return try fragment(encodeMessage(all[offset]), start: start)
        }
        var messages: [JSONValue] = []
        for message in all[offset..<(offset + min(limit, all.count - offset))] {
            let full = try encodeMessage(message)
            let candidate = page(messages + [full])
            if candidate.stringValue.utf8.count > (outputMaxBytes ?? 65536) {
                if messages.isEmpty { return try fragment(full, start: 0) }
                break
            }
            messages.append(full)
        }
        return page(messages)
    }

    private func renameSession(id: String, title: String, agent: AIAgent) async throws -> Tool.Output {
        guard let target = agent.session(id: id) else {
            return .error("No session found with id '\(id)'.")
        }
        try await agent.sessionManager.renameSession(id, title: title)
        return .json(.object([
            "success": .bool(true),
            "session_id": .string(target.id),
            "title": .string(target.title)
        ]))
    }

    /// 新建会话。可指定标题与模型引用；不指定模型时用 agent 的默认模型。
    private func createSession(title: String?, model: String?, agent: AIAgent) async throws -> Tool.Output {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = try await agent.sessionManager.createPersistedSession(
            title: (name?.isEmpty == false) ? name! : "新对话",
            modelReference: model
        )
        agent.delegate?.aiAgent(agent, didCreateSession: created)
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

    private func deleteSession(id: String, agent: AIAgent, current: AISession) async -> Tool.Output {
        guard agent.session(id: id) != nil else {
            return .error("No session found with id '\(id)'.")
        }
        guard id != current.id else {
            return .error("Cannot archive the current session you are running in. Switch to or create another session first.")
        }
        do {
            try await agent.deleteSession(id)
        } catch {
            return .error("Failed to archive session '\(id)': \(error.localizedDescription)")
        }
        return .json(.object([
            "success": .bool(true),
            "deleted_session_id": .string(id),
            "archived_session_id": .string(id),
            "recoverable": .bool(true)
        ]))
    }
}
