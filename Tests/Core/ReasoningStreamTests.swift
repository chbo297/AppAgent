import XCTest
@testable import AppAgent

/// 「思考过程」链路：两种协议的 SSE 解析 → ProviderStreamEvent.reasoningDelta →
/// LLMExecutor 转成 AIAgentEvent.reasoningContent 并累计到 uiState。
final class ReasoningStreamTests: XCTestCase {

    func testOpenAIReasoningContentBecomesReasoningDelta() {
        var active: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
        let event = SSEEvent(
            event: "",
            data: #"{"choices":[{"delta":{"reasoning_content":"先看设置页"},"finish_reason":null}]}"#
        )
        let events = OpenAIChatCompletionsMapper.parseSSEEvent(event, activeToolCalls: &active)
        guard case .reasoningDelta(let text)? = events.first else {
            return XCTFail("expected reasoningDelta, got \(events)")
        }
        XCTAssertEqual(text, "先看设置页")
    }

    /// 部分网关用 `reasoning` 而不是 `reasoning_content`。
    func testOpenAIReasoningAliasIsAccepted() {
        var active: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
        let event = SSEEvent(event: "", data: #"{"choices":[{"delta":{"reasoning":"思路 A"}}]}"#)
        let events = OpenAIChatCompletionsMapper.parseSSEEvent(event, activeToolCalls: &active)
        guard case .reasoningDelta(let text)? = events.first else {
            return XCTFail("expected reasoningDelta, got \(events)")
        }
        XCTAssertEqual(text, "思路 A")
    }

    /// 正文与思考互不串台。
    func testOpenAIContentStaysTextDelta() {
        var active: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
        let event = SSEEvent(event: "", data: #"{"choices":[{"delta":{"content":"最终答案"}}]}"#)
        let events = OpenAIChatCompletionsMapper.parseSSEEvent(event, activeToolCalls: &active)
        guard case .textDelta(let text)? = events.first else {
            return XCTFail("expected textDelta, got \(events)")
        }
        XCTAssertEqual(text, "最终答案")
    }

    func testAnthropicThinkingDeltaBecomesReasoningDelta() {
        var active: [Int: (id: String, name: String, jsonAccumulator: String)] = [:]
        let event = SSEEvent(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"我在推理"}}"#
        )
        let events = AnthropicMapper.parseSSEEvent(event, activeToolCalls: &active)
        guard case .reasoningDelta(let text)? = events.first else {
            return XCTFail("expected reasoningDelta, got \(events)")
        }
        XCTAssertEqual(text, "我在推理")
    }

    /// 执行循环把 reasoningDelta 转成事件 + uiState.reasoningText，且不写进消息历史。
    func testExecutorForwardsReasoningToEventsAndUIState() async throws {
        let central = ModelProviderCentral()
        await central.register(name: "p", provider: ReasoningProvider(modelId: "m"))
        let agent = AIAgent(
            id: "reasoning-exec",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "t")

        var reasoning = ""
        var answer = ""
        for await event in session.sendMessage("hi") {
            switch event {
            case .reasoningContent(let delta): reasoning += delta
            case .streamingContent(let delta): answer += delta
            default: break
            }
        }

        XCTAssertEqual(reasoning, "第一步…第二步…")
        XCTAssertEqual(answer, "答案")
        XCTAssertEqual(session.uiState.reasoningText, "第一步…第二步…")
        // 思考不进历史：最后一条 assistant 消息只有正文。
        XCTAssertEqual(session.messages.last?.text, "答案")
        XCTAssertFalse(session.messages.contains { $0.text.contains("第一步") })
    }
}

/// 先吐两段思考、再吐正文的桩 provider。
private final class ReasoningProvider: ModelProvider, @unchecked Sendable {
    let name = "reasoning"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .openaiCompletions
    let customHeaders: [String: String] = [:]
    let models: [ModelSpec]
    let requestTimeout: TimeInterval = 5

    init(modelId: String) {
        self.models = [ModelSpec(id: modelId)]
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoningDelta("第一步…"))
            continuation.yield(.reasoningDelta("第二步…"))
            continuation.yield(.textDelta("答案"))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}
