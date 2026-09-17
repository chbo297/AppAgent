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
