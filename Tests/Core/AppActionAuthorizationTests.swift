import XCTest
@testable import AppAgent

/// 用真实工具走 executor：常规动作免确认，但不能绕过只读边界。
final class AppActionAuthorizationTests: XCTestCase {
    func testDefaultPolicyExecutesAppActionWithoutAuthorization() async throws {
        let provider = ActionRecorder()
        let responder = AuthorizationRecorder()
        let (session, agent) = await makeSession(provider: provider, responder: responder)
        defer {
            _ = agent
        }

        let results = await run(session)
        let calls = await provider.calls
        let authorizationCount = await responder.asked
        XCTAssertEqual(authorizationCount, 0, "常规 app_action 不应申请 toolAuthorization")
        XCTAssertEqual(calls.count, 1, "必须真正调用宿主 provider，不能只跳过授权")
        XCTAssertEqual(calls.first?.action, "toggle_favorite")
        XCTAssertEqual(calls.first?.parameters, ["item_id": .string("item-1")])
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.toolCallId, "action-1")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "favorite toggled")
    }

    func testReadOnlyRejectsAppActionWithoutAuthorizationOrExecution() async throws {
        let provider = ActionRecorder()
        let responder = AuthorizationRecorder()
        let (session, agent) = await makeSession(provider: provider, responder: responder, readOnly: true)
        defer {
            _ = agent
        }

        let results = await run(session)
        let calls = await provider.calls
        let authorizationCount = await responder.asked
        XCTAssertEqual(authorizationCount, 0, "只读拒绝应直接返回，不能通过询问用户提权")
        XCTAssertTrue(calls.isEmpty, "只读模式不能执行宿主动作")
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.toolCallId, "action-1")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("read-only"), "应返回只读拦截原因，而非授权拒绝或工具缺失")
    }

    private func makeSession(
        provider: ActionRecorder, responder: AuthorizationRecorder, readOnly: Bool = false
    ) async -> (session: AISession, agent: AIAgent) {
        let tools = ToolCentral()
        await tools.register(AppActionTool(provider: provider))
        let models = ModelProviderCentral()
        await models.register(name: "p", provider: ActionCallModel())
        var profile = AIAgentProfile(autoPersist: false, registerBuiltInTools: false)
        if readOnly {
            profile.toolMutationPolicy = .readOnly
        }
        let agent = AIAgent(
            id: "action-authorization-\(UUID().uuidString)",
            profile: profile,
            toolCentral: tools,
            providerCentral: models,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "动作授权回归")
        let registry = DecisionResponderCentral()
        registry.register(responder)
        session.decisionResponders = registry
        return (session, agent)
    }

    private func run(_ session: AISession) async -> [AIAgentMessage.ToolCallResult] {
        let executor = LLMExecutor(session: session)
        var completed = 0
        for await event in executor.run("切换 item-1 的收藏状态") {
            switch event {
            case .completed:
                completed += 1
            case .error(let error):
                XCTFail("执行链应正常收尾：\(error)")
            default:
                break
            }
        }
        XCTAssertEqual(completed, 1)
        return session.messages.flatMap(\.content).compactMap { content in
            if case .toolResult(let result) = content {
                return result
            }
            return nil
        }
    }
}

private actor ActionRecorder: AppActionProvider {
    struct Call: Sendable {
        let action: String
        let parameters: [String: JSONValue]
    }

    private(set) var calls: [Call] = []

    func availableActions() async -> [AppAction] {
        [AppAction(name: "toggle_favorite", description: "切换收藏状态")]
    }

    func execute(action: String, parameters: [String: JSONValue]) async throws -> Tool.Output {
        calls.append(Call(action: action, parameters: parameters))
        return .text("favorite toggled")
    }
}

/// 即使回归成需要授权，也立即响应，避免测试悬挂；由请求计数明确报错。
private actor AuthorizationRecorder: DecisionResponder {
    private(set) var asked = 0

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        if case .toolAuthorization = request {
            asked += 1
        }
        return .allowOnce
    }
}

/// 首次请求调用 app_action，收到工具结果后收尾；无真实网络请求。
private struct ActionCallModel: ModelProvider {
    let name = "action-call-model"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let shouldCall = messages.last?.isGenuineUserInput == true
        return AsyncThrowingStream { continuation in
            if shouldCall {
                continuation.yield(.toolCall(.init(
                    id: "action-1",
                    name: "app_action",
                    arguments: [
                        "action": .string("toggle_favorite"),
                        "parameters": .object(["item_id": .string("item-1")])
                    ]
                )))
                continuation.yield(.done(stopReason: .toolUse))
            } else {
                continuation.yield(.textDelta("收尾"))
                continuation.yield(.done(stopReason: .endTurn))
            }
            continuation.finish()
        }
    }
}
