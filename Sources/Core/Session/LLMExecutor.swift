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

            defer {
                self.clearRunTask(runID: runID)
                outputContinuation.finish()
            }

            guard let session = self.session else {
                outputContinuation.yield(.error(AIAgentError.sessionReleased))
                return
            }

            guard self.isActiveRun(runID) else { return }

            // Reset UI state before validation so early errors surface consistently.
            session.uiState.resetStreamingText()
            session.uiState.resetReasoningText()
            session.uiState.setError(nil)
            session.uiState.setStreaming(true)

            // Add user message to session
            session.addUserMessage(text)
            Logger.info("LLMExecutor", "run: sessionId=\(session.id), text=\"\(text.prefix(100))\(text.count > 100 ? "..." : "")\", messageCount=\(session.messages.count)")

            // Resolve provider from session
            guard let agent = session.agentMask?.agent else {
                let error = ModelError.providerError("No agent attached")
                Logger.error("LLMExecutor", "run: sessionId=\(session.id), no agent attached")
                if self.isActiveRun(runID) {
                    session.uiState.setStreaming(false)
                    session.uiState.setError(error)
                }
                outputContinuation.yield(.error(error))
                return
            }

            guard let provider = session.provider, let modelId = session.modelId else {
                let error = ModelError.providerError("No provider configured")
                Logger.error("LLMExecutor", "run: sessionId=\(session.id), no provider/model configured")
                if self.isActiveRun(runID) {
                    session.uiState.setStreaming(false)
                    session.uiState.setError(error)
                    agent.sessionDidEncounterError(session, error: error)
                }
                outputContinuation.yield(.error(error))
                return
            }

            let maxIter = session.agentMask?.profile.maxIterations ?? agent.profile.maxIterations

            // Run the execution loop
            await self.runLoop(
                runID: runID,
                initialMessages: session.messages,
                provider: provider,
                modelId: modelId,
                maxIterations: maxIter,
                session: session,
                agent: agent,
                continuation: outputContinuation
            )
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

    /// 按 modelPolicy（primary + fallbacks）顺序取第一个尚未尝试过的可解析模型。
    private func resolveNextModel(
        agent: AIAgent,
        policyRefs: [String],
        tried: Set<String>
    ) async -> (ref: String, provider: any ModelProvider, modelId: String)? {
        for ref in policyRefs {
            guard let resolved = await agent.providerCentral.resolve(modelReference: ref) else { continue }
            guard !tried.contains(Self.modelKey(resolved.provider, resolved.modelId)) else { continue }
            return (ref, resolved.provider, resolved.modelId)
        }
        return nil
    }

    // MARK: - Run Loop


    private func runLoop(
        runID: UUID,
        initialMessages: [AIAgentMessage],
        provider: any ModelProvider,
        modelId: String,
        maxIterations: Int,
        session: AISession,
        agent: AIAgent,
        continuation: AsyncStream<AIAgentEvent>.Continuation
    ) async {
        var currentMessages = initialMessages
        var iteration = 0
        var retryCount = 0
        var loopDetector = ToolLoopDetector()

        // 运行期模型回退：当前模型不可用（或重试用尽）时，按 modelPolicy 的顺序
        // 换下一个还没试过的模型，继续同一轮对话，不打断用户。
        var provider = provider
        var modelId = modelId
        let policyRefs: [String] = agent.modelPolicy.map { [$0.primary] + $0.fallbacks } ?? []
        var triedModelKeys: Set<String> = [Self.modelKey(provider, modelId)]

        func finishWithError(_ error: Error, messages: [AIAgentMessage]) {
            if self.isActiveRun(runID) {
                session.updateMessages(messages)
                session.uiState.setStreaming(false)
                session.uiState.setError(error)
                agent.sessionDidEncounterError(session, error: error)
            }
            continuation.yield(.error(error))
        }

        defer {
            if self.isActiveRun(runID) {
                session.uiState.setStreaming(false)
            }
        }

        while iteration < maxIterations {
            // Check cancellation
            guard !Task.isCancelled else {
                let error = AIAgentError.cancelled
                Logger.info("LLMExecutor", "cancelled at iteration \(iteration)")
                finishWithError(error, messages: currentMessages)
                return
            }

            // Verify session is still alive
            guard self.session != nil else {
                let error = AIAgentError.sessionReleased
                Logger.error("LLMExecutor", "session released during execution at iteration \(iteration)")
                finishWithError(error, messages: currentMessages)
                return
            }

            iteration += 1
            currentIteration = iteration
            continuation.yield(.started(turn: iteration))
            Logger.info("LLMExecutor", "--- iteration \(iteration)/\(maxIterations) start, messageCount=\(currentMessages.count) ---")

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

            // 4. Context compression
            if let compressor = self.compressor,
               let contextWindow = provider.modelSpec(for: modelId)?.contextWindow {
                let estimatedTokens = compressor.estimateTokens(messages: currentMessages)
                let threshold = Int(Double(contextWindow) * 0.85)
                if estimatedTokens > threshold {
                    let targetTokens = Int(Double(contextWindow) * 0.6)
                    currentMessages = await compressor.compress(messages: currentMessages, targetTokens: targetTokens)
                    Logger.info("LLMExecutor", "context compressed: ~\(estimatedTokens) → ~\(targetTokens) tokens, messages: \(currentMessages.count)")
                }
            }

            // 5. Stream completion from provider
            let messagesForProvider = await self.prepareMessagesForProvider(
                currentMessages, session: session, isFirstIteration: (iteration == 1)
            )
            let stream = provider.streamCompletion(
                messages: messagesForProvider,
                system: systemParts,
                tools: toolSegments,
                modelId: modelId
            )
            Logger.debug("LLMExecutor", "streamCompletion requested: provider=\(provider.name), model=\(modelId), messageCount=\(currentMessages.count), toolCount=\(toolSegments.count)")
            AppAgentDebugLog.shared.record(
                .request,
                message: "发起模型请求（消息 \(currentMessages.count) 条，工具 \(toolSegments.count) 个）",
                sessionId: session.id,
                provider: provider.name,
                apiProtocol: provider.apiProtocol.rawValue,
                modelId: modelId,
                iteration: iteration
            )
            let streamStart = Date()

            // Consume the stream
            var assistantText = ""
            var toolCalls: [AIAgentMessage.ToolCall] = []
            var stopReason: ProviderStreamEvent.StopReason = .endTurn

            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        assistantText += delta
                        continuation.yield(.streamingContent(delta))
                        if self.isActiveRun(runID) {
                            session.uiState.appendStreamingText(delta)
                        }

                    case .reasoningDelta(let delta):
                        // 思考过程只用于展示：进 uiState 与事件流，不写入消息历史。
                        continuation.yield(.reasoningContent(delta))
                        if self.isActiveRun(runID) {
                            session.uiState.appendReasoningText(delta)
                        }

                    case .toolCall(let call):
                        toolCalls.append(call)
                        continuation.yield(.toolCallStarted(call))

                    case .done(let reason):
                        stopReason = reason

                    case .usage(let input, let output):
                        continuation.yield(.usage(inputTokens: input, outputTokens: output))
                    }
                }
                Logger.info("LLMExecutor", "streamConsumed: textLength=\(assistantText.count), toolCalls=\(toolCalls.count)[\(toolCalls.map(\.name).joined(separator: ", "))], stopReason=\(stopReason)")
                AppAgentDebugLog.shared.record(
                    .success,
                    message: "模型返回完成（文本 \(assistantText.count) 字，工具调用 \(toolCalls.count) 次，stop=\(stopReason)）",
                    sessionId: session.id,
                    provider: provider.name,
                    apiProtocol: provider.apiProtocol.rawValue,
                    modelId: modelId,
                    iteration: iteration,
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                )
                retryCount = 0
            } catch is CancellationError {
                let error = AIAgentError.cancelled
                Logger.info("LLMExecutor", "streamCancelled: iteration=\(iteration)")
                finishWithError(error, messages: currentMessages)
                return
            } catch {
                let classified = ErrorClassifier.classify(error)
                Logger.error("LLMExecutor", "streamError: iteration=\(iteration), reason=\(classified.reason), retryable=\(classified.retryable), retryCount=\(retryCount)/\(retryPolicy.maxRetries), error=\(error)")
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: classified.message,
                    sessionId: session.id,
                    provider: provider.name,
                    apiProtocol: provider.apiProtocol.rawValue,
                    modelId: modelId,
                    iteration: iteration,
                    reason: classified.reason.rawValue,
                    statusCode: classified.statusCode,
                    durationMs: Int(Date().timeIntervalSince(streamStart) * 1000)
                )

                if classified.retryable && retryCount < retryPolicy.maxRetries {
                    retryCount += 1
                    let delay = retryPolicy.delay(for: retryCount - 1)
                    Logger.info("LLMExecutor", "retrying in \(String(format: "%.1f", delay))s (attempt \(retryCount)/\(retryPolicy.maxRetries))")
                    AppAgentDebugLog.shared.record(
                        .retry,
                        message: String(format: "%.1fs 后重试（%d/%d）", delay, retryCount, retryPolicy.maxRetries),
                        sessionId: session.id,
                        provider: provider.name,
                        apiProtocol: provider.apiProtocol.rawValue,
                        modelId: modelId,
                        iteration: iteration,
                        attempt: retryCount,
                        reason: classified.reason.rawValue
                    )
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        finishWithError(AIAgentError.cancelled, messages: currentMessages)
                        return
                    }
                    continue
                }

                // 重试用尽、或本来就不该重试（401/404/额度等）：换下一个可用模型继续本轮。
                if let next = await self.resolveNextModel(agent: agent, policyRefs: policyRefs, tried: triedModelKeys) {
                    let from = "\(modelId)@\(provider.apiProtocol.rawValue)"
                    triedModelKeys.insert(Self.modelKey(next.provider, next.modelId))
                    provider = next.provider
                    modelId = next.modelId
                    retryCount = 0
                    Logger.info("LLMExecutor", "model fallback: \(from) → \(next.ref) (reason=\(classified.reason))")
                    AppAgentDebugLog.shared.record(
                        .fallback,
                        message: "模型不可用，切换 \(from) → \(next.ref)",
                        sessionId: session.id,
                        provider: next.provider.name,
                        apiProtocol: next.provider.apiProtocol.rawValue,
                        modelId: next.modelId,
                        iteration: iteration,
                        reason: classified.reason.rawValue
                    )
                    if self.isActiveRun(runID) {
                        session.uiState.set(SessionUIState.activeModelKey, value: next.ref)
                    }
                    continue
                }

                finishWithError(error, messages: currentMessages)
                return
            }

            guard !Task.isCancelled else {
                finishWithError(AIAgentError.cancelled, messages: currentMessages)
                return
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
                currentMessages.append(AIAgentMessage(
                    role: .assistant, content: assistantParts, turnID: session.currentTurnID
                ))
            }

            // 7. If tool_use, execute tools and loop
            if stopReason == .toolUse, !toolCalls.isEmpty {
                let (toolResultParts, terminalError) = await executeToolsConcurrently(
                    calls: toolCalls,
                    session: session,
                    loopDetector: &loopDetector,
                    continuation: continuation
                )

                if let terminalError {
                    finishWithError(terminalError, messages: currentMessages)
                    return
                }

                guard !Task.isCancelled else {
                    finishWithError(AIAgentError.cancelled, messages: currentMessages)
                    return
                }

                // Add tool results as a user message. Wire 上必须是 user 角色，但它们是
                // 这一轮内部的过程，不是用户又说了话——所以打上同一个 turnID。
                currentMessages.append(AIAgentMessage(
                    role: .user, content: toolResultParts, turnID: session.currentTurnID
                ))
                continue
            }

            // 8. Done — emit result
            let result = AIAgentFinish(text: assistantText, updatedMessages: currentMessages)
            Logger.info("LLMExecutor", "completed: iteration=\(iteration), textLength=\(assistantText.count), totalMessages=\(currentMessages.count)")

            // Update session state
            if self.isActiveRun(runID) {
                session.updateMessages(result.updatedMessages)
                session.uiState.setStreaming(false)
                session.uiState.resetStreamingText()
                agent.sessionDidCompleteRun(session, result: result)
            }

            continuation.yield(.completed(result))
            return
        }

        // Exceeded max iterations
        Logger.warning("LLMExecutor", "maxIterationsReached: limit=\(maxIterations)")
        finishWithError(AIAgentError.maxIterationsReached, messages: currentMessages)
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
            let toolTimeout = session.agentMask?.profile.toolTimeout ?? 60
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
            let mutationPolicy = session.agentMask?.profile.toolMutationPolicy ?? .allowed
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
            let budget = tool.outputMaxBytes ?? session.agentMask?.profile.toolOutputMaxBytes ?? 8192
            // 预算只管文本；图片走多模态通道，截断它只会得到一张坏图。
            let payload = Self.clampToolOutput(result.stringValue, maxBytes: budget, toolName: call.name)
            let attachments = result.images.map {
                AIAgentMessage.ImageAttachment(data: $0.data, mediaType: $0.mediaType)
            }
            let resultPreview = payload.prefix(500)
            Logger.info("LLMExecutor", "toolResult: name=\(call.name), id=\(call.id), duration=\(String(format: "%.2f", duration))s, images=\(attachments.count), result=\"\(resultPreview)\(payload.count > 500 ? "...(\(payload.count) chars)" : "")\"")
            let content = AIAgentMessage.Content.toolResult(AIAgentMessage.ToolCallResult(
                toolCallId: call.id,
                content: payload,
                images: attachments
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
    private func prepareMessagesForProvider(
        _ messages: [AIAgentMessage],
        session: AISession,
        isFirstIteration: Bool
    ) async -> [AIAgentMessage] {
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
            createdAt: lastMsg.createdAt
        )

        var result = messages
        result[lastIndex] = wrappedMsg

        let entryLabels = allEntries.map(\.label).joined(separator: ", ")
        Logger.debug("LLMExecutor", "messageContext injected: entries=[\(entryLabels)], wrappedLength=\(wrappedText.count)")

        return result
    }
}
