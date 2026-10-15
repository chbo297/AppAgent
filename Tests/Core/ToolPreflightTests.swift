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

    func testDisabledToolIsRejectedAtEachExecutionBoundary() async throws {
        for boundary in ["offer", "preflight", "authorization"] {
            let tool = PreflightProbeTool(rejection: nil, disableDuringPreflight: boundary == "preflight")
            let recorder = AskRecorder(onAsk: {
                if boundary == "authorization" {
                    tool.enabled = false
                }
            })
            let provider = SingleToolCallProvider(toolName: tool.name, onFirstRequest: {
                if boundary == "offer" {
                    tool.enabled = false
                }
            })
            let (session, agent) = try await makeSession(tool: tool, recorder: recorder, provider: provider)
            let executor = LLMExecutor(session: session)
            defer {
                _ = agent
                _ = executor
            }
            var failures = 0
            for await event in executor.run("禁用已提供的工具") {
                if case .toolCallFailed(let id, let name, let error) = event {
                    XCTAssertEqual(id, "call-1")
                    XCTAssertEqual(name, tool.name)
                    XCTAssertTrue(error.localizedDescription.contains("disabled"))
                    failures += 1
                }
            }
            XCTAssertTrue(provider.offeredNames.contains(tool.name), boundary)
            XCTAssertEqual(tool.preflightCount, boundary == "offer" ? 0 : 1, boundary)
            XCTAssertEqual(recorder.asked, boundary == "authorization" ? 1 : 0, boundary)
            XCTAssertEqual(tool.executeCount, 0, boundary)
            XCTAssertEqual(failures, 1, boundary)
            let results = toolResults(in: session.messages)
            XCTAssertEqual(results.count, 1, boundary)
            XCTAssertEqual(results.first?.isError, true, boundary)
            XCTAssertTrue(results.first?.content.contains("disabled") == true, boundary)
        }
    }

    func testToolErrorsReachHistoryAndNextRequestWithoutFailingTheTurn() async throws {
        for throwsError in [false, true] {
            let tool = PreflightProbeTool(rejection: nil, throwsError: throwsError, output: .error("probe failed"))
            let provider = SingleToolCallProvider(toolName: tool.name)
            let recorder = AskRecorder()
            let (session, agent) = try await makeSession(tool: tool, recorder: recorder, provider: provider)
            let executor = LLMExecutor(session: session)
            defer {
                _ = agent
                _ = executor
                _ = recorder
            }
            var returnedErrors = 0
            var thrownErrors = 0
            var completedTurns = 0
            var failedTurns = 0
            for await event in executor.run("工具失败后继续回答") {
                switch event {
                case .toolCallCompleted(let id, let output):
                    XCTAssertEqual(id, "call-1")
                    guard case .error(let message) = output else {
                        XCTFail("必须保留结构化错误结果")
                        continue
                    }
                    XCTAssertEqual(message, "probe failed")
                    returnedErrors += 1
                case .toolCallFailed(let id, let name, let error):
                    XCTAssertEqual(id, "call-1")
                    XCTAssertEqual(name, tool.name)
                    XCTAssertEqual(error.localizedDescription, "probe failed")
                    thrownErrors += 1
                case .completed:
                    completedTurns += 1
                case .error:
                    failedTurns += 1
                default:
                    break
                }
            }
            XCTAssertEqual(tool.executeCount, 1)
            XCTAssertEqual(returnedErrors, throwsError ? 0 : 1)
            XCTAssertEqual(thrownErrors, throwsError ? 1 : 0)
            XCTAssertEqual(completedTurns, 1)
            XCTAssertEqual(failedTurns, 0)
            XCTAssertEqual(session.turnRecords.count, 1)
            XCTAssertEqual(session.turnRecords.values.first?.outcome, .answered)
            for results in [toolResults(in: session.messages), provider.receivedToolResults] {
                XCTAssertEqual(results.count, 1)
                XCTAssertEqual(results.first?.toolCallId, "call-1")
                XCTAssertEqual(results.first?.isError, true)
                XCTAssertEqual(results.first?.content, "Error: probe failed")
            }
        }
    }

    /// `AISession` 只弱引用 agent，所以 agent 必须由调用方持住 —— 否则整轮直接
    /// 以 "No agent attached" 结束，测不到任何工具路径。
    private func makeSession(
        tool: PreflightProbeTool, recorder: AskRecorder, provider: SingleToolCallProvider? = nil
    ) async throws -> (session: AISession, agent: AIAgent) {
        let central = ModelProviderCentral()
        await central.register(name: "p", provider: provider ?? SingleToolCallProvider(toolName: tool.name))
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
    private let onAsk: (@Sendable () -> Void)?

    init(onAsk: (@Sendable () -> Void)? = nil) {
        self.onAsk = onAsk
    }

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        $asked.mutate { $0 += 1 }
        onAsk?()
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
    private let disableDuringPreflight: Bool
    private let throwsError: Bool
    private let output: Tool.Output
    @Locked var enabled = true
    @Locked private(set) var preflightCount = 0
    @Locked private(set) var executeCount = 0

    init(rejection: String?, disableDuringPreflight: Bool = false,
         throwsError: Bool = false, output: Tool.Output = .text("executed")) {
        self.rejection = rejection
        self.disableDuringPreflight = disableDuringPreflight
        self.throwsError = throwsError
        self.output = output
    }

    func preflightRejection(for arguments: [String: JSONValue], session: AISession) async -> String? {
        $preflightCount.mutate {
            $0 += 1
        }
        if disableDuringPreflight {
            enabled = false
        }
        return rejection
    }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        $executeCount.mutate {
            $0 += 1
        }
        if throwsError {
            throw ProbeError()
        }
        return output
    }
}

private struct ProbeError: LocalizedError {
    var errorDescription: String? {
        "probe failed"
    }
}

private func toolResults(in messages: [AIAgentMessage]) -> [AIAgentMessage.ToolCallResult] {
    messages.flatMap(\.content).compactMap { content in
        if case .toolResult(let result) = content {
            return result
        }
        return nil
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
    private let onFirstRequest: (@Sendable () -> Void)?
    @Locked private var rounds = 0
    @Locked private(set) var offeredNames: [String] = []
    @Locked private(set) var receivedToolResults: [AIAgentMessage.ToolCallResult] = []

    init(toolName: String, onFirstRequest: (@Sendable () -> Void)? = nil) {
        self.toolName = toolName
        self.onFirstRequest = onFirstRequest
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
        if round == 1 {
            offeredNames = tools.compactMap { entry in
                if case .content(let tool) = entry {
                    return tool.name
                }
                return nil
            }
            onFirstRequest?()
        } else {
            receivedToolResults = toolResults(in: messages)
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
