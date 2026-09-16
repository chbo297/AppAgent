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

    // Session ID generation state
    @Locked private var lastPrefix: String = ""
    @Locked private var sequence: Int = 0

    public init(storage: any SessionStorage) {
        self.storage = storage
        self._agent = WeakLocked(wrappedValue: nil)
    }

    // MARK: - Session ID Generation

    /// Generate a unique session ID, checking against existing sessions.
    ///
    /// Format: `<agentId>_YYYYMMDD_HHMMSS_<cs><seq>`
    /// - `agentId`: the agent's registered name
    /// - `YYYYMMDD_HHMMSS`: creation timestamp (local timezone)
    /// - `cs`: centiseconds (00-99)
    /// - `seq`: single-digit sequence number (0-9), increments on collision
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

        if prefix == lastPrefix {
            sequence += 1
        } else {
            lastPrefix = prefix
            sequence = 0
        }

        var candidate = "\(prefix)\(sequence)"

        // Deduplicate against existing sessions
        while sessions[candidate] != nil && sequence < 9 {
            sequence += 1
            candidate = "\(prefix)\(sequence)"
        }

        // sequence == 9 and still duplicate — this is abnormal (10 sessions in the same centisecond),
        // overwrite the existing session entry as a last resort.
        if sessions[candidate] != nil {
            Logger.warning("AISessionManager", "Session ID collision at max sequence (9), overwriting: \(candidate)")
        }

        return candidate
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

        sessions[session.id] = session
        Logger.info("AISessionManager", "createSession: id=\(session.id), title=\"\(title)\", modelId=\(modelId ?? "nil"), installedTools=\(installedTools.count)")
        return session
    }

    /// Delete a session by ID.
    public func deleteSession(_ id: String) async throws {
        Logger.info("AISessionManager", "deleteSession: id=\(id)")
        if let session = sessions[id] {
            session.cancel()
        }
        sessions.removeValue(forKey: id)
        try await storage.delete(id: id)
    }

    /// Cancel all running agent loops across all sessions.
    public func cancelAllRuns() {
        for session in sessions.values {
            session.cancel()
        }
    }

    /// Restore all sessions from storage.
    public func restoreAll() async throws {
        let snapshots = try await storage.loadAll()
        let mask = agent?.buildMask()

        // Resolve provider + model from agent for restored sessions
        let resolved = await agent?.resolveProvider()

        for snapshot in snapshots {
            var installedTools: [String: any ToolProtocol] = [:]
            if let registry = mask?.toolCentral ?? agent?.toolCentral {
                installedTools = await registry.resolveTools()
            }

            let session = AISession(
                id: snapshot.id,
                title: snapshot.title,
                agentMask: mask,
                installedTools: installedTools,
                messages: snapshot.messages,
                provider: resolved?.provider,
                modelId: resolved?.modelId,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt
            )
            sessions[session.id] = session
        }
        Logger.info("AISessionManager", "restoreAll: restored \(snapshots.count) sessions")
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
        Logger.debug("AISessionManager", "saveSession: id=\(session.id), messageCount=\(session.messages.count)")
        let snapshot = session.toSnapshot()
        try await storage.save(session: snapshot)
    }

    /// Save all sessions to storage (call on app backgrounding/termination).
    public func saveAll() async throws {
        for session in sessions.values {
            try await storage.save(session: session.toSnapshot())
        }
    }
}
