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
    public struct ModelSelection: Sendable {
        public let provider: (any ModelProvider)?
        public let modelId: String?
        public let generation: UInt64

        init(
            provider: (any ModelProvider)?,
            modelId: String?,
            generation: UInt64
        ) {
            self.provider = provider
            self.modelId = modelId
            self.generation = generation
        }
    }

    public let id: String
    public let createdAt: Date
    let lifecycle = SessionLifecycleState()
    public let metadata: [String: String]?

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

    /// Effective execution policy for this session.
    ///
    /// Managed sessions receive a frozen policy from `agentMask`. Detached
    /// sessions created explicitly for tests or utility code use the SDK
    /// defaults.
    public var executionPolicy: AIAgentExecutionPolicy {
        agentMask?.executionPolicy ?? .default
    }

    /// The model provider for this session. Resolved at creation time; can be re-pointed at
    /// runtime via `switchModel(...)`（切换只影响随后发起的 run）。
    public var provider: (any ModelProvider)? {
        modelSelection.provider
    }

    /// The model ID for this session (e.g., "Claude Opus 4.6").
    public var modelId: String? {
        modelSelection.modelId
    }

    /// Atomically read the provider/model pair used by one run.
    public func modelSelectionSnapshot() -> ModelSelection {
        modelSelection
    }

    @Locked
    private var modelSelection: ModelSelection

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

    /// 每一轮的阶段与终局（按 turnID 索引），**随快照落盘**。见 `AIAgentTurnRecord`。
    ///
    /// UI 的 loading / 阶段指示条 / 终态（有回复 · 空 · 失败 · 已停止 · 上次中断）全读这里，
    /// 不再依赖进程内的 `uiState`——切会话、重建列表、重启 App 看到的都是同一份事实。
    @TrackedLocked
    public private(set) var turnRecords: [Int: AIAgentTurnRecord] = [:]

    /// Delegation depth (0 = top-level session, 1 = sub-session, ...).
    public let delegationDepth: Int

    /// 谁来呈现「等用户拍板」的请求。默认走进程级注册表（AppAgent 面板挂载时注册进去），
    /// 测试里可以换成一个假的 responder。
    @Locked
    public var decisionResponders: DecisionResponderCentral = .default

    /// Delegated requests retain their parent boundary and use the root's responders.
    /// Set before starting the child; an in-flight decision rejects reparenting.
    @Locked
    public var decisionParent: AISession? = nil

    /// Host-selected scene, frozen by the turn authorization (not model-controlled).
    @Locked
    public var inspectionSceneIdentifier: String? = nil

    /// A hard host opt-out, checked on both sides of every SDK authorization await.
    @Locked
    public var allowsAppAgentInspection: Bool = true

    /// The LLM execution engine mounted on this session.
    public private(set) var executor: LLMExecutor!

    /// Session-owned mirror of the host application's structured runtime state.
    ///
    /// The host provider may be shared by multiple sessions, but this mirror and
    /// its model-seen cursor belong exclusively to this session.
    public let hostStateMirror: HostStateMirror

    // MARK: - Computed Properties

    /// Whether the executor is currently running.
    public var isRunning: Bool { executor.isRunning }

    // MARK: - Dirty Tracking

    /// Whether any persistable property has been modified since last `clearDirty()`.
    public var isDirty: Bool {
        _title.isDirty || _updatedAt.isDirty || _messages.isDirty || _turnRecords.isDirty
    }

    /// Clear dirty flags after successful persistence.
    public func clearDirty() {
        _title.clearDirty()
        _updatedAt.clearDirty()
        _messages.clearDirty()
        _turnRecords.clearDirty()
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
         turnRecords: [AIAgentTurnRecord] = [],
         delegationDepth: Int = 0,
         metadata: [String: String]? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.metadata = metadata
        self._updatedAt = TrackedLocked(wrappedValue: updatedAt ?? createdAt, isEqual: ==)
        self._title = TrackedLocked(wrappedValue: title, isEqual: ==)
        self._messages = TrackedLocked(wrappedValue: messages)
        self.agentMask = agentMask
        self._modelSelection = Locked(
            wrappedValue: ModelSelection(
                provider: provider,
                modelId: modelId,
                generation: 0
            )
        )
        self._installedTools = Locked(wrappedValue: installedTools)
        // 从已有消息接着数，否则恢复出来的会话再来一条提问会复用第一轮的号，
        // agent 的来回就会被划到旧的一轮里去。
        self._currentTurnID = Locked(wrappedValue: max(messages.compactMap(\.turnID).max() ?? 0,
                                                       turnRecords.map(\.turnID).max() ?? 0))
        self._turnRecords = TrackedLocked(
            wrappedValue: Dictionary(turnRecords.map { ($0.turnID, $0) }, uniquingKeysWith: { _, last in last })
        )
        self._toolPolicy = Locked(wrappedValue: nil)
        self._decisionResponders = Locked(wrappedValue: .default)
        self.hostStateMirror = HostStateMirror()
        self.uiState = SessionUIState()
        self.delegationDepth = delegationDepth
        // LLMExecutor is initialized below after all stored properties are set
        self.executor = LLMExecutor(session: self)
    }

    // MARK: - Host Context

    /// Install a host state provider and load its first complete snapshot.
    ///
    /// Updates are consumed continuously. A revision gap or epoch change causes
    /// an automatic snapshot refresh before consumption continues.
    @discardableResult
    public func installHostStateProvider(
        _ provider: any HostStateProvider
    ) async throws -> Bool {
        try await hostStateMirror.installProvider(provider)
    }

    /// Stop consuming host updates while retaining the last mirrored snapshot.
    public func removeHostStateProvider() async {
        await hostStateMirror.removeProviderGeneration()
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
        return lifecycle.start { executor.run(text) }
    }

    /// Add a user message to the conversation history. Starts a new turn.
    /// Returns the allocated turn ID so a run never has to read a later run's current ID.
    @discardableResult
    public func addUserMessage(_ text: String) -> Int {
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
        return turnID
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
        turnRecords = [:]
        updatedAt = Date()
    }

    // MARK: - Turn Records（阶段与终局，唯一真相）

    /// 取某一轮的记录。
    public func turnRecord(turnID: Int) -> AIAgentTurnRecord? {
        turnRecords[turnID]
    }

    /// 开一轮：`LLMExecutor` 在 `.preparing` 时调用。同号重开（重试）会覆盖旧记录。
    func openTurnRecord(turnID: Int, modelRef: String?) {
        $turnRecords.mutate {
            $0[turnID] = AIAgentTurnRecord(
                turnID: turnID, stage: .preparing, modelRef: modelRef, roundCount: 0
            )
        }
    }

    /// 执行循环开始时记轮数；只增不减，迟到的更新不能改写终局。
    func advanceTurnRound(turnID: Int, roundCount: Int) {
        $turnRecords.mutate {
            guard var record = $0[turnID], !record.isFinished else { return }
            record.roundCount = max(record.roundCount ?? 0, roundCount)
            $0[turnID] = record
        }
    }

    /// 推进阶段。记录已经有终局了就不再动它（终局是不可逆的）。
    func advanceTurnStage(turnID: Int, stage: AIAgentRunStage, modelRef: String? = nil) {
        $turnRecords.mutate {
            guard var record = $0[turnID], record.outcome == nil else { return }
            record.stage = stage
            if let modelRef = modelRef { record.modelRef = modelRef }
            $0[turnID] = record
        }
    }

    /// 关一轮：写入终局。**一轮只能通过这里结束**，重复调用只有第一次生效。
    func closeTurnRecord(turnID: Int, outcome: AIAgentTurnRecord.Outcome, stage: AIAgentRunStage? = nil) {
        $turnRecords.mutate {
            guard var record = $0[turnID] else { return }
            guard record.outcome == nil else { return }
            record.outcome = outcome
            record.endedAt = Date()
            if let stage = stage { record.stage = stage }
            $0[turnID] = record
        }
    }

    /// 恢复会话时调用：把没有终局的轮次标成 `.interrupted`。
    ///
    /// 进程死过一次，这些轮次不可能自己回来（SSE 断了、工具 Task 没了），而且**绝不自动重放**
    /// ——工具有副作用。UI 把它渲染成「上次中断」，要不要重问交给用户。
    /// - Returns: 被标记的轮次号。
    @discardableResult
    public func markUnfinishedTurnsAsInterrupted() -> [Int] {
        var marked: [Int] = []
        $turnRecords.mutate {
            for (turnID, record) in $0 where record.outcome == nil {
                var updated = record
                updated.outcome = .interrupted
                updated.endedAt = record.endedAt ?? Date()
                $0[turnID] = updated
                marked.append(turnID)
            }
        }
        if !marked.isEmpty {
            Logger.info("AISession", "markUnfinishedTurnsAsInterrupted: id=\(id), turns=\(marked.sorted())")
        }
        return marked
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
        return switchModel(
            provider: resolved.provider,
            modelId: resolved.modelId,
            reference: reference
        )
    }

    /// 使用已经解析过的 provider/model 更新会话，避免运行期故障切换时再次读取旧注册表。
    @discardableResult
    func switchModel(
        provider: any ModelProvider,
        modelId: String,
        reference: String,
        expectedGeneration: UInt64? = nil
    ) -> Bool {
        guard provider.modelSpec(for: modelId) != nil else {
            Logger.warning("AISession", "switchModel: provider 中不存在模型 \(modelId)")
            return false
        }

        let didSwitch = $modelSelection.mutate { selection -> Bool in
            if let expectedGeneration,
               selection.generation != expectedGeneration {
                return false
            }
            selection = ModelSelection(
                provider: provider,
                modelId: modelId,
                generation: selection.generation &+ 1
            )
            return true
        }
        guard didSwitch else {
            Logger.info(
                "AISession",
                "switchModel ignored stale generation: sessionId=\(id), reference=\(reference)"
            )
            return false
        }

        updatedAt = Date()
        uiState.set(SessionUIState.activeModelKey, value: reference)
        Logger.info("AISession", "switchModel: sessionId=\(id) → \(reference)")
        AppAgentDebugLog.shared.record(
            .info,
            message: "会话切换模型 → \(reference)",
            sessionId: id,
            provider: provider.name,
            apiProtocol: provider.apiProtocol.rawValue,
            modelId: modelId
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
    /// 子到根的宿主策略（deny 优先）→ 根会话的 responder → 兜底拒绝。
    /// Pending 只注册在根会话；取消同步清理，不等待不合作的宿主 responder 返回。
    public func requestDecision(_ request: DecisionRequest) async -> DecisionOutcome {
        let fallback = Self.fallbackOutcome(for: request)
        guard !Task.isCancelled, let chain = decisionPolicyChain(), let root = chain.last,
              decisionBoundariesAllow(request, chain: chain) else { return fallback }
        let pending = DecisionPendingRegistration(state: root.uiState, request: request)
        let waiter = DecisionWaiter(onSettle: { pending.clear() })
        return await withTaskCancellationHandler {
            waiter.start { [self] in
                let policy = await decisionHostPolicy(for: request, chain: chain)
                guard !Task.isCancelled, matchesDecisionPolicyChain(chain),
                      decisionBoundariesAllow(request, chain: chain) else { return fallback }
                if let policy { return policy }

                let responders = root.decisionResponders.responders
                guard !responders.isEmpty, pending.install() else { return fallback }
                for responder in responders {
                    guard !Task.isCancelled, matchesDecisionPolicyChain(chain),
                          decisionBoundariesAllow(request, chain: chain) else { return fallback }
                    if let outcome = await responder.respond(to: request, session: root) {
                        guard !Task.isCancelled, matchesDecisionPolicyChain(chain),
                              decisionBoundariesAllow(request, chain: chain) else { return fallback }
                        // Approval can never override a restriction imposed while UI was open.
                        let latest = await decisionHostPolicy(for: request, chain: chain)
                        guard !Task.isCancelled, matchesDecisionPolicyChain(chain),
                              decisionBoundariesAllow(request, chain: chain) else { return fallback }
                        if latest == .deny { return .deny }
                        if case .clarification = request { return latest ?? outcome }
                        if let latest, latest != .allowOnce && latest != .allowForSession { return .deny }
                        // An allowOnce host policy cannot be expanded by a session-wide UI answer.
                        if latest == .allowOnce, outcome == .allowForSession { return .allowOnce }
                        return outcome
                    }
                }
                return fallback
            }
            let outcome = await waiter.value()
            guard !Task.isCancelled, !waiter.isCancelled, matchesDecisionPolicyChain(chain),
                  decisionBoundariesAllow(request, chain: chain) else { return fallback }
            return outcome
        } onCancel: {
            waiter.cancel(returning: fallback)
        }
    }

    /// Strong snapshot across awaits; cycles are invalid, not a reason to skip an ancestor.
    func decisionPolicyChain() -> [AISession]? {
        var chain: [AISession] = []
        var seen = Set<ObjectIdentifier>()
        var current: AISession? = self
        while let session = current {
            guard seen.insert(ObjectIdentifier(session)).inserted else { return nil }
            chain.append(session)
            current = session.decisionParent
        }
        return chain
    }

    func matchesDecisionPolicyChain(_ expected: [AISession]) -> Bool {
        guard let current = decisionPolicyChain(), current.count == expected.count else { return false }
        return zip(current, expected).allSatisfy { $0.0 === $0.1 }
    }

    /// Non-interactive only. Call under a DecisionWaiter cancellation gate. A child's
    /// allow is provisional until every ancestor has had an opportunity to deny it.
    func decisionHostPolicy(for request: DecisionRequest, chain: [AISession]) async -> DecisionOutcome? {
        var selected: DecisionOutcome?
        for session in chain {
            guard !Task.isCancelled, matchesDecisionPolicyChain(chain),
                  decisionBoundariesAllow(request, chain: chain) else { return .deny }
            guard let agent = session.agentMask?.agent, let delegate = agent.delegate else { continue }
            guard let outcome = await delegate.aiAgent(agent, session: session, policyFor: request) else {
                continue
            }
            if outcome == .deny { return .deny }
            if case .clarification = request {
                if selected == nil { selected = outcome }
            } else {
                guard outcome == .allowOnce || outcome == .allowForSession else { return .deny }
                if selected == nil || outcome == .allowOnce { selected = outcome }
            }
        }
        guard !Task.isCancelled, matchesDecisionPolicyChain(chain),
              decisionBoundariesAllow(request, chain: chain) else { return .deny }
        return selected
    }

    private func decisionBoundariesAllow(_ request: DecisionRequest, chain: [AISession]) -> Bool {
        guard case let .appAgentInspection(scope, isMutation) = request else { return true }
        do {
            try HostInspectionAccess.checkBoundaries(scope: scope, isMutation: isMutation, chain: chain)
            return true
        } catch { return false }
    }

    /// 没人能回答时的结果：授权类一律拒绝，澄清类当作没回答。
    private static func fallbackOutcome(for request: DecisionRequest) -> DecisionOutcome {
        switch request {
        case .privateNetworkAccess, .toolAuthorization, .appAgentInspection: return .deny
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
            messages: messages,
            metadata: metadata,
            turnRecords: turnRecords.values.sorted { $0.turnID < $1.turnID },
            executionPolicy: executionPolicy,
            ownerAgentID: agentMask?.agent?.id
        )
    }
}
