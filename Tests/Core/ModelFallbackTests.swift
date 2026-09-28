import XCTest
@testable import AppAgent

/// 运行期模型回退 + 调试记录器的行为测试。
/// 用桩 provider 制造「主模型 404 不可用」，验证执行循环会自动切到 policy 里的下一个模型，
/// 并在调试记录里留下 failure / fallback / success 轨迹。
final class ModelFallbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppAgentDebugLog.shared.clear()
    }

    /// 主模型不可用（404）时自动切到 fallback 模型，用户仍能拿到回复。
    func testFallsBackToNextModelWhenPrimaryUnavailable() async throws {
        let central = ModelProviderCentral()
        await central.register(name: "pa", provider: AlwaysFailingProvider(modelId: "A", statusCode: 404))
        await central.register(name: "pb", provider: FixedReplyProvider(modelId: "B", reply: "hello from B"))

        let agent = AIAgent(
            id: "fallback-test",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "pa/A", fallbacks: ["pb/B"]),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "t")
        XCTAssertEqual(session.modelId, "A")

        var streamed = ""
        for await event in session.sendMessage("hi") {
            if case .streamingContent(let delta) = event { streamed += delta }
        }

        XCTAssertEqual(streamed, "hello from B")
        XCTAssertEqual(session.messages.last?.text, "hello from B")
        XCTAssertEqual(session.modelId, "B")
        XCTAssertEqual(session.uiState.get(SessionUIState.activeModelKey), "pb/B")

        let events = AppAgentDebugLog.shared.snapshot()
        XCTAssertTrue(events.contains { $0.kind == .failure && $0.reason == "model_not_found" })
        XCTAssertTrue(events.contains { $0.kind == .fallback && $0.modelId == "B" })
        XCTAssertTrue(events.contains { $0.kind == .success && $0.modelId == "B" })
    }

    /// 没有可用的候选模型时不再无限回退，向上抛错。
    func testSurfacesErrorWhenNoFallbackAvailable() async throws {
        let central = ModelProviderCentral()
        await central.register(name: "pa", provider: AlwaysFailingProvider(modelId: "A", statusCode: 404))

        let agent = AIAgent(
            id: "fallback-none",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "pa/A"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "t")

        var failed = false
        for await event in session.sendMessage("hi") {
            if case .error = event { failed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(AppAgentDebugLog.shared.snapshot().contains { $0.kind == .fallback })
    }

    /// 注册但真实请求失败的候选必须跳过，继续按用户顺序探测下一个模型。
    func testSkipsRegisteredButUnavailableFallback() async throws {
        let central = ModelProviderCentral()
        await central.register(name: "pa", provider: AlwaysFailingProvider(modelId: "A", statusCode: 404))
        await central.register(name: "pb", provider: AlwaysFailingProvider(modelId: "B", statusCode: 404))
        await central.register(name: "pc", provider: FixedReplyProvider(modelId: "C", reply: "hello from C"))

        let agent = AIAgent(
            id: "fallback-probe",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "pa/A", fallbacks: ["pb/B", "pc/C"]),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "t")

        var streamed = ""
        for await event in session.sendMessage("hi") {
            if case .streamingContent(let delta) = event {
                streamed += delta
            }
        }

        XCTAssertEqual(streamed, "hello from C")
        XCTAssertEqual(session.modelId, "C")
        XCTAssertEqual(session.uiState.get(SessionUIState.activeModelKey), "pc/C")
        let failures = AppAgentDebugLog.shared.snapshot().filter { event in
            event.kind == .failure && event.reason == "fallback_probe_model_not_found"
        }
        XCTAssertEqual(failures.count, 1)
    }

    /// 会话可以按模型引用切换模型（下一轮生效）。
    func testSwitchModelRepointsSession() async throws {
        let central = ModelProviderCentral()
        await central.register(name: "pa", provider: FixedReplyProvider(modelId: "A", reply: "a"))
        await central.register(name: "pb", provider: FixedReplyProvider(modelId: "B", reply: "b"))

        let agent = AIAgent(
            id: "switch-model",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "pa/A"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "t")
        XCTAssertEqual(session.modelId, "A")

        let ok = await session.switchModel(reference: "pb/B")
        XCTAssertTrue(ok)
        XCTAssertEqual(session.modelId, "B")
        XCTAssertEqual(session.uiState.get(SessionUIState.activeModelKey), "pb/B")

        let bad = await session.switchModel(reference: "nope/none")
        XCTAssertFalse(bad)
        XCTAssertEqual(session.modelId, "B")
    }

    /// 默认是三次重试（共四次请求）；网络错误与 loop 预算耗尽必须区分。
    func testRetryExhaustionAndIterationExhaustionReportDifferentErrors() async throws {
        let retryExhaustionLimit = RetryPolicy().maxRetries + 1
        let limitedBudget = 2
        XCTAssertEqual(AIAgentProfile().maxIterations, AIAgentExecutionPolicy.defaultMaxIterations)

        for loopLimit in [retryExhaustionLimit, limitedBudget] {
            let central = ModelProviderCentral()
            await central.register(name: "pa", provider: AlwaysFailingProvider(modelId: "A", statusCode: 503))
            let agent = AIAgent(
                id: "retry-limit-\(loopLimit)",
                profile: AIAgentProfile(maxIterations: loopLimit, autoPersist: false, registerBuiltInTools: false),
                providerCentral: central,
                modelPolicy: ModelPolicy(primary: "pa/A"),
                memoryStorage: InMemoryMemoryStorage(),
                sessionStorage: InMemorySessionStorage()
            )
            let session = await agent.createSession(title: "Retry limits")
            // 保留真实默认重试次数，只关闭退避等待；不出网。
            let executor = LLMExecutor(session: session, retryPolicy: RetryPolicy(baseDelay: 0, jitterFactor: 0))
            var iterations: [Int] = []
            var errors: [Error] = []
            var completions = 0
            for await event in executor.run("hi") {
                switch event {
                case .started(let turn): iterations.append(turn)
                case .error(let error): errors.append(error)
                case .completed: completions += 1
                default: break
                }
            }
            XCTAssertEqual(iterations, Array(1...loopLimit))
            XCTAssertEqual(errors.count, 1)
            XCTAssertEqual(completions, 0)
            let error = try XCTUnwrap(errors.first)
            if loopLimit == retryExhaustionLimit {
                guard case .httpError(let statusCode, _) = error as? ModelError else {
                    return XCTFail("重试耗尽且无备用模型时应保留原始 HTTP 错误")
                }
                XCTAssertEqual(statusCode, 503)
                XCTAssertEqual(error.localizedDescription, "HTTP 503: no such model")
            } else {
                guard case .maxIterationsReached(let limit) = error as? AIAgentError else {
                    return XCTFail("重试也消耗 loop 预算，应返回带本轮 limit 的错误")
                }
                XCTAssertEqual(limit, loopLimit)
                XCTAssertEqual(
                    error.localizedDescription,
                    AIAgentError.maxIterationsReached(limit: loopLimit).localizedDescription
                )
            }
            XCTAssertEqual(session.uiState.lastError?.localizedDescription, error.localizedDescription)
            XCTAssertEqual(session.turnRecord(turnID: session.currentTurnID)?.failureMessage, error.localizedDescription)
            XCTAssertEqual(session.turnRecord(turnID: session.currentTurnID)?.roundCount, iterations.count)
        }
    }

    /// 真实探测会跳过失效候选，找到的候选仍受主执行循环的 iteration 预算约束。
    func testModelFallbackSkipsUnavailableCandidateWithinIterationBudget() async throws {
        let central = ModelProviderCentral()
        await central.register(name: "pa", provider: AlwaysFailingProvider(modelId: "A", statusCode: 404))
        await central.register(name: "pb", provider: AlwaysFailingProvider(modelId: "B", statusCode: 404))
        await central.register(name: "pc", provider: FixedReplyProvider(modelId: "C", reply: "unreachable"))
        let agent = AIAgent(
            id: "fallback-loop-limit",
            profile: AIAgentProfile(maxIterations: 2, autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "pa/A", fallbacks: ["pb/B", "pc/C"]),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Fallback budget")
        var iterations: [Int] = []
        var errors: [Error] = []
        for await event in session.sendMessage("hi") {
            switch event {
            case .started(let turn): iterations.append(turn)
            case .error(let error): errors.append(error)
            case .streamingContent, .completed:
                break
            default: break
            }
        }
        XCTAssertEqual(iterations, [1, 2])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(session.modelId, "C")
        XCTAssertEqual(session.messages.last?.text, "unreachable")
    }
}

// MARK: - 桩 provider

/// 永远以指定 HTTP 状态码失败。
private final class AlwaysFailingProvider: ModelProvider, @unchecked Sendable {
    let name = "failing"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .openaiCompletions
    let customHeaders: [String: String] = [:]
    let models: [ModelSpec]
    let requestTimeout: TimeInterval = 5
    private let statusCode: Int

    init(modelId: String, statusCode: Int) {
        self.models = [ModelSpec(id: modelId)]
        self.statusCode = statusCode
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ModelError.httpError(statusCode: statusCode, body: "no such model"))
        }
    }
}

/// 固定返回一段文本后结束。
private final class FixedReplyProvider: ModelProvider, @unchecked Sendable {
    let name = "fixed"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models: [ModelSpec]
    let requestTimeout: TimeInterval = 5
    private let reply: String

    init(modelId: String, reply: String) {
        self.models = [ModelSpec(id: modelId)]
        self.reply = reply
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let text = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}
