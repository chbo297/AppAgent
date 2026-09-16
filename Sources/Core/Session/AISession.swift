//
//  AISession.swift
//  AppAgent
//

import Foundation

/// A single agent conversation session.
/// Pure context holder — stores conversation state, tools, and config.
/// Execution is delegated to the mounted `LLMExecutor`. iOS 13+ compatible.
/// Thread-safe via property wrappers.
public final class AISession: @unchecked Sendable {
    public let id: String
    public let createdAt: Date

    // MARK: - Thread-Safe Properties (backed by property wrappers)

    @TrackedLocked
    public var title: String

    @TrackedLocked
    public private(set) var updatedAt: Date

    @TrackedLocked
    public private(set) var messages: [AIAgentMessage]

    /// Immutable configuration snapshot from the AIAgent at session creation time.
    /// Also carries a weak back-reference to the source AIAgent via `agentMask.agent`.
    public let agentMask: AIAgentMask?

    /// The model provider for this session. Set at creation time.
    public let provider: (any ModelProvider)?

    /// The model ID for this session (e.g., "Claude Opus 4.6"). Set at creation time.
    public let modelId: String?

    @Locked
    public private(set) var installedTools: [String: any ToolProtocol]

    /// UI state intermediary — tools and LLMExecutor update this, UI layer observes via onChange.
    public let uiState: SessionUIState

    /// Runtime tool filtering policy for this session.
    /// Combined with agent-level policy (from mask) when resolving available tools.
    @Locked
    public var toolPolicy: ToolCentral.ToolPolicy?

    /// Session-level system prompt parts (may contain .cacheControl markers).
    @Locked
    public var promptParts: [ContentOrCacheControl<SystemPrompt>] = []

    /// Session-scoped message context providers (combined with agent-level providers).
    /// Use for conversation-specific context like active document, visible map region, etc.
    @Locked
    public var messageContextProviders: [any MessageContextProvider] = []

    /// Delegation depth (0 = top-level session, 1 = sub-session, ...).
    public let delegationDepth: Int

    /// The LLM execution engine mounted on this session.
    public private(set) var executor: LLMExecutor!

    // MARK: - Computed Properties

    /// Whether the executor is currently running.
    public var isRunning: Bool { executor.isRunning }

    // MARK: - Dirty Tracking

    /// Whether any persistable property has been modified since last `clearDirty()`.
    public var isDirty: Bool {
        _title.isDirty || _updatedAt.isDirty || _messages.isDirty
    }

    /// Clear dirty flags after successful persistence.
    public func clearDirty() {
        _title.clearDirty()
        _updatedAt.clearDirty()
        _messages.clearDirty()
    }

    public init(id: String,
         title: String = "New Chat",
         agentMask: AIAgentMask? = nil,
         installedTools: [String: any ToolProtocol] = [:],
         messages: [AIAgentMessage] = [],
         provider: (any ModelProvider)? = nil,
         modelId: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date? = nil,
         delegationDepth: Int = 0) {
        self.id = id
        self.createdAt = createdAt
        self._updatedAt = TrackedLocked(wrappedValue: updatedAt ?? createdAt, isEqual: ==)
        self._title = TrackedLocked(wrappedValue: title, isEqual: ==)
        self._messages = TrackedLocked(wrappedValue: messages)
        self.agentMask = agentMask
        self.provider = provider
        self.modelId = modelId
        self._installedTools = Locked(wrappedValue: installedTools)
        self._toolPolicy = Locked(wrappedValue: nil)
        self.uiState = SessionUIState()
        self.delegationDepth = delegationDepth
        // LLMExecutor is initialized below after all stored properties are set
        self.executor = LLMExecutor(session: self)
    }

    // MARK: - Tool Management

    /// Refresh installedTools using diff — preserves existing instances, adds new ones, removes stale ones.
    public func reinstallTools() async {
        guard let central = agentMask?.toolCentral else { return }

        var policies: [ToolCentral.ToolPolicy] = []
        if let agentPolicy = agentMask?.toolPolicy {
            policies.append(agentPolicy)
        }
        if let sessionPolicy = toolPolicy {
            policies.append(sessionPolicy)
        }

        let newTools = await central.resolveTools(policies: policies)

        var merged: [String: any ToolProtocol] = [:]
        for (name, newTool) in newTools {
            if let existing = installedTools[name] {
                merged[name] = existing
            } else {
                merged[name] = newTool
            }
        }
        installedTools = merged
    }

    // MARK: - Agent Interaction

    /// Send a message and get a stream of agent events.
    public func sendMessage(_ text: String) -> AsyncStream<AIAgentEvent> {
        executor.run(text)
    }

    /// Add a user message to the conversation history.
    public func addUserMessage(_ text: String) {
        let isFirstUserMessage = !messages.contains { $0.role == .user }
        messages.append(.user(text))
        updatedAt = Date()
        // Codex-style auto-naming: derive the session title from the first user
        // message, but only while the title is still a default placeholder so a
        // user-chosen (renamed) title is never clobbered.
        if isFirstUserMessage, Self.isDefaultTitle(title),
           let derived = Self.deriveTitle(from: text) {
            title = derived
            // Persist the freshly derived title right away so the session list
            // shows a meaningful name even before the first run completes.
            if let manager = agentMask?.agent?.sessionManager {
                let snapshot = self
                Task { try? await manager.saveSession(snapshot) }
            }
        }
    }

    /// Rename the session. Marks the session dirty so it will be persisted;
    /// does not change `updatedAt` so renaming never reorders the session list.
    public func rename(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
    }

    /// Placeholder titles that auto-naming is allowed to overwrite.
    static let defaultTitles: Set<String> = ["New Chat", "New Session", "对话", "未命名会话", ""]

    static func isDefaultTitle(_ title: String) -> Bool {
        defaultTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Derive a concise, single-line title from a user message (≤24 chars).
    static func deriveTitle(from text: String, maxLength: Int = 24) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    /// Replace the entire message history.
    public func updateMessages(_ new: [AIAgentMessage]) {
        messages = new
        updatedAt = Date()
    }

    /// Clear all messages.
    public func clearHistory() {
        messages = []
        updatedAt = Date()
    }

    /// Cancel the current agent run.
    public func cancel() {
        Logger.info("AISession", "cancel: sessionId=\(id), wasRunning=\(isRunning)")
        executor.cancel()
    }

    /// Look up a specific tool by type.
    public func tool<T: ToolProtocol>(_ type: T.Type) -> T? {
        installedTools.values.first { $0 is T } as? T
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> (any ToolProtocol)? {
        installedTools[name]
    }

    // MARK: - Persistence

    /// Create a snapshot for persistence.
    public func toSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }
}
