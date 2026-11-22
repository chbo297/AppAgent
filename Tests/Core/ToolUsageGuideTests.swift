import XCTest
@testable import AppAgent

/// 工具使用手册（`usageGuide`）的下发规则：同一会话第一次调用时附在结果后面，成败都附；
/// 之后不再重复；上下文压缩清空登记后再附一次。手册本身不进工具定义，所以每轮请求都不带它。
final class ToolUsageGuideTests: XCTestCase {

    /// 反射参数改成 typed 数组后，旧的 JSON 字符串写法和数字 / 布尔形式的 value 仍要能用。
    func testRuntimeInspectAcceptsTypedArgumentsAndLegacyForms() throws {
        let typed = RuntimeInspectTool.invocationArgumentsJSON(["arguments": .array([.string("Hi"), .number(2)])])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(typed.utf8)) as? [Any])
        XCTAssertEqual(decoded.first as? String, "Hi")
        XCTAssertEqual((decoded.last as? NSNumber)?.intValue, 2)
        XCTAssertEqual(RuntimeInspectTool.invocationArgumentsJSON(["argumentsJSON": .string("[1]")]), "[1]")
        XCTAssertEqual(RuntimeInspectTool.invocationArgumentsJSON(["arguments": .string("[1]")]), "[1]")
        XCTAssertEqual(RuntimeInspectTool.invocationArgumentsJSON([:]), "[]")

        XCTAssertEqual(RuntimeInspectTool.scalarText(.number(0.5)), "0.5")
        XCTAssertEqual(RuntimeInspectTool.scalarText(.number(3)), "3")
        XCTAssertEqual(RuntimeInspectTool.scalarText(.bool(true)), "true")
        XCTAssertNil(RuntimeInspectTool.scalarText(.array([])))
    }

    func testGuideIsAttachedOnceEvenWhenTheFirstCallFails() async throws {
        let tool = GuideProbeTool(failFirst: true)
        let provider = TwoCallProvider(toolName: tool.name)
        let (session, agent) = try await makeSession(tool: tool, provider: provider)
        let executor = LLMExecutor(session: session)
        defer {
            _ = agent
            _ = executor
        }
        for await _ in executor.run("调用两次") {}

        let results = toolResults(in: session.messages)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].isError, true, "第一次调错仍是错误结果")
        XCTAssertTrue(results[0].content.contains(GuideProbeTool.guide), "调错的那次最需要手册")
        XCTAssertFalse(results[1].content.contains(GuideProbeTool.guide), "第二次不再重复")
        XCTAssertFalse(provider.offeredDescriptions.contains { description in
            description.contains(GuideProbeTool.guide)
        }, "手册不能进工具定义")

        // 压缩会截掉旧结果里的手册；执行器在压缩时清空登记，下次调用重新附上。
        session.deliveredToolGuides = []
        XCTAssertTrue(session.claimToolGuide(tool.name))
        XCTAssertFalse(session.claimToolGuide(tool.name))
    }

    private func makeSession(tool: GuideProbeTool, provider: TwoCallProvider) async throws -> (AISession, AIAgent) {
        let central = ModelProviderCentral()
        await central.register(name: "p", provider: provider)
        let tools = ToolCentral()
        await tools.register(tool)
        let agent = AIAgent(
            id: "guide-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            toolCentral: tools,
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "手册下发")
        return (session, agent)
    }
}

private final class GuideProbeTool: ToolProtocol, @unchecked Sendable {
    static let guide = "GUIDE: pass shapes as an array"
    let name = "guide_probe"
    let description = "自检用：验证使用手册只在第一次调用时下发"
    let parameters = Tool.Schema(properties: [:], required: [])
    let usageGuide: String? = GuideProbeTool.guide
    private let failFirst: Bool
    @Locked private var calls = 0

    init(failFirst: Bool) {
        self.failFirst = failFirst
    }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let call = $calls.mutate { calls -> Int in
            calls += 1
            return calls
        }
        return failFirst && call == 1 ? .error("shapes must be an array") : .text("ok")
    }
}

/// 前两轮各吐一个工具调用，第三轮收尾。
private final class TwoCallProvider: ModelProvider, @unchecked Sendable {
    let name = "guide-provider"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    private let toolName: String
    @Locked private var rounds = 0
    @Locked private(set) var offeredDescriptions: [String] = []

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
        let descriptions = tools.compactMap { entry -> String? in
            if case .content(let tool) = entry {
                return tool.description
            }
            return nil
        }
        $offeredDescriptions.mutate { offered in
            offered += descriptions
        }
        let toolName = toolName
        return AsyncThrowingStream { continuation in
            if round <= 2 {
                continuation.yield(.toolCall(.init(id: "call-\(round)", name: toolName, arguments: [:])))
                continuation.yield(.done(stopReason: .toolUse))
            } else {
                continuation.yield(.textDelta("收尾"))
                continuation.yield(.done(stopReason: .endTurn))
            }
            continuation.finish()
        }
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
