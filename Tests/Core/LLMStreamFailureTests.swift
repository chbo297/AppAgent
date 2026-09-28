import XCTest
@testable import AppAgent

final class LLMStreamFailureTests: XCTestCase {
    func testRetryOnlyPersistsFinalAttemptTextAndNeverUnexecutedCalls() async throws {
        for failures in [1, 2] {
            let provider = PartialFailureProvider(failures: failures)
            let central = ModelProviderCentral()
            await central.register(name: "p", provider: provider)
            let agent = makeAgent(central: central, policy: ModelPolicy(primary: "p/m"))
            let session = await agent.createSession(title: "流失败回归")
            let executor = LLMExecutor(
                session: session,
                retryPolicy: RetryPolicy(maxRetries: 1, baseDelay: 0, jitterFactor: 0)
            )
            var terminals = 0
            for await event in executor.run("测试") {
                switch event {
                case .completed, .error: terminals += 1
                default: break
                }
            }
            XCTAssertEqual(terminals, 1)
            XCTAssertEqual(provider.requests.count, 2)
            XCTAssertTrue(provider.requests.allSatisfy { request in
                !request.contains { $0.role == .assistant }
            }, "失败尝试的半截正文和未执行调用不能进入重试请求")
            let replies = session.messages.filter { $0.role == .assistant }
            XCTAssertEqual(replies.map(\.text), [failures == 1 ? "完整回答" : "半截回答 2"])
            XCTAssertTrue(replies.allSatisfy { $0.toolCalls.isEmpty })
            XCTAssertEqual(replies.first?.turnID, 1)
            let record = try XCTUnwrap(session.turnRecord(turnID: 1))
            XCTAssertTrue(record.isFinished)
            if failures == 1 {
                XCTAssertEqual(record.outcome, .answered)
            } else {
                XCTAssertEqual(record.failedStage, .streaming)
            }
        }
    }

    func testFallbackDoesNotPersistFailedProvidersPartialText() async throws {
        let central = ModelProviderCentral()
        let primary = PartialFailureProvider(failures: 1)
        let fallback = PartialFailureProvider(name: "fallback", failures: 0)
        await central.register(name: "p", provider: primary)
        await central.register(name: "q", provider: fallback)
        let agent = makeAgent(central: central, policy: ModelPolicy(primary: "p/m", fallbacks: ["q/m"]))
        let session = await agent.createSession(title: "流回退回归")
        let executor = LLMExecutor(session: session, retryPolicy: RetryPolicy(maxRetries: 0))
        for await _ in executor.run("测试") {}
        XCTAssertEqual(primary.requests.count, 1)
        // 候选先做一次真实可用性探测，再用同一模型重放原始请求。
        XCTAssertEqual(fallback.requests.count, 2)
        XCTAssertFalse(fallback.requests.flatMap { $0 }.contains { $0.role == .assistant })
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }.map(\.text), ["完整回答"])
        XCTAssertEqual(session.turnRecord(turnID: 1)?.outcome, .answered)
    }

    private func makeAgent(central: ModelProviderCentral, policy: ModelPolicy) -> AIAgent {
        AIAgent(
            id: "stream-failure-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            toolCentral: ToolCentral(),
            providerCentral: central,
            modelPolicy: policy,
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
    }
}

private final class PartialFailureProvider: ModelProvider, @unchecked Sendable {
    let name: String
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    let failures: Int
    @Locked private(set) var requests: [[AIAgentMessage]] = []

    init(name: String = "partial-failure", failures: Int) {
        self.name = name
        self.failures = failures
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let attempt = $requests.mutate { requests in
            requests.append(messages)
            return requests.count
        }
        return AsyncThrowingStream { continuation in
            if attempt <= failures {
                continuation.yield(.textDelta("半截回答 \(attempt)"))
                continuation.yield(.toolCall(.init(id: "unexecuted", name: "never_execute", arguments: [:])))
                continuation.finish(throwing: ModelError.httpError(statusCode: 503, body: "流中断"))
            } else {
                continuation.yield(.textDelta("完整回答"))
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
        }
    }
}
