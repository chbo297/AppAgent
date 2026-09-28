//
//  AISessionManager.swift
//  AppAgent
//

import Foundation

/// Pure session lifecycle manager.
/// Shared resources (providerCentral, toolCentral, systemPrompt) live on AIAgent.
/// AISessionManager handles creation, deletion, persistence, and lookup.
/// Thread-safe via property wrappers.
public final class AISessionManager: @unchecked Sendable {

    /// Active sessions keyed by ID.
    @Locked
    public private(set) var sessions: [String: AISession] = [:]

    /// Persistent storage backend.
    public let storage: any SessionStorage
    private let lifecycleQueue = SessionLifecycleQueue()

    /// Back-reference to the owning AIAgent.
    @WeakLocked
    public internal(set) var agent: AIAgent?

    /// Concurrency admission policy for top-level runs. MVP: fixed hard limit of 4.
    /// Sub-sessions (delegation) do not count against this limit.
    public let governor = RunGovernor(limit: 4)

    /// Number of top-level sessions (`delegationDepth == 0`) currently running an agent loop.
    /// Derived live from each executor's `isRunning` — no separate counter.
    public var runningSessionCount: Int {
        sessions.values.filter { $0.delegationDepth == 0 && $0.isRunning }.count
    }

    /// Whether a new run can be admitted for `session` under the concurrency limit.
    ///
    /// - A sub-session (delegation depth > 0) is always admitted (exempt from the limit).
    /// - A session that is already running re-runs in its own slot (always admitted).
    /// - Otherwise a new top-level run is admitted only if the running count is below the limit.
    public func canAdmitRun(for session: AISession) -> Bool {
        guard session.delegationDepth == 0 else { return true }
        return governor.canAdmit(runningCount: runningSessionCount,
                                 isAlreadyRunning: session.isRunning)
    }

    public init(storage: any SessionStorage) {
        self.storage = storage
        self._agent = WeakLocked(wrappedValue: nil)
    }

    // MARK: - Session ID Generation

    /// Generate a unique session ID, checking against existing sessions.
    ///
    /// Format: `<agentId>_YYYYMMDD_HHMMSS_<cs>_<uuid>`
    /// - `agentId`: the agent's registered name
    /// - `YYYYMMDD_HHMMSS`: creation timestamp (local timezone)
    /// - `cs`: centiseconds (00-99)
    /// - `uuid`: never reuse an archived/purged session identity
    private func generateSessionID(agentId: String, now: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
        let cs = (comps.nanosecond ?? 0) / 10_000_000

        let prefix = String(
            format: "%@_%04d%02d%02d_%02d%02d%02d_%02d",
            agentId,
            comps.year!, comps.month!, comps.day!,
            comps.hour!, comps.minute!, comps.second!,
            cs
        )

        // Uniqueness must include archived/purged IDs and concurrent creation, not only active memory.
        return "\(prefix)_\(UUID().uuidString.lowercased())"
    }

    // MARK: - AISession Lifecycle

    /// Create a new session.
    @discardableResult
    public func createSession(
        title: String = "New Chat",
        toolPolicy: ToolCentral.ToolPolicy? = nil,
        provider: (any ModelProvider)? = nil,
        modelId: String? = nil
    ) async -> AISession {
        let mask = agent?.buildMask()

        // Build policy chain: agent policy (from mask) + session policy
        var policies: [ToolCentral.ToolPolicy] = []
        if let agentPolicy = mask?.toolPolicy {
            policies.append(agentPolicy)
        }
        if let sessionPolicy = toolPolicy {
            policies.append(sessionPolicy)
        }

        var installedTools: [String: any ToolProtocol] = [:]
        if let registry = mask?.toolCentral ?? agent?.toolCentral {
            installedTools = await registry.resolveTools(policies: policies)
        }

        let agentId = agent?.id ?? "unknown"
        let sessionId = generateSessionID(agentId: agentId)

        let session = AISession(
            id: sessionId,
            title: title,
            agentMask: mask,
            installedTools: installedTools,
            provider: provider,
            modelId: modelId
        )
        session.toolPolicy = toolPolicy

        $sessions.mutate { $0[session.id] = session }
        Logger.info("AISessionManager", "createSession: id=\(session.id), title=\"\(title)\", modelId=\(modelId ?? "nil"), installedTools=\(installedTools.count)")
        return session
    }

    /// Compatibility alias: deletion is always recoverable archival.
    public func deleteSession(_ id: String) async throws {
        try await archiveSession(id)
    }

    public func archiveSession(_ id: String) async throws {
        try await lifecycleQueue.run { [self] in
            guard let session = session(id: id) else { throw SessionLifecycleError.notFound(id) }
            try session.lifecycle.suspend(session)
            do {
                try await storage.archive(session: session.toSnapshot())
            } catch {
                session.lifecycle.resume()
                throw error
            }
            _ = $sessions.mutate { $0.removeValue(forKey: id) }
        }
    }

    public func archivedSessions() async throws -> [SessionSnapshot] {
        try await lifecycleQueue.run { [self] in
            try await storage.loadArchived().filter { owns($0) }
                .sorted { ($0.archivedAt ?? $0.updatedAt) > ($1.archivedAt ?? $1.updatedAt) }
        }
    }

    public func restoreArchivedSession(_ id: String) async throws -> AISession {
        await agent?.ensureReady()
        return try await lifecycleQueue.run { [self] in
            guard sessions[id] == nil else { throw SessionLifecycleError.conflict(id) }
            guard let archived = try await storage.loadArchived().first(where: { $0.id == id && owns($0) }) else {
                throw SessionLifecycleError.notFound(id)
            }
            // Resolve current policy before committing storage. No old prompt/provider is restored.
            let session = await materialize(archived)
            _ = try await storage.restoreArchived(id: id)
            $sessions.mutate { $0[id] = session }
            return session
        }
    }

    /// Trusted manual UI entry point only. Never exposed by a model tool.
    public func purgeArchivedSession(_ id: String) async throws {
        try await lifecycleQueue.run { [self] in
            guard sessions[id] == nil else { throw SessionLifecycleError.conflict(id) }
            guard try await storage.loadArchived().contains(where: { $0.id == id && owns($0) }) else {
                throw SessionLifecycleError.notFound(id)
            }
            try await storage.purgeArchived(id: id)
        }
    }

    private func owns(_ snapshot: SessionSnapshot) -> Bool {
        guard let agent else { return snapshot.ownerAgentID == nil }
        if let owner = snapshot.ownerAgentID { return owner == agent.id }
        // Legacy snapshots only have the generated ID. Do not claim arbitrary snapshots from a
        // shared repository, and do not use a loose prefix ("a" must not claim "a_b").
        let prefix = NSRegularExpression.escapedPattern(for: agent.id)
        return snapshot.id.range(of: "^\(prefix)_[0-9]{8}_[0-9]{6}_[0-9]{3,}$",
                                 options: .regularExpression) != nil
    }

    /// Cancel all running agent loops across all sessions.
    public func cancelAllRuns() {
        for session in sessions.values {
            session.cancel()
        }
    }

    /// Restore all sessions from storage.
    public func restoreAll() async throws {
        // 内置工具的注册是 AIAgent.init 丢出去的异步 Task，没就绪就解析工具表会拿到
        // 「注册到一半」的残缺集合（靠后注册的 web_fetch / screenshot 会缺），而模型
        // 看到的清单是实时全集，于是出现「清单里有、执行时 Tool not found」。
        // `AIAgent.restoreAll` 已经等过一次，但这个方法是 public、也可能被直接调用，
        // 所以闸门放在这里才真的守得住（`ensureReady` 幂等）。
        await agent?.ensureReady()

        try await lifecycleQueue.run { [self] in
            let snapshots = try await storage.loadAll().filter { owns($0) }
            for snapshot in snapshots where sessions[snapshot.id] == nil {
                let session = await materialize(snapshot)
                $sessions.mutate { $0[session.id] = session }
            }
            Logger.info("AISessionManager", "restoreAll: loaded \(snapshots.count) owned sessions")
        }
    }

    private func materialize(_ snapshot: SessionSnapshot) async -> AISession {
        var mask = agent?.buildMask()
        if let persistedPolicy = snapshot.executionPolicy, let currentMask = mask {
            var profile = currentMask.profile
            profile.executionPolicy = persistedPolicy
            mask = AIAgentMask(
                profile: profile,
                toolPolicy: currentMask.toolPolicy,
                toolCentral: currentMask.toolCentral,
                agent: currentMask.agent
            )
        }

        // Resolve provider + model from agent for restored sessions
        let resolved = await agent?.resolveProvider()

        // 和 createSession 走同一条策略链：恢复出来的会话不该比新建的多拿工具。
        var policies: [ToolCentral.ToolPolicy] = []
        if let agentPolicy = mask?.toolPolicy { policies.append(agentPolicy) }
        var installedTools: [String: any ToolProtocol] = [:]
        if let registry = mask?.toolCentral ?? agent?.toolCentral {
            installedTools = await registry.resolveTools(policies: policies)
        }
        let session = AISession(
            id: snapshot.id, title: snapshot.title, agentMask: mask, installedTools: installedTools,
            messages: snapshot.messages, provider: resolved?.provider, modelId: resolved?.modelId,
            createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt,
            turnRecords: snapshot.turnRecords ?? [], metadata: snapshot.metadata
        )
        // 进程死过一次：标「上次中断」，不自动重放有副作用的工具。
        session.markUnfinishedTurnsAsInterrupted()
        return session
    }

    /// Find a session by ID.
    public func session(id: String) -> AISession? {
        sessions[id]
    }

    /// All sessions sorted by updatedAt descending.
    public var allSessions: [AISession] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Persistence

    /// Save a single session to storage.
    public func saveSession(_ session: AISession) async throws {
        try await lifecycleQueue.run { [self] in
            // Reject old executor tasks even after an archive was restored with the same ID.
            guard sessions[session.id] === session else { throw SessionLifecycleError.inactive(session.id) }
            try await storage.save(session: session.toSnapshot())
        }
    }

    /// Save all sessions to storage (call on app backgrounding/termination).
    public func saveAll() async throws {
        try await lifecycleQueue.run { [self] in
            for session in sessions.values {
                try await storage.save(session: session.toSnapshot())
            }
        }
    }

    /// Transactional rename: errors are visible and the in-memory title is published after saving.
    func renameSession(_ id: String, title: String) async throws {
        try await lifecycleQueue.run { [self] in
            guard let session = session(id: id) else { throw SessionLifecycleError.notFound(id) }
            let old = session.toSnapshot()
            let next = SessionSnapshot(id: old.id, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                       createdAt: old.createdAt, updatedAt: old.updatedAt,
                                       messages: old.messages, metadata: old.metadata,
                                       turnRecords: old.turnRecords,
                                       executionPolicy: old.executionPolicy,
                                       ownerAgentID: old.ownerAgentID)
            try await storage.save(session: next)
            session.rename(title)
        }
    }

    /// Creates a persisted session without publishing a half-created result on storage failure.
    func createPersistedSession(title: String, modelReference: String? = nil) async throws -> AISession {
        await agent?.ensureReady()
        return try await lifecycleQueue.run { [self] in
            let snapshot = SessionSnapshot(id: generateSessionID(agentId: agent?.id ?? "unknown"),
                                           title: title, createdAt: Date(), updatedAt: Date(),
                                           messages: [], executionPolicy: agent?.buildMask().executionPolicy,
                                           ownerAgentID: agent?.id)
            let result = await materialize(snapshot)
            if let modelReference, !(await result.switchModel(reference: modelReference)) {
                throw SessionLifecycleError.invalid("Could not resolve model '\(modelReference)'.")
            }
            try await storage.save(session: result.toSnapshot())
            $sessions.mutate { $0[result.id] = result }
            return result
        }
    }

    /// Local full-fidelity concatenation in caller-specified source order; never invokes a model.
    public func mergeSessions(_ sourceIDs: [String], title: String = "Merged Chat") async throws -> AISession {
        await agent?.ensureReady()
        return try await lifecycleQueue.run { [self] in
            guard sourceIDs.count >= 2, Set(sourceIDs).count == sourceIDs.count else {
                throw SessionLifecycleError.invalid("source_session_ids must contain at least two distinct session IDs.")
            }
            var sources: [AISession] = []
            defer { sources.forEach { $0.lifecycle.resume() } }
            for id in sourceIDs {
                guard let source = session(id: id) else { throw SessionLifecycleError.notFound(id) }
                try source.lifecycle.suspend(source)
                sources.append(source)
            }
            let merged = try SessionHistoryMerge.merge(sources.map { $0.toSnapshot() })
            let snapshot = SessionSnapshot(
                id: generateSessionID(agentId: agent?.id ?? "unknown"), title: title,
                createdAt: Date(), updatedAt: Date(), messages: merged.messages,
                metadata: ["mergedSourceSessionIDs": sourceIDs.joined(separator: ",")],
                turnRecords: merged.records,
                executionPolicy: agent?.buildMask().executionPolicy,
                ownerAgentID: agent?.id
            )
            let result = await materialize(snapshot)
            try await storage.save(session: result.toSnapshot())
            $sessions.mutate { $0[result.id] = result }
            return result
        }
    }
}
