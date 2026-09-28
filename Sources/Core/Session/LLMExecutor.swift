//
//  LLMExecutor.swift
//  AppAgent
//

import Foundation

// MARK: - LLM Executor

/// Drives the LLM provider ↔ tool execution cycle for a session.
///
/// Mounted as a persistent property on AISession. Each `run()` call resolves
/// the provider/model, resets per-run state, and drives the execution loop.
///
/// Responsibilities:
/// - System prompt assembly
/// - Tool resolution and parallel execution
/// - Provider streaming and retry
/// - Context compression
/// - Tool loop detection
public final class LLMExecutor: @unchecked Sendable {

    // MARK: - Dependencies (set once at init)

    private weak var session: AISession?
    private let retryPolicy: RetryPolicy
    private let compressor: (any ContextCompressor)?

    // MARK: - Thread Safety

    private let lock = ReadersWriterLock()

    /// The Task driving the run loop. Non-nil while running.
    private var _runTask: Task<Void, Never>?

    /// Identity of the run currently allowed to mutate session/UI state.
    private var _activeRunID: UUID?

    // 「这一轮发过终止事件了吗」是 per-run 的事实，已搬进 `TurnJournal`（一个 Bool）。
    // 放在这个长寿对象上时它需要 runID 作键 + 条数上限 + 淘汰策略，而淘汰策略正是
    // 一次真实 bug 的来源（按 `Set.first` 淘汰会误删当前 run，defer 兜底随即补发
    // 第二个 `.error`）。per-run 之后这套容器连同那类 bug 一起没了。

    /// 上一次把 turnRecord 写盘的时间（用于限流，见 `persistTurnState`）。
    private var _lastTurnPersistAt: Date?

    /// Current iteration number (1-based). Updated at the start of each iteration.
    @Locked
    public private(set) var currentIteration: Int = 0

    /// Whether the executor is currently running.
    public var isRunning: Bool { lock.read { _runTask != nil } }

    // MARK: - Init

    init(session: AISession,
         retryPolicy: RetryPolicy = RetryPolicy(),
         compressor: (any ContextCompressor)? = SimpleContextCompressor()) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.compressor = compressor
    }

    // MARK: - Public API

    /// Run the LLM execution loop for a user message.
    ///
    /// Integrates the full lifecycle: adds the user message, resolves the provider,
    /// manages UI state, drives the LLM ↔ tool loop, and updates the session on completion.
    public func run(_ text: String) -> AsyncStream<AIAgentEvent> {
        let (outputStream, outputContinuation) = AsyncStream<AIAgentEvent>.makePair()
        let runID = UUID()

        outputContinuation.onTermination = { @Sendable [weak self] termination in
            if case .cancelled = termination {
                self?.cancel(runID: runID)
            }
        }

        let previousTask = lock.writeSync { () -> Task<Void, Never>? in
            let task = _runTask
            _runTask = nil
            _activeRunID = runID
            return task
        }
        previousTask?.cancel()

        let task = Task { [weak self] in
            guard let self else {
                outputContinuation.finish()
                return
            }

            // 这一轮所有状态写入的唯一出口。依赖用闭包注入，journal 不认识 executor。
            let journal = TurnJournal(
                session: self.session,
                continuation: outputContinuation,
                isActive: { [weak self] in self?.isActiveRun(runID) ?? false },
                persist: { [weak self] session, force in
                    self?.persistTurnState(session: session, force: force)
                }
            )
            defer {
                if let session = self.session {
                    Task { [weak session] in
                        await session?.hostStateMirror.endRun(runID)
                    }
                }
                // 顺序要紧：先兜底补终止事件（这时 runID 还是 active，UI 状态才清得掉），
                // 再摘 task，最后关流。
                journal.finalizeIfNeeded()
                self.clearRunTask(runID: runID)
                outputContinuation.finish()
            }

            guard let session = self.session else {
                journal.failed(AIAgentError.sessionReleased)
                return
            }

            guard self.isActiveRun(runID) else { return }
            await session.hostStateMirror.startRun(runID)

            // 先把 UI 拨到「刚开始」，这样早期失败也能在界面上显示出来。
            journal.prepareUI()

            let turnID = session.addUserMessage(text)
            journal.openTurn(turnID: turnID)
            Logger.info("LLMExecutor", "run: sessionId=\(session.id), text=\"\(text.prefix(100))\(text.count > 100 ? "..." : "")\", messageCount=\(session.messages.count)")

            // Resolve provider from session
            guard let mask = session.agentMask, let agent = mask.agent else {
                let error = ModelError.providerError("No agent attached")
                Logger.error("LLMExecutor", "run: sessionId=\(session.id), no agent attached")
                // agent 还没 attach，所以不会回调 sessionDidEncounterError —— 与原行为一致。
                journal.failed(error)
                return
            }
            journal.attach(agent: agent)

            let modelSelection = session.modelSelectionSnapshot()
            guard let provider = modelSelection.provider,
                  let modelId = modelSelection.modelId else {
                let error = ModelError.providerError("No provider configured")
                Logger.error("LLMExecutor", "run: sessionId=\(session.id), no provider/model configured")
                journal.failed(error)
                return
            }

            // 记下这一轮实际用的模型（运行期回退后会再更新一次）。
            journal.recordModel("\(provider.name)/\(modelId)", stage: .preparing)

            let maxIter = mask.executionPolicy.maxIterations

            // Only temporary delegated sessions inherit the parent's turn grant.
            let inheritedGrant = session.decisionParent == nil ? nil : HostInspectionAccess.authorization
            let grant = inheritedGrant ?? HostInspectionAuthorization(session: session)
            defer { if inheritedGrant == nil { grant.invalidate() } }
            await withTaskCancellationHandler {
                await HostInspectionAccess.$authorization.withValue(grant) {
                    await self.runLoop(
                        runID: runID,
                        turnID: turnID,
                        initialMessages: session.messages,
                        provider: provider,
                        modelId: modelId,
                        modelSelectionGeneration: modelSelection.generation,
                        maxIterations: maxIter,
                        session: session,
                        agent: agent,
                        journal: journal,
                        continuation: outputContinuation
                    )
                }
            } onCancel: {
                if inheritedGrant == nil { grant.invalidate() }
            }
        }

        let shouldCancelTask = lock.writeSync { () -> Bool in
            guard _activeRunID == runID else { return true }
            _runTask = task
            return false
        }
        if shouldCancelTask {
            task.cancel()
        }

        return outputStream
    }

    /// Cancel the current execution.
    public func cancel() {
        cancel(runID: nil)
        Logger.info("LLMExecutor", "cancel: sessionId=\(session?.id ?? "nil")")
    }

    private func cancel(runID: UUID?) {
        let task = lock.writeSync { () -> Task<Void, Never>? in
            if let runID, _activeRunID != runID {
                return nil
            }
            let task = _runTask
            _runTask = nil
            _activeRunID = nil
            return task
        }
        task?.cancel()
        session?.uiState.setStreaming(false)
    }

    private func isActiveRun(_ runID: UUID) -> Bool {
        lock.read { _activeRunID == runID }
    }

    /// 把 turnRecord 的变化写盘。
    ///
    /// 阶段推进也写（这样进程被杀后能看出「上次卡在哪一步」），但**限流**：非强制写至多
    /// 每秒一次。不限流的话一轮要写好几遍整份会话 JSON（几十 KB），纯属浪费。
    /// 终局一定 `force: true`。
    private func persistTurnState(session: AISession, force: Bool) {
        guard let agent = session.agentMask?.agent,
              session.executionPolicy.autoPersist else { return }
        let shouldWrite: Bool = lock.writeSync {
            let now = Date()
            if !force, let last = _lastTurnPersistAt, now.timeIntervalSince(last) < 1.0 {
                return false
            }
            _lastTurnPersistAt = now
            return true
        }
        guard shouldWrite else { return }
        Task { [weak agent, weak session] in
            guard let agent, let session else { return }
            do {
                try await agent.sessionManager.saveSession(session)
            } catch {
                Logger.warning("LLMExecutor", "persistTurnState failed: \(error)")
            }
        }
    }


    private func clearRunTask(runID: UUID) {
        lock.writeSync {
            guard _activeRunID == runID else { return }
            _runTask = nil
            _activeRunID = nil
        }
    }

    // MARK: - System Prompt Assembly

    /// Assemble the final system prompt from profile, memory, tools, and session-level parts.
    ///
    /// - Parameter tools: 这一轮真正递给模型的工具清单。由调用方解析一次传进来——自己再
    ///   解析一遍会二次命中 ToolCentral、并且让工厂工具多造一份实例。
    func assembleSystemPrompt(session: AISession,
                             tools: [any ToolProtocol]? = nil) async -> [ContentOrCacheControl<SystemPrompt>] {
        guard let mask = session.agentMask else {
            // No mask — minimal prompt
            var result: [ContentOrCacheControl<SystemPrompt>] = []
            result.append(.cacheControl)
            result.append(contentsOf: session.promptParts)
            return result
        }

        var result: [ContentOrCacheControl<SystemPrompt>] = []
        let profile = mask.profile

        // 1. Prompt builders
        for builder in profile.promptBuilders {
            switch builder.content {
            case .text(let text):
                result.append(.content(SystemPrompt(text)))
            case .closure(let resolver):
                if let text = await resolver(session) {
                    result.append(.content(SystemPrompt(text)))
                }
            }
        }

        // 2. Memory prompts (from agent.memoryStore — NOT in mask)
        if let memoryStore = mask.agent?.memoryStore {
            let memoryPrompts = await memoryStore.assembleMemoryPrompts()
            for prompt in memoryPrompts {
                result.append(.content(prompt))
            }
            if !memoryPrompts.isEmpty {
                result.append(.cacheControl)
            }
        }

        // 3. Tool-specific prompts
        let resolvedTools: [any ToolProtocol]
        if let tools {
            resolvedTools = tools
        } else {
            resolvedTools = await self.availableTools(session: session)
        }
        var mergedToolPrompts = AIAgentProfile.defaultBuiltInToolPrompts
        for (key, value) in profile.toolPrompts {
            mergedToolPrompts[key] = value
        }
        let matchedToolPrompts = resolvedTools.compactMap { mergedToolPrompts[$0.name] }
        if !matchedToolPrompts.isEmpty {
            let toolSection = "# Using your tools\n\n" + matchedToolPrompts.joined(separator: "\n\n")
            result.append(.content(SystemPrompt(toolSection)))
        }

        // 4. Cache break
        result.append(.cacheControl)

        // 5. Session-level prompt parts
        result.append(contentsOf: session.promptParts)

        return result
    }

    // MARK: - Tool Resolution

    /// Get the current list of available tools (filtered, stably sorted by name).
    func availableTools(session: AISession) async -> [any ToolProtocol] {
        // Build policy chain: agent policy (from mask) → session policy
        var policies: [ToolCentral.ToolPolicy] = []
        if let agentPolicy = session.agentMask?.toolPolicy {
            policies.append(agentPolicy)
        }
        if let sessionPolicy = session.toolPolicy {
            policies.append(sessionPolicy)
        }

        // Merge shared tools from registry + installed (per-session) tools
        var allTools: [String: any ToolProtocol] = [:]
        if let central = session.agentMask?.toolCentral {
            let sharedTools = await central.resolveTools(policies: policies)
            allTools = sharedTools
        }

        // Installed tools (per-session instances) override shared ones with the same name,
        // but only if they survive the policy filter (name + group rules, using each
        // installed tool's own group).
        let survivingInstalled = ToolCentral.ToolPolicy.apply(
            policies,
            to: Set(session.installedTools.keys),
            groupOf: { session.installedTools[$0]?.group }
        )
        for name in survivingInstalled {
            if let tool = session.installedTools[name] {
                allTools[name] = tool
            }
        }

        // Filter: only enabled tools
        let filtered = allTools.values.filter { $0.enabled }

        // Stable sort by name for cache friendliness
        return StableSort.byName(filtered) { $0.name }
    }

    // MARK: - Model Fallback

    /// 区分「provider + 模型」的稳定键。注意 `AnthropicProvider.name` 恒为 "anthropic"，
    /// 同一接口下的 OpenAI / Anthropic 两个 provider 只能靠协议与 baseURL 区分。
    private static func modelKey(_ provider: any ModelProvider, _ modelId: String) -> String {
        "\(provider.name)|\(provider.apiProtocol.rawValue)|\(provider.baseURL)|\(modelId)"
    }

    /// 按 modelPolicy 顺序重新解析并逐个真实探测候选模型。
    ///
    /// 每个候选只会在本次调用中探测一次；返回的 attemptedKeys 由调用方合并到
    /// 本轮 triedModelKeys，避免探测失败的候选在下一次 fallback 分支中重复请求。
    private func resolveAndProbeNextModel(
        agent: AIAgent,
        policyRefs: [String],
        tried: Set<String>,
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>]
    ) async -> (
        next: (ref: String, provider: any ModelProvider, modelId: String)?,
        attemptedKeys: Set<String>
    ) {
        var attemptedKeys: Set<String> = []
        for ref in policyRefs {
            guard !Task.isCancelled else {
                break
            }
            guard let resolved = await agent.providerCentral.resolve(modelReference: ref) else {
                continue
            }
            let key = Self.modelKey(resolved.provider, resolved.modelId)
            guard !tried.contains(key), !attemptedKeys.contains(key) else {
                continue
            }
            attemptedKeys.insert(key)

            guard resolved.provider.modelSpec(for: resolved.modelId) != nil else {
                continue
            }
            guard await probeModel(
                provider: resolved.provider,
                modelId: resolved.modelId,
                messages: messages,
                system: system,
                tools: tools
            ) else {
                continue
            }
            return (
                next: (ref, resolved.provider, resolved.modelId),
                attemptedKeys: attemptedKeys
            )
        }
        return (next: nil, attemptedKeys: attemptedKeys)
    }

    /// 用当前 session 的消息、系统提示和工具定义做一次最小真实流式请求。
    /// 这同时验证了候选的接口可达性和当前 session 的协议/上下文兼容性。
    private func probeModel(
        provider: any ModelProvider,
        modelId: String,
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>]
    ) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        let timeout = min(max(provider.requestTimeout, 1), 20)
        do {
            return try await Self.withTimeout(timeout) {
                let stream = provider.streamCompletion(
                    messages: messages,
                    system: system,
                    tools: tools,
                    modelId: modelId
                )
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let text) where !text.isEmpty:
                        return true
                    case .toolCall:
                        return true
                    case .done(let stopReason):
                        if stopReason != .toolUse {
                            return true
                        }
                    default:
                        continue
                    }
                }
                throw ModelError.providerError("fallback probe returned no usable output")
            }
        } catch {
            if Task.isCancelled {
                return false
            }
            let classified = ErrorClassifier.classify(error)
            Logger.warning(
                "LLMExecutor",
                "fallback probe failed: model=\(modelId), reason=\(classified.reason), error=\(error)"
            )
            AppAgentDebugLog.shared.record(
                .failure,
                message: "回退模型可用性探测失败：\(classified.message)",
                provider: provider.name,
                apiProtocol: provider.apiProtocol.rawValue,
                modelId: modelId,
                reason: "fallback_probe_\(classified.reason.rawValue)",
                statusCode: classified.statusCode
            )
            return false
        }
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await body()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            defer {
                group.cancelAll()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    // MARK: - Model Switch (两处共用)

    /// 换下一个还没试过的模型，重跑这一轮。
    ///
    /// 流错误回退与协议异常（`stop=tool_use` 但 0 个调用）走的是**同一套动作**，
    /// 只有 `reason` 与 debug-log 文案不同，所以合在这里，别再各写一份。
    /// 副作用清单（顺序有讲究）：
    /// 1. 轮次预算守卫 —— 探测会真的发请求，预算用完就别探了；
    /// 2. 探测候选 → 取消守卫（探测期间用户可能按了停止）；
    /// 3. `triedModelKeys` 并入本次探测过的全部 key，避免回退绕圈；
    /// 4. 改 `state` 的 6 个字段（含 `retryCount = 0`：新模型重新给满重试额度）；
    /// 5. 仅当仍是 active run 且之前没被拒过，才把新模型发布回会话；
    ///    `expectedGeneration` 不匹配说明用户自己换过模型，此后不再尝试发布。
    private func switchToNextModel(
        reason: String,
        debugMessage: (_ from: String, _ to: String) -> String,
        state: inout RunLoopState,
        context: ModelSwitchContext
    ) async -> ModelSwitchOutcome {
        guard state.iteration < context.maxIterations else { return .budgetExhausted }

        let fallback = await self.resolveAndProbeNextModel(
            agent: context.agent,
            policyRefs: context.agent.modelPolicy.map { policy in
                [policy.primary] + policy.fallbacks
            } ?? [],
            tried: state.triedModelKeys,
            messages: state.providerMessages,
            system: context.systemParts,
            tools: context.toolSegments
        )
        guard !Task.isCancelled else { return .cancelled }

        state.triedModelKeys.formUnion(fallback.attemptedKeys)
        guard let next = fallback.next else { return .noCandidateLeft }

        state.forceHostSnapshotNextRequest = true
        state.providerMessages = state.currentMessages
        let from = "\(state.modelId)@\(state.provider.apiProtocol.rawValue)"
        state.provider = next.provider
        state.modelId = next.modelId
        state.retryCount = 0

        Logger.info("LLMExecutor", "model fallback: \(from) → \(next.ref) (reason=\(reason))")
        AppAgentDebugLog.shared.record(
            .fallback,
            message: debugMessage(from, next.ref),
            sessionId: context.session.id,
            provider: next.provider.name,
            apiProtocol: next.provider.apiProtocol.rawValue,
            modelId: next.modelId,
            iteration: state.iteration,
            reason: reason
        )

        if self.isActiveRun(context.runID), state.canPublishFallback {
            let published = context.session.switchModel(
                provider: next.provider,
                modelId: next.modelId,
                reference: next.ref,
                expectedGeneration: state.modelSelectionGeneration
            )
            if published {
                state.modelSelectionGeneration &+= 1
            } else {
                state.canPublishFallback = false
            }
            context.session.advanceTurnStage(
                turnID: context.turnID, stage: .requesting, modelRef: next.ref
            )
        }
        return .switched
    }

    // MARK: - Run Loop


    private func runLoop(
        runID: UUID,
        turnID: Int,
        initialMessages: [AIAgentMessage],
        provider: any ModelProvider,
        modelId: String,
        modelSelectionGeneration: UInt64,
        maxIterations: Int,
        session: AISession,
        agent: AIAgent,
        journal: TurnJournal,
        continuation: AsyncStream<AIAgentEvent>.Continuation
    ) async {
        // 这一轮会变的全部状态都在这里（原先是摊开的 11 个 var，见 RunLoopState）。
        // turnID 在创建用户消息时分配并传入，不能重读可能已被下一次 run 推进的 currentTurnID。
        var state = RunLoopState(
            initialMessages: initialMessages,
            provider: provider,
            modelId: modelId,
            modelSelectionGeneration: modelSelectionGeneration,
            initialModelKey: Self.modelKey(provider, modelId)
        )

        func finishWithError(_ error: Error, messages: [AIAgentMessage]) {
            journal.failed(error, messages: messages)
        }

        /// 阶段推进的唯一入口。三层门控与顺序都在 `TurnJournal` 里。
        func setStage(_ stage: AIAgentRunStage) {
            journal.advanceStage(stage)
        }

        func discardPreparedHostContext(_ preparation: PreparedHostContext?) async {
            guard let preparation else {
                return
            }
            await session.hostStateMirror.discard(preparation)
        }

        func commitPreparedHostContext(_ preparation: PreparedHostContext?) async -> Bool {
            guard let preparation else {
                return true
            }
            do {
                try await session.hostStateMirror.commit(preparation)
                return true
            } catch {
                Logger.warning(
                    "LLMExecutor",
                    "host context commit rejected; forcing a fresh snapshot: \(error)"
                )
                await session.hostStateMirror.invalidateModelBaseline()
                return false
            }
        }

        defer {
            if self.isActiveRun(runID) {
                session.uiState.setStreaming(false)
            }
        }

        while state.iteration < maxIterations {
            // Check cancellation
            guard !Task.isCancelled else {
                let error = AIAgentError.cancelled
                Logger.info("LLMExecutor", "cancelled at iteration \(state.iteration)")
                finishWithError(error, messages: state.currentMessages)
                return
            }

            // Verify session is still alive
            guard self.session != nil else {
                let error = AIAgentError.sessionReleased
                Logger.error("LLMExecutor", "session released during execution at iteration \(state.iteration)")
                finishWithError(error, messages: state.currentMessages)
                return
            }

            state.iteration += 1
            currentIteration = state.iteration
            journal.advanceRound(state.iteration)
            continuation.yield(.started(turn: state.iteration))
            Logger.info("LLMExecutor", "--- iteration \(state.iteration)/\(maxIterations) start, messageCount=\(state.currentMessages.count) ---")

            // 1. Get available tools (filtered, sorted)
            let availableTools = await self.availableTools(session: session)
            // Offer 与 execute 必须同源：下面 `executeSingleTool` 用 `tool(named:)` 查表，
            // 所以先把执行表对齐到刚算出的清单，避免「清单里有、执行时找不到」。
            session.syncInstalledTools(availableTools)
            Logger.debug("LLMExecutor", "availableTools: [\(availableTools.map(\.name).joined(separator: ", "))]")

            // 2. Assemble system prompt（复用上面那份清单，别再解析一遍）
            let systemParts = await self.assembleSystemPrompt(session: session, tools: availableTools)
            let contentCount = systemParts.filter { if case .content = $0 { return true }; return false }.count
            let cacheCount = systemParts.filter { if case .cacheControl = $0 { return true }; return false }.count
            Logger.debug("LLMExecutor", "systemPrompt: \(contentCount) content segments, \(cacheCount) cache markers")

            // 3. Build tools array with cache control at the end
            var toolSegments: [ContentOrCacheControl<any ToolProtocol>] = availableTools.map { .content($0) }
            if !toolSegments.isEmpty {
                toolSegments.append(.cacheControl)
            }

            // 换模型那一步要用到的、这一轮内不变的上下文（两处共用，见 switchToNextModel）。
            let switchContext = ModelSwitchContext(
                session: session,
                agent: agent,
                runID: runID,
                turnID: turnID,
                maxIterations: maxIterations,
                systemParts: systemParts,
                toolSegments: toolSegments
            )

            // 4. Context compression
            if let compressor = self.compressor,
               let contextWindow = state.provider.modelSpec(for: state.modelId)?.contextWindow {
                let estimatedTokens = compressor.estimateTokens(messages: state.currentMessages)
                let threshold = Int(Double(contextWindow) * 0.85)
                if estimatedTokens > threshold {
                    let targetTokens = Int(Double(contextWindow) * 0.6)
                    state.currentMessages = await compressor.compress(messages: state.currentMessages, targetTokens: targetTokens)
                    state.providerMessages = state.currentMessages
                    await session.hostStateMirror.invalidateModelBaseline()
                    state.forceHostSnapshotNextRequest = true
                    Logger.info("LLMExecutor", "context compressed: ~\(estimatedTokens) → ~\(targetTokens) tokens, messages: \(state.currentMessages.count)")
                }
            }

            // 5. Stream completion from provider
            let preparedHostContext: PreparedHostContext?
            do {
                preparedHostContext = try await session.hostStateMirror.prepare(
                    runID: runID,
                    forceSnapshot: state.forceHostSnapshotNextRequest
                )
            } catch {
                Logger.error("LLMExecutor", "host context preparation failed: \(error)")
                finishWithError(error, messages: state.currentMessages)
                return
            }
            state.forceHostSnapshotNextRequest = false

            var messagesForProvider: [AIAgentMessage]
            if state.iteration == 1 {
                messagesForProvider = await self.prepareMessagesForProvider(
                    state.currentMessages,
                    session: session,
                    turnID: turnID,
                    isFirstIteration: true
                )
            } else {
                messagesForProvider = state.providerMessages
            }
            if let preparedHostContext {
                messagesForProvider.append(preparedHostContext.message(turnID: turnID))
            }
            let stream = state.provider.streamCompletion(
                messages: messagesForProvider,
                system: systemParts,
                tools: toolSegments,
                modelId: state.modelId
            )
            // 请求已发出，等首个内容：卡在这一步基本是网络 / 鉴权 / 网关问题。
            setStage(.requesting)
            Logger.debug("LLMExecutor", "streamCompletion requested: provider=\(state.provider.name), model=\(state.modelId), messageCount=\(messagesForProvider.count), toolCount=\(toolSegments.count)")
            AppAgentDebugLog.shared.record(
                .request,
                message: "发起模型请求（消息 \(state.currentMessages.count) 条，工具 \(toolSegments.count) 个）",
                sessionId: session.id,
                provider: state.provider.name,
                apiProtocol: state.provider.apiProtocol.rawValue,
                modelId: state.modelId,
                iteration: state.iteration
            )
            let streamStart = Date()

            // Consume the stream
            var assistantText = ""
            var toolCalls: [AIAgentMessage.ToolCall] = []
            var stopReason: ProviderStreamEvent.StopReason = .endTurn
            var receivedStopReason = false

            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        assistantText += delta
                        journal.contentDelta(delta)

                    case .reasoningDelta(let delta):
                        // 思考过程只用于展示：进 uiState 与事件流，不写入消息历史。
                        journal.reasoningDelta(delta)

                    case .toolCall(let call):
                        toolCalls.append(call)
                        setStage(.streaming)
                        continuation.yield(.toolCallStarted(call))

                    case .done(let reason):
                        stopReason = reason
                        receivedStopReason = true

                    case .usage(let input, let output):
                        continuation.yield(.usage(inputTokens: input, outputTokens: output))
                    }
                }
                guard receivedStopReason else {
                    await discardPreparedHostContext(preparedHostContext)
                    if Task.isCancelled {
                        let error = AIAgentError.cancelled
                        Logger.info("LLMExecutor", "streamCancelled: iteration=\(state.iteration)")
                        finishWithError(error, messages: state.currentMessages)
                        return
                    }
                    state.forceHostSnapshotNextRequest = true
                    let error = ModelError.providerError(
                        "Provider stream ended without a stop reason."
                    )
                    Logger.error(
                        "LLMExecutor",
                        "streamProtocolError: iteration=\(state.iteration), missing stop reason"
                    )
                    finishWithError(error, messages: state.currentMessages)
                    return
                }
                Logger.info("LLMExecutor", "streamConsumed: textLength=\(assistantText.count), toolCalls=\(toolCalls.count)[\(toolCalls.map(\.name).joined(separator: ", "))], stopReason=\(stopReason)")
                AppAgentDebugLog.shared.record(
                    .success,
                    message: "模型返回完成（文本 \(assistantText.count) 字，工具调用 \(toolCalls.count) 次，stop=\(stopReason)）",
                    sessionId: session.id,
                    provider: state.provider.name,
                    apiProtocol: state.provider.apiProtocol.rawValue,
                    modelId: state.modelId,
                    iteration: state.iteration,
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                )
                state.retryCount = 0
            } catch is CancellationError {
                await discardPreparedHostContext(preparedHostContext)
                let error = AIAgentError.cancelled
                Logger.info("LLMExecutor", "streamCancelled: iteration=\(state.iteration)")
                finishWithError(error, messages: state.currentMessages)
                return
            } catch {
                await discardPreparedHostContext(preparedHostContext)
                state.forceHostSnapshotNextRequest = true
                let classified = ErrorClassifier.classify(error)
                Logger.error("LLMExecutor", "streamError: iteration=\(state.iteration), reason=\(classified.reason), retryable=\(classified.retryable), retryCount=\(state.retryCount)/\(retryPolicy.maxRetries), error=\(error)")
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: classified.message,
                    sessionId: session.id,
                    provider: state.provider.name,
                    apiProtocol: state.provider.apiProtocol.rawValue,
                    modelId: state.modelId,
                    iteration: state.iteration,
                    reason: classified.reason.rawValue,
                    statusCode: classified.statusCode,
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                )

                if classified.retryable && state.retryCount < retryPolicy.maxRetries {
                    state.retryCount += 1
                    let delay = retryPolicy.delay(for: state.retryCount - 1)
                    Logger.info("LLMExecutor", "retrying in \(String(format: "%.1f", delay))s (attempt \(state.retryCount)/\(retryPolicy.maxRetries))")
                    AppAgentDebugLog.shared.record(
                        .retry,
                        message: String(format: "%.1fs 后重试（%d/%d）", delay, state.retryCount, retryPolicy.maxRetries),
                        sessionId: session.id,
                        provider: state.provider.name,
                        apiProtocol: state.provider.apiProtocol.rawValue,
                        modelId: state.modelId,
                        iteration: state.iteration,
                        attempt: state.retryCount,
                        reason: classified.reason.rawValue
                    )
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        finishWithError(AIAgentError.cancelled, messages: state.currentMessages)
                        return
                    }
                    continue
                }

                // 重试用尽后，明确支持回退的错误可以切换模型；如果流已经产出
                // 部分正文或工具调用，即使是 5xx 中断也应切换，避免把半截响应
                // 作为最终结果暴露给用户。
                let hasPartialOutput = !assistantText.isEmpty || !toolCalls.isEmpty
                if classified.shouldFallback || hasPartialOutput {
                    guard state.iteration < maxIterations else {
                        finishWithError(
                            AIAgentError.maxIterationsReached(limit: maxIterations),
                            messages: state.currentMessages
                        )
                        return
                    }
                    // 顺序：先过预算守卫再清正文 —— 预算用完时这次尝试的正文还要留给终局 UI。
                    journal.attemptDiscarded()
                    switch await self.switchToNextModel(
                        reason: classified.reason.rawValue,
                        debugMessage: { from, to in "模型不可用，切换 \(from) → \(to)" },
                        state: &state,
                        context: switchContext
                    ) {
                    case .switched:
                        continue
                    case .cancelled:
                        await discardPreparedHostContext(preparedHostContext)
                        finishWithError(AIAgentError.cancelled, messages: state.currentMessages)
                        return
                    case .noCandidateLeft, .budgetExhausted:
                        break   // 落到下面「最终流错误」的收尾
                    }
                }

                // 最终流错误仍保留本次尝试已输出的正文，供终局 UI 接上错误详情。
                // 只在重试/回退都结束后写入；未执行的 toolCall 不能作为无结果的调用落库。
                if !assistantText.isEmpty {
                    state.currentMessages.append(AIAgentMessage(
                        role: .assistant, content: [.text(assistantText)], turnID: turnID
                    ))
                }
                finishWithError(error, messages: state.currentMessages)
                return
            }

            guard !Task.isCancelled else {
                await discardPreparedHostContext(preparedHostContext)
                finishWithError(AIAgentError.cancelled, messages: state.currentMessages)
                return
            }

            // 模型说「这一轮要调工具」却一个调用都没给：协议级异常（常见于 OpenAI 兼容端点的
            // `tool_calls` 流式格式和我们解析不上），**不能**当成「成功的回复」悄悄结束——
            // 界面上就是 loading 转一圈然后什么都没有，真机踩过。
            //
            // **带正文也算异常**：那点正文通常是「我来看看当前页面…」这类过场话（实测收到过一条
            // 光秃秃的 `...`）。当成答案收下就会写进消息历史，下一轮模型还会拿它当自己的上一句，
            // 并据此认为「这个问题我已经答过了」。
            if stopReason == .toolUse, toolCalls.isEmpty {
                await discardPreparedHostContext(preparedHostContext)
                state.forceHostSnapshotNextRequest = true
                Logger.error(
                    "LLMExecutor",
                    "stopReason=toolUse 但没有解析到任何工具调用；model=\(state.modelId)@\(state.provider.apiProtocol.rawValue), textLength=\(assistantText.count)"
                )
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: "模型返回 stop=tool_use 但没有任何工具调用（可能是该端点的 tool_calls 流式格式没被解析）",
                    sessionId: session.id,
                    provider: state.provider.name,
                    apiProtocol: state.provider.apiProtocol.rawValue,
                    modelId: state.modelId,
                    iteration: state.iteration,
                    reason: "toolUseWithoutCalls"
                )
                // 同一个端点再请求一次还是同样的格式，重试没意义；直接按 modelPolicy 换下一个
                // 还没试过的模型/协议重跑这一轮（Anthropic 协议的 `tool_use` 块和 chat/completions
                // 的 `tool_calls` 分片是两套解析，换过去往往就通了）。
                guard state.iteration < maxIterations else {
                    finishWithError(
                        AIAgentError.maxIterationsReached(limit: maxIterations),
                        messages: state.currentMessages
                    )
                    return
                }
                switch await self.switchToNextModel(
                    reason: "toolUseWithoutCalls",
                    debugMessage: { from, to in "工具调用没解析到，切换 \(from) → \(to)" },
                    state: &state,
                    context: switchContext
                ) {
                case .switched:
                    continue
                case .cancelled:
                    await discardPreparedHostContext(preparedHostContext)
                    finishWithError(AIAgentError.cancelled, messages: state.currentMessages)
                    return
                case .noCandidateLeft, .budgetExhausted:
                    let detail = assistantText.isEmpty
                        ? "（也没有正文）"
                        : "（只给了 \(assistantText.count) 字过场文本）"
                    finishWithError(
                        ModelError.providerError("模型声明要调用工具，但没有返回任何调用\(detail)。"),
                        messages: state.currentMessages
                    )
                    return
                }
            }

            if stopReason == .unknown {
                await discardPreparedHostContext(preparedHostContext)
                state.forceHostSnapshotNextRequest = true
                let error = ModelError.providerError(
                    "Provider returned an unknown stop reason."
                )
                Logger.error(
                    "LLMExecutor",
                    "streamProtocolError: iteration=\(state.iteration), unknown stop reason"
                )
                finishWithError(error, messages: state.currentMessages)
                return
            }

            // The model has produced a complete, protocol-valid response. Only now
            // advance the mirror's model-seen cursor. Tool execution may still fail,
            // but the provider did receive this host context successfully.
            let committedHostContext = await commitPreparedHostContext(preparedHostContext)
            if committedHostContext {
                state.providerMessages = messagesForProvider
            } else {
                state.providerMessages = state.currentMessages
                state.forceHostSnapshotNextRequest = true
            }

            // 6. Build assistant message
            var assistantParts: [AIAgentMessage.Content] = []
            if !assistantText.isEmpty {
                assistantParts.append(.text(assistantText))
            }
            for call in toolCalls {
                assistantParts.append(.toolUse(call))
            }
            if !assistantParts.isEmpty {
                let assistantMessage = AIAgentMessage(
                    role: .assistant, content: assistantParts, turnID: turnID
                )
                state.currentMessages.append(assistantMessage)
                state.providerMessages.append(assistantMessage)
            }

            // 7. If tool_use, execute tools and loop
            if stopReason == .toolUse, !toolCalls.isEmpty {
                // 工具阶段：卡在这里要么是工具自己慢/挂住，要么是在等用户拍板。
                setStage(.tooling)
                let (toolResultParts, terminalError) = await executeToolsConcurrently(
                    calls: toolCalls,
                    session: session,
                    loopDetector: &state.loopDetector,
                    continuation: continuation
                )

                if let terminalError {
                    finishWithError(terminalError, messages: state.currentMessages)
                    return
                }

                guard !Task.isCancelled else {
                    finishWithError(AIAgentError.cancelled, messages: state.currentMessages)
                    return
                }

                // Add tool results as a user message. Wire 上必须是 user 角色，但它们是
                // 这一轮内部的过程，不是用户又说了话——所以打上同一个 turnID。
                let toolResultMessage = AIAgentMessage(
                    role: .user, content: toolResultParts, turnID: turnID
                )
                state.currentMessages.append(toolResultMessage)
                state.providerMessages.append(toolResultMessage)
                continue
            }

            // 8. Done — emit result
            let result = AIAgentFinish(text: assistantText, updatedMessages: state.currentMessages)
            Logger.info("LLMExecutor", "completed: iteration=\(state.iteration), textLength=\(assistantText.count), totalMessages=\(state.currentMessages.count)")

            // Update session state + 终局（三层门控、去重与事件都在 TurnJournal 里）
            journal.answered(result)
            return
        }

        // Exceeded max iterations
        Logger.warning("LLMExecutor", "maxIterationsReached: limit=\(maxIterations)")
        finishWithError(AIAgentError.maxIterationsReached(limit: maxIterations), messages: state.currentMessages)
    }

    // MARK: - Parallel Tool Execution

    /// Execute tool calls concurrently via TaskGroup.
    ///
    /// Phase 1: Sequential loop detection (ToolLoopDetector is a value type)
    /// Phase 2: Parallel execution via TaskGroup (each tool handles its own safety check + timeout)
    /// Phase 3: Reconstruct results in original call order
    private func executeToolsConcurrently(
        calls: [AIAgentMessage.ToolCall],
        session: AISession,
        loopDetector: inout ToolLoopDetector,
        continuation: AsyncStream<AIAgentEvent>.Continuation
    ) async -> (results: [AIAgentMessage.Content], terminalError: Error?) {

        // Phase 1: Sequential loop detection
        var preResults: [String: (content: AIAgentMessage.Content, event: AIAgentEvent?)] = [:]
        var executableCalls: [AIAgentMessage.ToolCall] = []

        for call in calls {
            // 循环检测按「工具名 + 参数」做签名，所以必须用剥掉 `_why` 的那份：
            // 否则模型每次换一句理由就是新签名，精确重复检测直接失效。
            let loopResult = loopDetector.record(name: call.name,
                                                arguments: Self.executableArguments(call.arguments))
            switch loopResult {
            case .critical(let message):
                Logger.error("LLMExecutor", "toolLoopCritical: \(message)")
                let error = AIAgentError.toolLoopDetected(call.name)
                continuation.yield(.toolCallFailed(toolCallId: call.id, name: call.name, error: error))
                return (results: [], terminalError: error)
            case .warning(let message):
                Logger.warning("LLMExecutor", "toolLoopWarning: \(message)")
                let output = Tool.Output.text(message)
                preResults[call.id] = (.toolResult(AIAgentMessage.ToolCallResult(
                    toolCallId: call.id,
                    content: output.stringValue
                )), .toolCallCompleted(toolCallId: call.id, result: output))
            case .ok:
                executableCalls.append(call)
            }
        }

        // Phase 2: read-only calls run concurrently; anything that mutates runs one at
        // a time. Two parallel writes to the same view or file have no mutual exclusion,
        // so the speedup is not worth the interleaving. (Codex draws the same line via
        // the MCP `readOnlyHint`.)
        var executionResults: [String: (content: AIAgentMessage.Content, event: AIAgentEvent?)] = [:]

        if !executableCalls.isEmpty {
            let toolTimeout = session.executionPolicy.toolTimeout
            var concurrentCalls: [AIAgentMessage.ToolCall] = []
            var serialCalls: [AIAgentMessage.ToolCall] = []
            for call in executableCalls {
                let level = session.tool(named: call.name)?.safetyLevel(for: call.arguments) ?? .safe
                if level == .safe { concurrentCalls.append(call) } else { serialCalls.append(call) }
            }
            if !serialCalls.isEmpty {
                Logger.info("LLMExecutor",
                            "toolExecutionSplit: concurrent=\(concurrentCalls.count), serial=\(serialCalls.count)")
            }

            await withTaskGroup(of: (String, AIAgentMessage.Content, AIAgentEvent?).self) { group in
                for call in concurrentCalls {
                    group.addTask { [weak session] in
                        guard let session else {
                            let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                                toolCallId: call.id,
                                content: "Error: Session released during tool execution",
                                isError: true
                            ))
                            return (call.id, content, AIAgentEvent.toolCallFailed(
                                toolCallId: call.id, name: call.name,
                                error: AIAgentError.sessionReleased
                            ))
                        }

                        return await Self.executeSingleTool(
                            call: call,
                            session: session,
                            toolTimeout: toolTimeout
                        )
                    }
                }

                for await result in group {
                    executionResults[result.0] = (result.1, result.2)
                }
            }

            for call in serialCalls {
                let result = await Self.executeSingleTool(
                    call: call,
                    session: session,
                    toolTimeout: toolTimeout
                )
                executionResults[result.0] = (result.1, result.2)
            }
        }

        // Phase 3: Reconstruct results in original call order
        var orderedResults: [AIAgentMessage.Content] = []

        for call in calls {
            if let pre = preResults[call.id] {
                if let event = pre.event {
                    continuation.yield(event)
                }
                orderedResults.append(pre.content)
            } else if let exec = executionResults[call.id] {
                // Yield event in original order
                if let event = exec.event {
                    continuation.yield(event)
                }
                orderedResults.append(exec.content)
            }
        }

        return (results: orderedResults, terminalError: nil)
    }

    /// Execute a single tool call with safety check and timeout.
    ///
    /// This is a static method to safely capture in TaskGroup child tasks.
    private static func executeSingleTool(
        call: AIAgentMessage.ToolCall,
        session: AISession,
        toolTimeout: TimeInterval
    ) async -> (String, AIAgentMessage.Content, AIAgentEvent?) {
        let argsDescription = describeArgumentsForLog(call.arguments)
        Logger.info("LLMExecutor", "toolExec: name=\(call.name), id=\(call.id), args={\(argsDescription)}")

        do {
            guard let tool = session.tool(named: call.name) else {
                Logger.warning("LLMExecutor", "toolNotFound: name=\(call.name), id=\(call.id)")
                let err = AIAgentError.toolNotFound(call.name)
                // 回给模型一份可用的工具清单，否则它只会反复猜名字空转。
                let available = session.installedTools.keys.sorted().joined(separator: ", ")
                let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                    toolCallId: call.id,
                    content: "Error: Tool '\(call.name)' not found. "
                        + "Available tools: \(available.isEmpty ? "(none)" : available). "
                        + "Do not retry this name — either call one of the listed tools or answer without tools.",
                    isError: true
                ))
                return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
            }

            // Per-call safety level: a multi-op tool reports `list` and `delete` differently.
            let level = tool.safetyLevel(for: call.arguments)

            // Mutation boundary. Refused outright rather than prompted — an out-of-bounds
            // call should fail like a sandbox violation, not become a dialog.
            let mutationPolicy = session.executionPolicy.toolMutationPolicy
            if Self.isBlockedByMutationPolicy(mutationPolicy, level: level) {
                Logger.info("LLMExecutor", "toolBlockedByReadOnly: name=\(call.name), id=\(call.id), safetyLevel=\(level.rawValue)")
                let err = AIAgentError.toolExecutionDenied(call.name)
                let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                    toolCallId: call.id,
                    content: "Error: '\(call.name)' would change runtime state (safety level: \(level.rawValue)) "
                        + "but the agent is running read-only. Use an inspection-only operation instead.",
                    isError: true
                ))
                return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
            }

            // `_why` 是元参数：模型用它说明为什么需要这次危险操作，卡片才能给出有意义的
            // 提示。它不属于工具的入参，执行前剥掉（循环检测那边也用同一份）。
            let toolArguments = Self.executableArguments(call.arguments)
            let justification = call.arguments["_why"]?.stringValue

            // Safety level check：统一走 session 的决策中心，由 AppAgent 自己的面板
            // 呈现（宿主策略可先行定夺），没人能回答时兜底拒绝。
            if level == .sensitive || level == .dangerous {
                let opKey = Self.approvalKey(tool: call.name, arguments: toolArguments)
                let remembered: [String] = session.uiState.get("approvedToolOps") ?? []
                if !remembered.contains(opKey) {
                    let decision = await session.requestDecision(.toolAuthorization(
                        tool: call.name, safetyLevel: level, detail: justification))
                    switch decision {
                    case .deny, .answer:
                        Logger.info("LLMExecutor", "toolRejected: name=\(call.name), id=\(call.id), safetyLevel=\(level.rawValue)")
                        let err = AIAgentError.toolExecutionDenied(call.name)
                        let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                            toolCallId: call.id,
                            content: "Error: User denied execution of '\(call.name)' (safety level: \(level.rawValue))",
                            isError: true
                        ))
                        return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
                    case .allowForSession:
                        // 原子追加：两个并发的授权不能互相覆盖（见 appendUnique 注释）。
                        session.uiState.appendUnique(opKey, forKey: "approvedToolOps")
                        Logger.info("LLMExecutor", "toolApprovedForSession: \(opKey)")
                    case .allowOnce:
                        break
                    }

                    // 等卡片的这段时间里 run 可能已经被取消（用户按了停止 / 切走）。
                    // 拿到「允许」也不能再执行——否则一个已经停掉的回合还会改状态。
                    if Task.isCancelled {
                        Logger.info("LLMExecutor", "toolAbandonedAfterDecision: name=\(call.name), id=\(call.id)")
                        let err = AIAgentError.toolExecutionDenied(call.name)
                        let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                            toolCallId: call.id,
                            content: "Error: Run was cancelled while waiting for authorization of '\(call.name)'",
                            isError: true
                        ))
                        return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
                    }
                }
            }

            // Execute with timeout
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await withThrowingTaskGroup(of: Tool.Output.self) { group in
                group.addTask {
                    try await tool.execute(arguments: toolArguments, session: session)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(toolTimeout * 1_000_000_000))
                    throw AIAgentError.toolExecutionTimedOut(toolName: call.name)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let budget = tool.outputMaxBytes ?? session.executionPolicy.toolOutputMaxBytes
            // 预算只管文本；图片走多模态通道，截断它只会得到一张坏图。
            let payload = Self.clampToolOutput(result.stringValue, maxBytes: budget, toolName: call.name)
            let attachments = result.images.map {
                AIAgentMessage.ImageAttachment(data: $0.data, mediaType: $0.mediaType)
            }
            let resultPreview = payload.prefix(500)
            Logger.info("LLMExecutor", "toolResult: name=\(call.name), id=\(call.id), duration=\(String(format: "%.2f", duration))s, images=\(attachments.count), result=\"\(resultPreview)\(payload.count > 500 ? "...(\(payload.count) chars)" : "")\"")
            // 工具可以不抛异常而返回 .error；wire 和历史 UI 都依赖这个结构化标志。
            let isError: Bool
            if case .error = result { isError = true } else { isError = false }
            let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                toolCallId: call.id,
                content: payload,
                images: attachments,
                isError: isError
            ))
            return (call.id, content, .toolCallCompleted(toolCallId: call.id, result: result))
        } catch {
            Logger.error("LLMExecutor", "toolError: name=\(call.name), id=\(call.id), error=\(error)")
            let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                toolCallId: call.id,
                content: "Error: \(error.localizedDescription)",
                isError: true
            ))
            return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: error))
        }
    }

    /// 递给工具执行的参数：剥掉 `_why` 这类只给授权卡片看的元参数。
    /// 执行、循环检测、授权记忆键都必须用这一份，三处口径才一致。
    static func executableArguments(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        guard arguments["_why"] != nil else { return arguments }
        var stripped = arguments
        stripped.removeValue(forKey: "_why")
        return stripped
    }

    /// 会话级授权的记忆键：工具 + op 粒度。整个工具级会太粗（批了 `list` 就等于批了
    /// `delete`），单次调用级太细（同一个 op 每次都问）。
    static func approvalKey(tool: String, arguments: [String: JSONValue]) -> String {
        let op = arguments["op"]?.stringValue ?? arguments["action"]?.stringValue ?? "*"
        return "\(tool):\(op)"
    }

    /// Whether the mutation boundary refuses this call. Split out so the rule is
    /// testable without standing up a session and a provider.
    static func isBlockedByMutationPolicy(_ policy: Tool.MutationPolicy,
                                         level: Tool.SafetyLevel) -> Bool {
        policy == .readOnly && level > .safe
    }

    /// Keep one tool result from eating the context window.
    ///
    /// Cuts on a UTF-8 byte budget (that is what the wire and the tokenizer care
    /// about), snaps back to the last line boundary so the model never sees half a
    /// record, and appends how much was dropped plus what to do about it. The hint
    /// matters: without it the model retries the same broad call.
    ///
    /// 边界都在**字节**上找，不要混用字符距离：CJK 一个字符 3 字节，拿字符数去比
    /// `maxBytes / 2` 的话行边界回退几乎永不触发；直接按字节前缀解码还会在多字节字符
    /// 中间切出一个 U+FFFD 替换符。
    static func clampToolOutput(_ text: String, maxBytes: Int, toolName: String) -> String {
        guard maxBytes > 0 else { return text }
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }

        // 先在字节上找切点：优先切到后半段里最后一个换行，否则退到不劈开字符的边界。
        var cut = maxBytes
        let head = data.prefix(maxBytes)
        if let newline = head.lastIndex(of: 0x0A), newline > maxBytes / 2 {
            cut = newline
        } else {
            // UTF-8 续字节是 10xxxxxx，往前退到一个字符起始字节。
            while cut > 0, data[cut] & 0xC0 == 0x80 { cut -= 1 }
        }

        let kept = String(decoding: data.prefix(cut), as: UTF8.self)
        let dropped = max(0, data.count - cut)
        Logger.info("LLMExecutor", "toolOutputTruncated: name=\(toolName), kept=\(cut)B, dropped=\(dropped)B, budget=\(maxBytes)B")
        return kept + "\n\n…[truncated: \(dropped) of \(data.count) bytes dropped to stay inside the "
            + "\(maxBytes)-byte tool output budget. Narrow the request — filter, paginate, "
            + "or target a specific path/section — instead of repeating this call.]"
    }

    private static func describeArgumentsForLog(_ arguments: [String: JSONValue]) -> String {
        arguments.keys.sorted().map { key in
            let value = arguments[key] ?? .null
            return "\(key)=\(describeValueForLog(value))"
        }.joined(separator: ", ")
    }

    private static func describeValueForLog(_ value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return "<string:\(string.count) chars>"
        case .number:
            return "<number>"
        case .bool:
            return "<bool>"
        case .null:
            return "null"
        case .array(let values):
            return "<array:\(values.count) items>"
        case .object(let object):
            return "<object:\(object.count) keys>"
        }
    }

    // MARK: - Message Context Injection

    /// Wrap the last user text message with context entries for the provider.
    /// Only applies on the first iteration (not during tool-use loops).
    /// 丢掉「用户问了、但这一轮什么都没产出」的孤儿轮次：失败或被中断的提问。
    ///
    /// 这些消息必须留在 `session.messages` 里（界面要显示用户气泡 + 那条错误），但**不能再发给
    /// 模型**。实测一个 demo 会话里同一句「当前页面有哪些功能」堆了 4 条无人应答的 user 消息：
    /// ① wire 上出现连续多条 `user`（Anthropic 侧对角色交替严格）；② 模型自己在思考里写
    /// 「用户问了好几次」，被历史带跑；③ 白烧 token（52 条消息 ≈ 9.9k prompt tokens）。
    ///
    /// 判据只用 Core 打的 `turnID`，不靠位置猜：这一轮有 assistant 消息就留下。正在跑的那一轮
    /// （`keeping`）永远保留——它的 assistant 消息还没写进历史。旧快照没有编号，无从判断，一律留下。
    static func strippingOrphanTurns(
        _ messages: [AIAgentMessage],
        keeping currentTurnID: Int?
    ) -> [AIAgentMessage] {
        var turnsWithAssistant: Set<Int> = []
        for message in messages where message.role == .assistant {
            if let turnID = message.turnID { turnsWithAssistant.insert(turnID) }
        }
        return messages.filter { message in
            guard let turnID = message.turnID else { return true }
            return turnID == currentTurnID || turnsWithAssistant.contains(turnID)
        }
    }

    private func prepareMessagesForProvider(
        _ rawMessages: [AIAgentMessage],
        session: AISession,
        turnID: Int,
        isFirstIteration: Bool
    ) async -> [AIAgentMessage] {
        let messages = Self.strippingOrphanTurns(rawMessages, keeping: turnID)
        if messages.count != rawMessages.count {
            Logger.debug(
                "LLMExecutor",
                "strippingOrphanTurns: dropped \(rawMessages.count - messages.count) message(s) from failed/interrupted turns"
            )
        }
        guard isFirstIteration else { return messages }

        // Find the last user message that contains .text (not .toolResult)
        guard let lastIndex = messages.lastIndex(where: { msg in
            msg.role == .user && msg.content.contains(where: {
                if case .text = $0 { return true }
                return false
            })
        }) else {
            return messages
        }

        let lastMsg = messages[lastIndex]

        // Skip messages that contain tool results
        let hasToolResult = lastMsg.content.contains(where: {
            if case .toolResult = $0 { return true }
            return false
        })
        if hasToolResult { return messages }

        // Collect context entries: BuiltIn → Agent-level → Session-level
        var allEntries: [MessageContextEntry] = []

        let builtIn = BuiltInMessageContext()
        allEntries.append(contentsOf: await builtIn.messageContext())

        if let mask = session.agentMask {
            let providers = mask.profile.messageContextProviders
            for provider in providers {
                allEntries.append(contentsOf: await provider.messageContext())
            }
        }

        for provider in session.messageContextProviders {
            allEntries.append(contentsOf: await provider.messageContext())
        }

        // Format the wrapped message
        let rawText = lastMsg.text
        let wrappedText = MessageContextFormatter.format(entries: allEntries, userText: rawText)

        // Replace text content in the message
        var wrappedContent: [AIAgentMessage.Content] = []
        var textReplaced = false
        for part in lastMsg.content {
            if case .text = part, !textReplaced {
                wrappedContent.append(.text(wrappedText))
                textReplaced = true
            } else {
                wrappedContent.append(part)
            }
        }

        let wrappedMsg = AIAgentMessage(
            id: lastMsg.id,
            role: lastMsg.role,
            content: wrappedContent,
            createdAt: lastMsg.createdAt,
            turnID: lastMsg.turnID
        )

        var result = messages
        result[lastIndex] = wrappedMsg

        let entryLabels = allEntries.map(\.label).joined(separator: ", ")
        Logger.debug("LLMExecutor", "messageContext injected: entries=[\(entryLabels)], wrappedLength=\(wrappedText.count)")

        return result
    }
}
