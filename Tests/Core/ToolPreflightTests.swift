import XCTest
@testable import AppAgent

/// 授权前置校验的接线回归。
///
/// 真机上一次 `view_invoke` 因为选择器不在受限作用域白名单里必然被拒，却先占掉用户
/// 4.9 秒去点「允许」，点完才报错。修法是给 `ToolProtocol` 加 `preflightRejection`，
/// 由 `LLMExecutor` 在弹授权卡**之前**问一次。
///
/// 这里锁的就是那个顺序：预检拒绝时，决策响应器一次都不该被问到，`execute` 也不该被调用。
final class ToolPreflightTests: XCTestCase {

    func testPreflightRejectionSkipsAuthorizationAndExecution() async throws {
        let tool = PreflightProbeTool(rejection: "(selector delegate requires all scope)")
        let recorder = AskRecorder()
        let (session, agent) = try await makeSession(tool: tool, recorder: recorder)
        defer { _ = agent }   // 持住 agent：session 对它只有弱引用

        let executor = LLMExecutor(session: session)
        for await _ in executor.run("触发一次注定失败的敏感调用") {}

        XCTAssertEqual(recorder.asked, 0, "预检已经判定必失败，不该再问用户")
        XCTAssertEqual(tool.executeCount, 0, "预检拒绝后不该再执行")
        let result = session.messages
            .flatMap(\.content)
            .compactMap { content -> AIAgentMessage.ToolCallResult? in
                if case .toolResult(let r) = content { return r }
                return nil
            }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.isError, true)
        XCTAssertTrue(result.first?.content.contains("requires all scope") == true,
                      "模型要看到真正的原因，而不是「用户拒绝」")
    }

    /// 反向保险：预检放行时，敏感工具必须照旧走授权并执行。
    /// 少了这条，一个「永远返回拒绝」的实现也能让上面那条通过。
    func testPreflightPassStillAsksAndExecutes() async throws {
        let tool = PreflightProbeTool(rejection: nil)
        let recorder = AskRecorder()
        let (session, agent) = try await makeSession(tool: tool, recorder: recorder)
        defer { _ = agent }   // 持住 agent：session 对它只有弱引用

        let executor = LLMExecutor(session: session)
        var seen: [String] = []
        for await event in executor.run("触发一次可以执行的敏感调用") {
            seen.append("\(event)")
        }
        XCTAssertEqual(recorder.asked, 1, "预检放行的敏感工具仍要问用户 · events=\(seen)")
        XCTAssertEqual(tool.executeCount, 1, "events=\(seen)")
    }

    /// `AISession` 只弱引用 agent，所以 agent 必须由调用方持住 —— 否则整轮直接
    /// 以 "No agent attached" 结束，测不到任何工具路径。
    private func makeSession(
        tool: PreflightProbeTool, recorder: AskRecorder
    ) async throws -> (session: AISession, agent: AIAgent) {
        let central = ModelProviderCentral()
        await central.register(name: "p", provider: SingleToolCallProvider(toolName: tool.name))
        let tools = ToolCentral()
        await tools.register(tool)
        let agent = AIAgent(
            id: "preflight-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            toolCentral: tools,
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "预检接线")
        let registry = DecisionResponderCentral()
        registry.register(recorder)
        session.decisionResponders = registry
        return (session, agent)
    }
}

/// 记录「有没有被问过」，并一律放行 —— 放行才能让「该问的时候真的问了」被观测到。
private final class AskRecorder: DecisionResponder, @unchecked Sendable {
    @Locked private(set) var asked = 0

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        $asked.mutate { $0 += 1 }
        return .allowOnce
    }
}

/// 敏感工具：`rejection` 非 nil 时预检必拒，否则放行并记录执行次数。
private final class PreflightProbeTool: ToolProtocol, @unchecked Sendable {
    let name = "preflight_probe"
    let description = "自检用：验证预检与授权的先后顺序"
    let parameters = Tool.Schema(properties: [:], required: [])
    let safetyLevel: Tool.SafetyLevel = .sensitive
    private let rejection: String?
    @Locked private(set) var executeCount = 0

    init(rejection: String?) {
        self.rejection = rejection
    }

    func preflightRejection(for arguments: [String: JSONValue], session: AISession) async -> String? {
        rejection
    }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        $executeCount.mutate { $0 += 1 }
        return .text("executed")
    }
}

/// 第一轮吐一个工具调用，第二轮直接收尾，保证 executor 只走一次工具路径。
private final class SingleToolCallProvider: ModelProvider, @unchecked Sendable {
    let name = "preflight-provider"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    private let toolName: String
    @Locked private var rounds = 0

    init(toolName: String) {
        self.toolName = toolName
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let round = $rounds.mutate { rounds -> Int in
            rounds += 1
            return rounds
        }
        let toolName = toolName
        return AsyncThrowingStream { continuation in
            if round == 1 {
                continuation.yield(.toolCall(.init(id: "call-1", name: toolName, arguments: [:])))
                continuation.yield(.done(stopReason: .toolUse))
            } else {
                continuation.yield(.textDelta("收尾"))
                continuation.yield(.done(stopReason: .endTurn))
            }
            continuation.finish()
        }
    }
}
