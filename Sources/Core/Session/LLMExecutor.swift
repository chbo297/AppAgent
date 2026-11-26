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

    /// 发给模型的历史里最多保留几个带图的工具结果（截图等）的原图。
    static let recentToolImageLimit = 2

    /// 单次回复撞到输出上限（max_tokens）后，每轮最多自动续写几次。
    static let maxOutputContinuations = 3

    /// 续写时插给模型的指令（不展示）。措辞参照 Claude Code 的同类恢复提示；
    /// 有调用被截断时点名，否则模型常常原样再写一遍同样长的参数（实测 Kimi K3）。
    static func outputLimitResumeNote(discardedTools: [String]) -> String {
        var note = "[Output token limit hit. Resume directly from where you stopped: no apology, no recap. If the cut happened mid-sentence, continue mid-sentence. Break remaining work into smaller pieces.]"
        if !discardedTools.isEmpty {
            let names = discardedTools.map { "`\($0)`" }.joined(separator: ", ")
            note += "\n[Your call to \(names) was cut off by the output limit and was NOT executed. Call it again with arguments several times smaller; split long content across multiple calls.]"
        }
        return note
    }

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

    /// 一轮的请求从哪来：用户发言，或 App 代发（见 `AIAgentMessage.appRequest`）。
    public enum Request: Sendable {
        case user(String, attachments: [AIAgentMessage.Attachment])
        case app(String, trigger: String?)
    }

    /// Run the LLM execution loop for a user message.
    ///
    /// Integrates the full lifecycle: adds the user message, resolves the provider,
    /// manages UI state, drives the LLM ↔ tool loop, and updates the session on completion.
    public func run(
        _ text: String,
        attachments: [AIAgentMessage.Attachment] = []
    ) -> AsyncStream<AIAgentEvent> {
        run(.user(text, attachments: attachments))
    }

    /// Run the LLM execution loop for one request. 两种请求只在「怎么落进历史」上不同，其余完全一致。
    public func run(_ request: Request) -> AsyncStream<AIAgentEvent> {
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

            // 整轮都在后台执行断言的保护下跑：切到后台再回来这种常见操作不该把这一轮打断。
            // 这条 defer 注册得最早，所以 LIFO 下它最后执行 —— 断言在收尾全部做完之后才释放。
            let endBackgroundAssertion = BackgroundActivity.begin("AppAgent run")
            defer { endBackgroundAssertion() }

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
                        await session?.hostStateReporter.endRun(runID)
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

            guard self.isActiveRun(runID), !Task.isCancelled else {
                journal.failed(AIAgentError.cancelled)
                return
            }

            // 先把 UI 拨到「刚开始」、落用户消息，再去等宿主状态：宿主慢的时候，
            // 用户至少看得到自己的话和「处理中」，也能按停止。
            journal.prepareUI()

            let turnID: Int
            switch request {
            case .user(let text, let attachments):
                turnID = session.addUserMessage(text, attachments: attachments)
                Logger.info("LLMExecutor", "run: sessionId=\(session.id), text=\"\(text.prefix(100))\(text.count > 100 ? "..." : "")\", attachments=\(attachments.count), messageCount=\(session.messages.count)")
            case .app(let text, let trigger):
                turnID = session.addAppRequest(text, trigger: trigger)
                Logger.info("LLMExecutor", "run(app): sessionId=\(session.id), trigger=\(trigger ?? "-"), chars=\(text.count), messageCount=\(session.messages.count)")
            }
            journal.openTurn(turnID: turnID)

            await session.hostStateReporter.startRun(runID)
            guard self.isActiveRun(runID), !Task.isCancelled else {
                journal.failed(AIAgentError.cancelled)
                return
            }

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
            // An old output stream can be cancelled after its replacement started.
            // Only the admitted cancellation may touch the current run's UI, and
            // clear it before another run can claim the executor.
            session?.uiState.setStreaming(false)
            return task
        }
        task?.cancel()
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
        if let sources = await session.agentMask?.toolCentral.toolSourcesPrompt() {
            result.append(.content(SystemPrompt(sources)))
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

        // Filter: only enabled tools; on-demand groups only after `load_tools` in this session.
        let loadedGroups = session.loadedToolGroups(groupOf: { name in
            allTools[name]?.deferredGroup
        })
        let filtered = allTools.values.filter { tool in
            guard tool.enabled else {
                return false
            }
            guard let group = tool.deferredGroup else {
                return true
            }
            return loadedGroups.contains(group)
        }

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

    // MARK: - Context Compaction (主动 / 报错后两处共用)

    /// 发给模型的估算长度超过窗口的这个比例就主动压缩。
    static let compactionTriggerRatio = 0.85

    /// 压缩目标：窗口的这个比例。留足余量，避免下一两次工具往返又顶到阈值。
    static let compactionTargetRatio = 0.4

    /// 把 `state.providerMessages` 压到窗口的 `compactionTargetRatio`。
    ///
    /// 压缩会把旧的宿主快照和工具结果（连同附在后面的使用手册）一起截掉，所以要让宿主基线失效、
    /// 下次强制重拍快照，并清空已下发的工具手册记录。返回 false = 没有压缩器或不知道窗口大小。
    private func compactProviderMessages(
        state: inout RunLoopState,
        session: AISession,
        reason: String
    ) async -> Bool {
        guard let compressor = self.compressor,
              let contextWindow = state.provider.modelSpec(for: state.modelId)?.contextWindow else {
            return false
        }
        let estimatedTokens = compressor.estimateTokens(messages: state.providerMessages)
        let targetTokens = Int(Double(contextWindow) * Self.compactionTargetRatio)
        let beforeCount = state.providerMessages.count
        state.providerMessages = await compressor.compress(
            messages: state.providerMessages,
            targetTokens: targetTokens
        )
        await session.hostStateReporter.invalidateModelBaseline()
        state.forceFullHostStateNextRequest = true
        session.deliveredToolGuides = []
        Logger.info("LLMExecutor", "context compressed (\(reason)): ~\(estimatedTokens) → target ~\(targetTokens) tokens, messages: \(beforeCount) → \(state.providerMessages.count)")
        // 压缩会改变模型看到的内容，诊断包里必须看得到，否则「答非所问」只能拼原始请求去查。
        AppAgentDebugLog.shared.record(
            .info,
            message: "上下文压缩（\(reason)）：估算 ~\(estimatedTokens) tokens，目标 ~\(targetTokens)（窗口 \(contextWindow)），消息 \(beforeCount) → \(state.providerMessages.count) 条",
            sessionId: session.id,
            provider: state.provider.name,
            apiProtocol: state.provider.apiProtocol.rawValue,
            modelId: state.modelId,
            iteration: state.iteration,
            reason: "context_compressed"
        )
        return true
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

        state.forceFullHostStateNextRequest = true
        // 换模型要从完整历史重建「发给模型的视图」，而不是直接用原始历史：否则会带回已剔除的
        // 孤儿轮（Anthropic 连续 user 报错）、丢掉中断说明和最新请求上的上下文包装。
        state.providerMessages = await self.prepareMessagesForProvider(
            state.currentMessages,
            session: context.session,
            turnID: context.turnID,
            isFirstIteration: true
        )
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
            await session.hostStateReporter.discard(preparation)
        }

        func commitPreparedHostContext(_ preparation: PreparedHostContext?) async -> Bool {
            guard let preparation else {
                return true
            }
            do {
                try await session.hostStateReporter.commit(preparation)
                return true
            } catch {
                Logger.warning(
                    "LLMExecutor",
                    "host context commit rejected; forcing a fresh snapshot: \(error)"
                )
                await session.hostStateReporter.invalidateModelBaseline()
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

            // 4. Build the provider-only view once; the complete historical view
            // remains unchanged for UI, persistence and every terminal path.
            if state.iteration == 1 {
                state.providerMessages = await self.prepareMessagesForProvider(
                    state.currentMessages,
                    session: session,
                    turnID: turnID,
                    isFirstIteration: true
                )
            }
            // 旧截图每轮都整批重发会把请求撑到几 MB；只给模型留最近两张，用户附图只留当前轮的。
            state.providerMessages = SimpleContextCompressor.retainingRecentImages(
                state.providerMessages,
                keep: Self.recentToolImageLimit,
                currentTurnID: turnID
            )
            if let compressor = self.compressor,
               let contextWindow = state.provider.modelSpec(for: state.modelId)?.contextWindow,
               compressor.estimateTokens(messages: state.providerMessages)
                   > Int(Double(contextWindow) * Self.compactionTriggerRatio) {
                if await self.compactProviderMessages(state: &state, session: session, reason: "接近窗口上限") {
                    journal.notice("对话接近长度上限，已自动压缩较早的内容")
                }
            }

            // 5. Stream completion from provider
            let preparedHostContext: PreparedHostContext?
            do {
                preparedHostContext = try await session.hostStateReporter.prepare(
                    runID: runID,
                    forceFullState: state.forceFullHostStateNextRequest
                )
            } catch {
                Logger.error("LLMExecutor", "host context preparation failed: \(error)")
                finishWithError(error, messages: state.currentMessages)
                return
            }
            state.forceFullHostStateNextRequest = false

            var messagesForProvider = state.providerMessages
            if let preparedHostContext {
                messagesForProvider.append(preparedHostContext.message(turnID: turnID))
            }
            let requestID = UUID().uuidString
            let providerStream = ModelRequestLogContext.$requestID.withValue(requestID) {
                state.provider.streamCompletion(
                    messages: messagesForProvider,
                    system: systemParts,
                    tools: toolSegments,
                    modelId: state.modelId
                )
            }
            let stream = StreamIdleGuard.wrap(
                providerStream,
                idleLimit: session.executionPolicy.streamIdleTimeout,
                onStall: { [sessionId = session.id, provider = state.provider,
                            modelId = state.modelId, iteration = state.iteration] idle in
                    Logger.error("LLMExecutor", "streamStalled: iteration=\(iteration), idle=\(String(format: "%.1f", idle))s")
                    AppAgentDebugLog.shared.record(
                        .failure,
                        message: String(format: "模型响应中断：%.1fs 没有新内容，按可重试错误处理", idle),
                        sessionId: sessionId,
                        requestId: requestID,
                        provider: provider.name,
                        apiProtocol: provider.apiProtocol.rawValue,
                        modelId: modelId,
                        iteration: iteration,
                        reason: FailoverReason.transport.rawValue
                    )
                }
            )
            // 请求已发出，等首个内容：卡在这一步基本是网络 / 鉴权 / 网关问题。
            setStage(.requesting)
            Logger.debug("LLMExecutor", "streamCompletion requested: request=\(requestID), session=\(session.id), iteration=\(state.iteration), provider=\(state.provider.name), model=\(state.modelId), messageCount=\(messagesForProvider.count), toolCount=\(toolSegments.count)")
            AppAgentDebugLog.shared.record(
                .request,
                message: "发起模型请求（消息 \(state.currentMessages.count) 条，工具 \(toolSegments.count) 个）",
                sessionId: session.id,
                requestId: requestID,
                provider: state.provider.name,
                apiProtocol: state.provider.apiProtocol.rawValue,
                modelId: state.modelId,
                iteration: state.iteration
            )
            let streamStart = Date()

            // Consume the stream
            var assistantText = ""
            var toolCalls: [AIAgentMessage.ToolCall] = []
            var discardedToolNames: [String] = []
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

                    case .discardedToolCall(let name):
                        discardedToolNames.append(name.isEmpty ? "tool" : name)

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
                    state.forceFullHostStateNextRequest = true
                    let error = ModelError.providerError(
                        "Provider stream ended without a stop reason."
                    )
                    Logger.error(
                        "LLMExecutor",
                        "streamProtocolError: iteration=\(state.iteration), missing stop reason"
                    )
                    AppAgentDebugLog.shared.record(
                        .failure,
                        message: "模型响应流结束但缺少终止原因",
                        sessionId: session.id,
                        requestId: requestID,
                        provider: state.provider.name,
                        apiProtocol: state.provider.apiProtocol.rawValue,
                        modelId: state.modelId,
                        iteration: state.iteration,
                        reason: "stream_protocol",
                        durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                    )
                    finishWithError(error, messages: state.currentMessages)
                    return
                }
                Logger.info("LLMExecutor", "streamConsumed: textLength=\(assistantText.count), toolCalls=\(toolCalls.count)[\(toolCalls.map(\.name).joined(separator: ", "))], stopReason=\(stopReason)")
                // 协议异常由下方对应分支记 failure，不能先记成成功。
                if stopReason != .unknown && !(stopReason == .toolUse && toolCalls.isEmpty) {
                    AppAgentDebugLog.shared.record(
                        .success,
                        message: "模型返回完成（文本 \(assistantText.count) 字，工具调用 \(toolCalls.count) 次，stop=\(stopReason)）",
                        sessionId: session.id,
                        requestId: requestID,
                        provider: state.provider.name,
                        apiProtocol: state.provider.apiProtocol.rawValue,
                        modelId: state.modelId,
                        iteration: state.iteration,
                        durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                    )
                }
                state.retryCount = 0
            } catch where Task.isCancelled || ErrorClassifier.isCancellation(error) {
                await discardPreparedHostContext(preparedHostContext)
                let error = AIAgentError.cancelled
                Logger.info("LLMExecutor", "streamCancelled: iteration=\(state.iteration)")
                finishWithError(error, messages: state.currentMessages)
                return
            } catch {
                await discardPreparedHostContext(preparedHostContext)
                state.forceFullHostStateNextRequest = true
                let error: Error = ModelNetworkError(
                    error, baseURL: state.provider.baseURL,
                    secrets: [state.provider.apiKey] + Array(state.provider.customHeaders.values)
                ) ?? error
                let classified = ErrorClassifier.classify(error)
                Logger.error("LLMExecutor", "streamError: iteration=\(state.iteration), reason=\(classified.reason), retryable=\(classified.retryable), retryCount=\(state.retryCount)/\(retryPolicy.maxRetries), error=\(error.localizedDescription)")
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: classified.message,
                    sessionId: session.id,
                    requestId: requestID,
                    provider: state.provider.name,
                    apiProtocol: state.provider.apiProtocol.rawValue,
                    modelId: state.modelId,
                    iteration: state.iteration,
                    reason: classified.reason.rawValue,
                    statusCode: classified.statusCode,
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                )

                // 上下文超长：原样重发必然再失败。压缩一次再试；本轮已经压过还超，就不再重试。
                if classified.shouldCompress {
                    if !state.didReactiveCompaction,
                       await self.compactProviderMessages(state: &state, session: session, reason: "模型报上下文超长") {
                        state.didReactiveCompaction = true
                        journal.attemptDiscarded()
                        journal.notice("对话超出模型长度上限，已自动压缩较早的内容后重试")
                        continue
                    }
                } else if classified.retryable && state.retryCount < retryPolicy.maxRetries {
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
                    // 重试和换模型一样要丢掉这次尝试已经吐出来的正文，否则界面上两截会接起来
                    // （`assistantText` 是每轮迭代的局部变量，重来时从空开始，但 uiState 不会）。
                    // 流被看门狗判死后重试是最常见的入口，漏了这一句就是「半截 + 完整」两遍。
                    journal.attemptDiscarded()
                    continue
                }

                // 重试用尽后，明确支持回退的错误可以切换模型；如果流已经产出
                // 部分正文或工具调用，即使是 5xx 中断也应切换，避免把半截响应
                // 作为最终结果暴露给用户。
                let hasPartialOutput = !assistantText.isEmpty || !toolCalls.isEmpty
                if classified.shouldFallback || (hasPartialOutput && !(error is ModelNetworkError)) {
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
                state.forceFullHostStateNextRequest = true
                Logger.error(
                    "LLMExecutor",
                    "stopReason=toolUse 但没有解析到任何工具调用；model=\(state.modelId)@\(state.provider.apiProtocol.rawValue), textLength=\(assistantText.count)"
                )
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: "模型返回 stop=tool_use 但没有任何工具调用（可能是该端点的 tool_calls 流式格式没被解析）",
                    sessionId: session.id,
                    requestId: requestID,
                    provider: state.provider.name,
                    apiProtocol: state.provider.apiProtocol.rawValue,
                    modelId: state.modelId,
                    iteration: state.iteration,
                    reason: "toolUseWithoutCalls",
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
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
                state.forceFullHostStateNextRequest = true
                let error = ModelError.providerError(
                    "Provider returned an unknown stop reason."
                )
                Logger.error(
                    "LLMExecutor",
                    "streamProtocolError: iteration=\(state.iteration), unknown stop reason"
                )
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: "模型返回未知终止原因，详见同 request 的原始响应日志",
                    sessionId: session.id,
                    requestId: requestID,
                    provider: state.provider.name,
                    apiProtocol: state.provider.apiProtocol.rawValue,
                    modelId: state.modelId,
                    iteration: state.iteration,
                    reason: "stream_protocol",
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                )
                finishWithError(error, messages: state.currentMessages)
                return
            }

            // The model has produced a complete, protocol-valid response. Only now
            // record what host state the model has seen. Tool execution may still fail,
            // but the provider did receive this host context successfully.
            let committedHostContext = await commitPreparedHostContext(preparedHostContext)
            if committedHostContext {
                state.providerMessages = messagesForProvider
            } else {
                // 只丢掉这次没提交成功的宿主上下文：providerMessages 本来就不含它，
                // 保留已整理（剔孤儿轮、上下文包装、压缩）的视图，下一请求强制重发快照。
                state.forceFullHostStateNextRequest = true
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

            // 7. If tool_use, execute tools and loop.
            // 撞到单次输出上限（max_tokens）时，已经完整收到的工具调用照常执行；
            // 写到一半的那个调用 mapper 已经丢掉，模型看到结果后会自己重发。
            if stopReason == .toolUse || stopReason == .maxTokens, !toolCalls.isEmpty {
                state.continuedText = ""
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

            // 8. 撞到单次输出上限、又没有可执行的工具调用：保留已输出的部分，让模型接着写。
            // 做法参照 Claude Code：插一句不展示的指令「直接接着写、别道歉别复述」，
            // 每轮最多续 `maxOutputContinuations` 次，超过就带着已有内容收尾。
            if stopReason == .maxTokens {
                // 实测（2026-11）：GLM-5.3 / MiniMax-M3 续写时 300 tokens 全花在思考上、正文为空。
                // 再续多半一样，连续两次「既没正文也没被截断的调用」就停。被截断的调用不算空：模型要拆小重发。
                let producedNothing = assistantText.isEmpty && discardedToolNames.isEmpty
                state.emptyOutputLimitHits = producedNothing ? state.emptyOutputLimitHits + 1 : 0
                if state.outputContinuations < Self.maxOutputContinuations,
                   state.emptyOutputLimitHits < 2,
                   state.iteration < maxIterations {
                    state.outputContinuations += 1
                    state.continuedText = AIAgentMessage.joiningContinuation(state.continuedText, assistantText)
                    let note = AIAgentMessage.agentNote(
                        Self.outputLimitResumeNote(discardedTools: discardedToolNames),
                        turnID: turnID
                    )
                    state.currentMessages.append(note)
                    state.providerMessages.append(note)
                    Logger.info("LLMExecutor", "maxTokens: auto-continue \(state.outputContinuations)/\(Self.maxOutputContinuations), partialTextLength=\(assistantText.count)")
                    AppAgentDebugLog.shared.record(
                        .retry,
                        message: "回复达到单次输出上限，自动续写（\(state.outputContinuations)/\(Self.maxOutputContinuations)）",
                        sessionId: session.id,
                        requestId: requestID,
                        provider: state.provider.name,
                        apiProtocol: state.provider.apiProtocol.rawValue,
                        modelId: state.modelId,
                        iteration: state.iteration,
                        attempt: state.outputContinuations,
                        reason: "max_tokens"
                    )
                    journal.notice("回复达到单次输出上限，正在接着输出…")
                    continue
                }
                Logger.warning("LLMExecutor", "maxTokens: stop continuing (continuations=\(state.outputContinuations), emptyHits=\(state.emptyOutputLimitHits))")
                journal.notice(state.emptyOutputLimitHits >= 2
                    ? "模型的思考过程连续占满了单次输出上限，已停止续写；可以调高单次输出上限后重试"
                    : "回复多次达到单次输出上限，已停止续写，下面是目前的内容")
            }

            // 9. Done — emit result
            let finalText = AIAgentMessage.joiningContinuation(state.continuedText, assistantText)
            let result = AIAgentFinish(text: finalText, updatedMessages: state.currentMessages)
            Logger.info("LLMExecutor", "completed: iteration=\(state.iteration), textLength=\(finalText.count), totalMessages=\(state.currentMessages.count)")

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
    /// 同一会话里第一次调用带 `usageGuide` 的工具时，不论成败都把手册附在结果后面：
    /// 第一次调错参数正是最需要手册的时候。
    private static func executeSingleTool(
        call: AIAgentMessage.ToolCall,
        session: AISession,
        toolTimeout: TimeInterval
    ) async -> (String, AIAgentMessage.Content, AIAgentEvent?) {
        let outcome = await runSingleTool(call: call, session: session, toolTimeout: toolTimeout)
        guard let guide = session.tool(named: call.name)?.usageGuide,
              case .toolResult(let result) = outcome.1,
              session.claimToolGuide(call.name) else {
            return outcome
        }
        let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
            toolCallId: result.toolCallId,
            content: result.content + Self.toolGuideSuffix(name: call.name, guide: guide),
            images: result.images,
            isError: result.isError
        ))
        return (outcome.0, content, outcome.2)
    }

    static func toolGuideSuffix(name: String, guide: String) -> String {
        "\n\n--- \(name) usage guide (sent once per conversation; follow it for later calls) ---\n\(guide)"
    }

    private static func runSingleTool(
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

            // The offered list is a snapshot; a tool may have been disabled while the model ran.
            try requireEnabled(tool)

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

            // 静态判定就能确定失败的调用，在弹授权卡之前拒掉。放在授权之前而不是执行之前是
            // 关键：否则用户会为一个不可能成功的操作点「允许」（真机实测一次 4.9 秒），
            // 而且会逐渐养成盲签的习惯。
            if let rejection = await tool.preflightRejection(for: toolArguments, session: session) {
                Logger.info("LLMExecutor",
                            "toolPreflightRejected: name=\(call.name), id=\(call.id), reason=\(rejection)")
                let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                    toolCallId: call.id, content: "Error: \(rejection)", isError: true
                ))
                let err = AIAgentError.toolExecutionFailed(toolName: call.name,
                                                           underlying: AIAgentError.toolExecutionDenied(rejection))
                return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
            }

            // Host policy is independent of remembered approvals and tool safety.
            // Pass every executable argument so multi-op tools retain their full meaning.
            try await ToolExecutionAccess.requireAllowed(tool, arguments: toolArguments, session: session)

            // Preflight and the gate can suspend. Disabled tools must not prompt.
            try requireEnabled(tool)

            // 宿主登记的权限（如「修改 App 运行时」）。已授权直接放行，否则弹权限卡；
            // 权限卡已经覆盖了这次调用，下面的安全级别卡不再重复问。
            var coveredByPermission = false
            if let permission = session.requiredPermission(for: tool, arguments: toolArguments) {
                if let rejection = await session.authorizePermission(
                    permission, tool: call.name, detail: justification
                ) {
                    let err = AIAgentError.toolExecutionDenied(call.name)
                    let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                        toolCallId: call.id, content: "Error: \(rejection)", isError: true
                    ))
                    return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
                }
                if Task.isCancelled {
                    Logger.info("LLMExecutor", "toolAbandonedAfterPermission: name=\(call.name), id=\(call.id)")
                    let err = AIAgentError.toolExecutionDenied(call.name)
                    let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                        toolCallId: call.id,
                        content: "Error: Run was cancelled while waiting for permission of '\(call.name)'",
                        isError: true
                    ))
                    return (call.id, content, .toolCallFailed(toolCallId: call.id, name: call.name, error: err))
                }
                try requireEnabled(tool)
                coveredByPermission = true
            }

            // Safety level check：统一走 session 的决策中心，由 AppAgent 自己的面板
            // 呈现（宿主策略可先行定夺），没人能回答时兜底拒绝。
            if !coveredByPermission && (level == .sensitive || level == .dangerous) {
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
                    case .allowForSession, .allowAlways:
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
                    // Recheck after authorization and task scheduling, immediately before execution.
                    try await ToolExecutionAccess.requireAllowed(tool, arguments: toolArguments, session: session)
                    try requireEnabled(tool)
                    return try await tool.execute(arguments: toolArguments, session: session)
                }
                // 等用户作答的工具由卡片倒计时收尾；用户关掉倒计时后必须一直等，不能被这里掐断。
                if !tool.waitsForUser {
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(toolTimeout * 1_000_000_000))
                        throw AIAgentError.toolExecutionTimedOut(toolName: call.name)
                    }
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

    private struct DisabledToolError: LocalizedError {
        let name: String

        var errorDescription: String? {
            "Tool '\(name)' is disabled. Do not retry it unless it is enabled again."
        }
    }

    private static func requireEnabled(_ tool: any ToolProtocol) throws {
        guard tool.enabled else {
            throw DisabledToolError(name: tool.name)
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
    ///
    /// 例外：**紧挨在当前轮之前**的那个孤儿轮，用户往往是在补充或纠正它。真机上「移除写着册的
    /// 按钮」被打断后用户补了一句「测试的测」（纠正语音识别），整轮丢掉后模型把它当成连通测试。
    /// 这一轮只留用户原话，后面补一条说明，user / assistant 依旧交替。
    static func strippingOrphanTurns(
        _ messages: [AIAgentMessage],
        keeping currentTurnID: Int?
    ) -> [AIAgentMessage] {
        var turnsWithAssistant: Set<Int> = []
        for message in messages where message.role == .assistant {
            if let turnID = message.turnID { turnsWithAssistant.insert(turnID) }
        }
        let carriedTurnID = precedingOrphanTurn(
            messages,
            currentTurnID: currentTurnID,
            turnsWithAssistant: turnsWithAssistant
        )
        var result: [AIAgentMessage] = []
        var carried: [AIAgentMessage] = []
        for message in messages {
            guard let turnID = message.turnID else {
                result.append(message)
                continue
            }
            if turnID == currentTurnID || turnsWithAssistant.contains(turnID) {
                if turnID == currentTurnID, !carried.isEmpty {
                    result.append(contentsOf: carried)
                    result.append(AIAgentMessage(
                        role: .assistant,
                        content: [.text("[This request was interrupted before any reply was produced. The user's next message may refine or correct it.]")],
                        turnID: carriedTurnID,
                        messageType: .assistant,
                        source: .agent,
                        displayPolicy: .hidden
                    ))
                    carried.removeAll()
                }
                result.append(message)
            } else if turnID == carriedTurnID, message.role == .user, message.source == .user {
                carried.append(message)
            }
        }
        return result
    }

    private static func precedingOrphanTurn(
        _ messages: [AIAgentMessage],
        currentTurnID: Int?,
        turnsWithAssistant: Set<Int>
    ) -> Int? {
        guard let currentTurnID,
              let firstCurrent = messages.firstIndex(where: { message in
                  message.turnID == currentTurnID
              }),
              firstCurrent > 0,
              let previous = messages[firstCurrent - 1].turnID,
              previous != currentTurnID,
              !turnsWithAssistant.contains(previous) else {
            return nil
        }
        return previous
    }

    func prepareMessagesForProvider(
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

        // Find the last genuine user request: text or user attachments (an image-only
        // message has no .text part), never a tool result.
        guard let lastIndex = messages.lastIndex(where: { msg in
            msg.role == .user && !msg.isAgentNote && msg.content.contains(where: { part in
                switch part {
                case .text, .attachment:
                    return true
                default:
                    return false
                }
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
        if !textReplaced {
            // Attachment-only request: carry the context as a leading text part.
            wrappedContent.insert(.text(wrappedText), at: 0)
        }

        let wrappedMsg = AIAgentMessage(
            id: lastMsg.id,
            role: lastMsg.role,
            content: wrappedContent,
            createdAt: lastMsg.createdAt,
            turnID: lastMsg.turnID,
            messageType: lastMsg.messageType,
            source: lastMsg.source,
            displayPolicy: lastMsg.displayPolicy,
            trigger: lastMsg.trigger,
            eventId: lastMsg.eventId,
            causedByToolCallId: lastMsg.causedByToolCallId
        )

        var result = messages
        result[lastIndex] = wrappedMsg

        let entryLabels = allEntries.map(\.label).joined(separator: ", ")
        Logger.debug("LLMExecutor", "messageContext injected: entries=[\(entryLabels)], wrappedLength=\(wrappedText.count)")

        return result
    }
}
