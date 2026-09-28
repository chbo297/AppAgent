import Foundation

/// SDK 自身的本地诊断脚本。只替换 provider / tool，不直接写 turnRecord 或伪造 UI 状态。
/// 独立注册表、内存存储、无回退模型，不能接触宿主工具或真实端点。
final class AppAgentFailureDemo: Sendable {
    enum Scenario: String, CaseIterable, Sendable {
        case preparation, firstRequest, requestRetries, toolLoop
        case streamInterrupted, followupRequest, invalidToolCall, recoveredTool

        var message: String {
            switch self {
            case .preparation: return "A · 准备失败：尚未配置模型，请开始回答。"
            case .firstRequest: return "B · 首次请求失败：模拟鉴权失败，尚未收到任何输出。"
            case .requestRetries: return "C · 请求持续失败：首次请求及 3 次重试均返回 503。"
            case .toolLoop: return "D · 工具反复失败：首次模型请求成功，但重复调用失败工具，直至循环保护终止。"
            case .streamInterrupted: return "E · 输出中断：已经开始回答，随后流数据解析失败。"
            case .followupRequest: return "F · 后续请求失败：工具执行成功，带结果再次请求模型时持续失败。"
            case .invalidToolCall: return "G · 工具协议异常：模型声明调用工具，却未返回有效调用。"
            case .recoveredTool: return "H · 失败后完成：工具报错后模型正常回答，保留工具失败详情。"
            }
        }
    }

    let agent: AIAgent
    let session: AISession
    let provider: AppAgentFailureDemoProvider

    private init(agent: AIAgent, session: AISession, provider: AppAgentFailureDemoProvider) {
        self.agent = agent
        self.session = session
        self.provider = provider
    }

    static func make(stepDelay: UInt64 = 450_000_000) async -> AppAgentFailureDemo {
        let tools = ToolCentral()
        let providers = ModelProviderCentral()
        let provider = AppAgentFailureDemoProvider(stepDelay: stepDelay)
        await providers.register(name: provider.name, provider: provider)
        await tools.register(AppAgentFailureDemoTool(stepDelay: stepDelay))
        let agent = AIAgent(
            id: "failure-demo-\(UUID().uuidString)",
            profile: AIAgentProfile(promptBuilders: [], autoPersist: false, registerBuiltInTools: false),
            toolCentral: tools,
            providerCentral: providers,
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        await agent.ensureReady()
        // 第一轮特意不配置 provider，以真实的准备失败出口收尾。
        let session = await agent.sessionManager.createSession(title: "报错演示 · 仅本地")
        return AppAgentFailureDemo(agent: agent, session: session, provider: provider)
    }

    func prepare(_ scenario: Scenario) async {
        provider.select(scenario)
        if scenario != .preparation {
            await session.switchModel(reference: "\(provider.name)/scripted")
        }
    }
}

/// 每次发起请求都经过 executor；计数按场景重置，工具结果只读取当前 turn。
final class AppAgentFailureDemoProvider: ModelProvider, @unchecked Sendable {
    let name = "local-failure-demo"
    let baseURL = "local://failure-demo"
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "scripted")]
    let requestTimeout: TimeInterval = 10
    private let stepDelay: UInt64
    private struct State {
        var scenario: AppAgentFailureDemo.Scenario = .preparation
        var requests = 0
    }
    @Locked private var state = State()

    init(stepDelay: UInt64) { self.stepDelay = stepDelay }

    func select(_ scenario: AppAgentFailureDemo.Scenario) {
        $state.mutate { $0 = State(scenario: scenario) }
    }

    var requestCount: Int { state.requests }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let snapshot = $state.mutate { state -> State in
            state.requests += 1
            return state
        }
        let turnID = messages.last(where: \.isGenuineUserInput)?.turnID
        let hasToolResult = messages.contains { message in
            message.turnID == turnID && message.content.contains {
                if case .toolResult = $0 { return true }
                return false
            }
        }
        let delay = stepDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: delay)
                    switch snapshot.scenario {
                    case .preparation, .firstRequest:
                        throw ModelError.httpError(statusCode: 401, body: "【本地演示】首次请求鉴权失败，API Key 无效；未收到模型输出。")
                    case .requestRetries:
                        throw ModelError.httpError(
                            statusCode: 503,
                            body: "【本地演示】第 \(snapshot.requests) 次请求失败，服务暂不可用。首次请求与最多 3 次重试均失败。"
                        )
                    case .streamInterrupted:
                        continuation.yield(.reasoningDelta("正在生成回答，用于观察输出阶段中断。"))
                        try await Task.sleep(nanoseconds: delay)
                        continuation.yield(.textDelta("这是一段已经收到的模型输出，接下来模拟流数据损坏……"))
                        try await Task.sleep(nanoseconds: delay * 2)
                        throw ModelError.decodingError("【本地演示】输出过程中收到损坏的 SSE 数据，本轮无法继续。")
                    case .invalidToolCall:
                        continuation.yield(.reasoningDelta("准备调用工具，但将模拟缺失调用内容的协议错误。"))
                        try await Task.sleep(nanoseconds: delay)
                        continuation.yield(.done(stopReason: .toolUse))
                    case .toolLoop, .followupRequest, .recoveredTool:
                        if snapshot.scenario == .followupRequest && hasToolResult {
                            throw ModelError.httpError(
                                statusCode: 503,
                                body: "【本地演示】工具已成功，但后续第 \(snapshot.requests - 1) 次模型请求失败，无法生成最终回答。"
                            )
                        }
                        if snapshot.scenario == .recoveredTool && hasToolResult {
                            continuation.yield(.textDelta("工具调用失败了，本轮仍正常完成。可展开处理过程查看失败原因；阶段条应只在“工具”处保留一个警告。"))
                            continuation.yield(.done(stopReason: .endTurn))
                        } else {
                            continuation.yield(.reasoningDelta(
                                "第 \(snapshot.requests) 次模型响应成功，接下来执行本地模拟工具。"
                            ))
                            try await Task.sleep(nanoseconds: delay)
                            continuation.yield(.toolCall(.init(
                                id: UUID().uuidString,
                                name: "demo_operation",
                                arguments: ["fail": .bool(snapshot.scenario != .followupRequest)]
                            )))
                            continuation.yield(.done(stopReason: .toolUse))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private struct AppAgentFailureDemoTool: ToolProtocol {
    let stepDelay: UInt64
    let name = "demo_operation"
    let description = "本地报错演示工具，不访问网络、文件或宿主状态。"
    let parameters = Tool.Schema(properties: ["fail": .boolean(description: "是否模拟失败")])
    let safetyLevel: Tool.SafetyLevel = .safe

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        try await Task.sleep(nanoseconds: stepDelay)
        if arguments["fail"]?.boolValue == true {
            return .error("【本地演示】工具执行失败：模拟资源不可用。\n相同参数重复执行仍会失败，模型需要决定改用其他方式回答或继续尝试。")
        }
        return .text("【本地演示】工具执行成功，结果已返回模型。")
    }
}
