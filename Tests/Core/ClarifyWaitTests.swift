import XCTest
@testable import AppAgent

/// clarify 一直等用户回答，执行器的通用超时不能掐断它。
final class ClarifyWaitTests: XCTestCase {
    func testClarifyIsNotCutByToolTimeout() async {
        let tools = ToolCentral()
        await tools.register(ClarifyTool())
        let providers = ModelProviderCentral()
        await providers.register(name: "p", provider: ClarifyProvider())
        let profile = AIAgentProfile(toolTimeout: 0.1, autoPersist: false, registerBuiltInTools: false)
        let agent = AIAgent(
            id: "clarify-\(UUID().uuidString)", profile: profile,
            toolCentral: tools, providerCentral: providers,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Clarify")
        let registry = DecisionResponderCentral()
        let responder = SlowResponder()
        registry.register(responder)
        session.decisionResponders = registry

        for await _ in session.sendMessage("go") {
        }

        let results = session.messages.flatMap(\.content).compactMap { content -> AIAgentMessage.ToolCallResult? in
            if case .toolResult(let result) = content {
                return result
            }
            return nil
        }
        XCTAssertEqual(results.first?.content, "B", "回答晚于 toolTimeout 也必须送达模型")
        XCTAssertEqual(results.first?.isError, false)
    }

    func testClarificationCardEndsWithCustomInputAndOnlyQuestionsAreSkippable() {
        let clarify = DecisionRequest.clarification(question: "选哪个？", choices: ["A"])
        XCTAssertEqual(clarify.options.map(\.id), ["choice_0", DecisionOption.customAnswerID])
        XCTAssertTrue(clarify.isSkippable)

        let permission = DecisionRequest.permission(
            AppAgentPermission(id: "p", title: "修改 App 运行时", summary: ""), tool: "t", detail: nil
        )
        XCTAssertFalse(permission.options.contains { option in
            option.id == DecisionOption.customAnswerID
        })
        XCTAssertFalse(permission.isSkippable)
    }
}

private final class SlowResponder: DecisionResponder, @unchecked Sendable {
    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return .answer("B")
    }
}

private struct ClarifyProvider: ModelProvider {
    let name = "clarify-provider"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5

    func streamCompletion(
        messages: [AIAgentMessage], system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>], modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let shouldCall = messages.last?.isGenuineUserInput == true
        let call = ProviderStreamEvent.toolCall(.init(
            id: UUID().uuidString, name: "clarify",
            arguments: ["question": .string("选哪个？"), "choices": .array([.string("A"), .string("B")])]
        ))
        return AsyncThrowingStream {
            if shouldCall {
                $0.yield(call)
                $0.yield(.done(stopReason: .toolUse))
            } else {
                $0.yield(.textDelta("done"))
                $0.yield(.done(stopReason: .endTurn))
            }
            $0.finish()
        }
    }
}
