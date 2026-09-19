//
//  AISession.swift
//  AppAgent
//

import Foundation

/// A single agent conversation session.
/// Pure context holder — stores conversation state, tools, and config.
/// Execution is delegated to the mounted `LLMExecutor`. iOS 15+ / macOS 12+.
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

    /// The model provider for this session. Resolved at creation time; can be re-pointed at
    /// runtime via `switchModel(...)`（切换只影响随后发起的 run）。
    @Locked
    public private(set) var provider: (any ModelProvider)?

    /// The model ID for this session (e.g., "Claude Opus 4.6").
    @Locked
    public private(set) var modelId: String?

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

    /// 当前这一轮「用户提问 → agent 答复」的编号。`addUserMessage` 时递增，
    /// agent 侧产生的消息（工具调用 / 工具结果）都打上同一个号，作为它们的归属。
    @Locked
    public private(set) var currentTurnID: Int = 0

    /// Delegation depth (0 = top-level session, 1 = sub-session, ...).
    public let delegationDepth: Int

    /// 谁来呈现「等用户拍板」的请求。默认走进程级注册表（AppAgent 面板挂载时注册进去），
    /// 测试里可以换成一个假的 responder。
    @Locked
    public var decisionResponders: DecisionResponderCentral = .default
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
        self._provider = Locked(wrappedValue: provider)
        self._modelId = Locked(wrappedValue: modelId)
        self._installedTools = Locked(wrappedValue: installedTools)
        // 从已有消息接着数，否则恢复出来的会话再来一条提问会复用第一轮的号，
        // agent 的来回就会被划到旧的一轮里去。
        self._currentTurnID = Locked(wrappedValue: messages.compactMap(\.turnID).max() ?? 0)
        self._toolPolicy = Locked(wrappedValue: nil)
        self._decisionResponders = Locked(wrappedValue: .default)
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
    ///
    /// Concurrency admission is gated here — the single authoritative entry point for
    /// starting a run. If the parallel-run limit is reached, the run is rejected: the
    /// agent's delegate is notified via `didRejectRun` and an immediately-finished empty
    /// stream is returned (no `.error` event, so the rejection does not pollute history).
    public func sendMessage(_ text: String) -> AsyncStream<AIAgentEvent> {
        if let agent = agentMask?.agent, !agent.sessionManager.canAdmitRun(for: self) {
            let limit = agent.sessionManager.governor.limit
            Logger.info("AISession", "sendMessage rejected by concurrency limit: sessionId=\(id), limit=\(limit)")
            agent.sessionDidRejectRun(self, error: AIAgentError.concurrencyLimitReached(limit: limit))
            return AsyncStream { $0.finish() }
        }
        return executor.run(text)
    }

    /// Add a user message to the conversation history. Starts a new turn.
    public func addUserMessage(_ text: String) {
        let isFirstUserMessage = !messages.contains { $0.role == .user }
        // 取号必须是一次临界区：`+= 1` 是读-改-写两次加锁，旧 run 还没排干时两条提问
        // 可能拿到同一个号，展示层就会把两轮并成一轮。
        let turnID = $currentTurnID.mutate { value -> Int in
            value += 1
            return value
        }
        messages.append(.user(text, turnID: turnID))
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
        // 灌进来的历史可能已经带着轮次号（恢复快照、压缩回写、样例对话）。计数器只往前走，
        // 否则下一条提问会复用旧号，新一轮被并进历史里的某一轮。
        let highest = new.compactMap(\.turnID).max() ?? 0
        $currentTurnID.mutate { $0 = max($0, highest) }
        updatedAt = Date()
    }

    /// Clear all messages.
    public func clearHistory() {
        messages = []
        currentTurnID = 0
        updatedAt = Date()
    }

    /// 切换本会话使用的模型（`"providerName/modelId"` 引用，由 providerCentral 解析）。
    /// 只影响之后发起的 run；正在进行的 run 继续用原模型。
    /// - Returns: 解析并切换成功返回 true；引用无法解析返回 false。
    @discardableResult
    public func switchModel(reference: String) async -> Bool {
        guard let central = agentMask?.agent?.providerCentral,
              let resolved = await central.resolve(modelReference: reference) else {
            Logger.warning("AISession", "switchModel: 无法解析模型引用 \(reference)")
            return false
        }
        provider = resolved.provider
        modelId = resolved.modelId
        updatedAt = Date()
        uiState.set(SessionUIState.activeModelKey, value: reference)
        Logger.info("AISession", "switchModel: sessionId=\(id) → \(reference)")
        AppAgentDebugLog.shared.record(
            .info,
            message: "会话切换模型 → \(reference)",
            sessionId: id,
            provider: resolved.provider.name,
            apiProtocol: resolved.provider.apiProtocol.rawValue,
            modelId: resolved.modelId
        )
        return true
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

    /// 把本 session 的工具表对齐到「这一次真正递给模型的那一份」。
    ///
    /// 模型看到的工具清单由 `LLMExecutor.availableTools` 每次迭代实时从 toolCentral
    /// 解析，而执行时的查找走 `tool(named:)` 读的是 `installedTools`。两者若不同源就会
    /// 出现「清单里有、执行时找不到」——模型照着清单调用，拿回一句 Tool not found。
    /// 所以每轮迭代前把执行表按**名字**对齐到清单：只补新增、删掉不再提供的。
    ///
    /// 注意是「对齐名字」而不是整表覆盖：`ToolCentral` 对工厂注册的工具每次解析都新建
    /// 实例，整表覆盖会把 per-session 实例在一次 run 内反复换掉，工具自己攒的状态就丢了。
    func syncInstalledTools(_ tools: [any ToolProtocol]) {
        $installedTools.mutate { installed in
            var next: [String: any ToolProtocol] = [:]
            next.reserveCapacity(tools.count)
            for tool in tools {
                next[tool.name] = installed[tool.name] ?? tool
            }
            installed = next
        }
    }

    // MARK: - 等用户拍板

    /// 请求一个需要用户拍板的决定。工具/executor 只调这一个入口，不关心谁来回答。
    ///
    /// 顺序：宿主策略（非交互，可直接定夺）→ 已注册的 responder（AppAgent 面板）
    /// → 兜底拒绝。期间 `uiState.pendingDecision` 置起，会话处于「等用户」的阻塞态；
    /// 阻塞发生在 executor 的 Task 里，不占主线程，用户可以切到别的 session。
    public func requestDecision(_ request: DecisionRequest) async -> DecisionOutcome {
        // 0. 这一轮已经被取消（用户按了停止 / 切走了 run）就别再弹卡片问人了：
        //    问出来也没人该为一个死掉的 run 拍板。
        if Task.isCancelled {
            Logger.info("AISession", "decisionSkippedRunCancelled: \(request)")
            return Self.fallbackOutcome(for: request)
        }

        // 1. 宿主策略先看一眼：企业场景可以「一律禁止，别问用户」。
        if let agent = agentMask?.agent, let delegate = agent.delegate,
           let policy = await delegate.aiAgent(agent, session: self, policyFor: request) {
            Logger.info("AISession", "decisionByHostPolicy: \(request) → \(policy)")
            return policy
        }

        // 2. 交给能呈现的人（正常就是 AppAgent 自己的对话面板）。
        let responders = decisionResponders.responders
        guard !responders.isEmpty else {
            Logger.info("AISession", "decisionDeniedNoResponder: \(request)")
            return Self.fallbackOutcome(for: request)
        }

        uiState.setPendingDecision(request)
        defer { uiState.clearPendingDecision(request) }

        for responder in responders {
            if let outcome = await responder.respond(to: request, session: self) {
                Logger.info("AISession", "decisionByResponder: \(request) → \(outcome)")
                return outcome
            }
        }
        Logger.info("AISession", "decisionDeniedNoResponderCouldPresent: \(request)")
        return Self.fallbackOutcome(for: request)
    }

    /// 没人能回答时的结果：授权类一律拒绝，澄清类当作没回答。
    private static func fallbackOutcome(for request: DecisionRequest) -> DecisionOutcome {
        switch request {
        case .privateNetworkAccess, .toolAuthorization: return .deny
        case .clarification: return .answer(nil)
        }
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
