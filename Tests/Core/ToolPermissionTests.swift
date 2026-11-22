import XCTest
@testable import AppAgent

/// 权限卡：未授权时弹卡、本会话允许后不再问、始终允许写入设备级记录、拒绝不执行、委派任务不能申请新权限。
final class ToolPermissionTests: XCTestCase {
    func testAllowOnceAsksEveryCall() async {
        let harness = await Harness(answer: .allowOnce)
        await harness.run("first")
        await harness.run("second")
        XCTAssertEqual(harness.tool.executions, 2)
        XCTAssertEqual(harness.responder.permissionRequests, 2)
        XCTAssertEqual(harness.responder.otherRequests, 0, "权限卡覆盖调用后不再弹安全级别卡")
        XCTAssertEqual(harness.session.permissionGrant(for: Harness.permission), .ask)
    }

    func testAllowForSessionIsRememberedAndPersisted() async {
        let harness = await Harness(answer: .allowForSession)
        await harness.run("first")
        await harness.run("second")
        XCTAssertEqual(harness.tool.executions, 2)
        XCTAssertEqual(harness.responder.permissionRequests, 1)
        XCTAssertEqual(harness.session.permissionGrant(for: Harness.permission), .session)
        XCTAssertEqual(harness.session.toSnapshot().permissionGrants, [Harness.permission.id])
        XCTAssertFalse(harness.store.isAlwaysAllowed(Harness.permission.id))

        // 另一个会话不继承本会话授权。
        let other = await harness.agent.createSession(title: "Other")
        XCTAssertEqual(other.permissionGrant(for: Harness.permission), .ask)
    }

    func testAllowAlwaysAppliesToEveryConversationOnDevice() async {
        let harness = await Harness(answer: .allowAlways)
        await harness.run("first")
        XCTAssertTrue(harness.store.isAlwaysAllowed(Harness.permission.id))
        let other = await harness.agent.createSession(title: "Other")
        XCTAssertEqual(other.permissionGrant(for: Harness.permission), .always)

        // 设置页选「每次询问」同时撤销始终允许。
        harness.session.setPermissionGrant(.ask, for: Harness.permission)
        XCTAssertFalse(harness.store.isAlwaysAllowed(Harness.permission.id))
        XCTAssertEqual(other.permissionGrant(for: Harness.permission), .ask)
    }

    func testDenyDoesNotExecute() async {
        let harness = await Harness(answer: .deny)
        await harness.run("first")
        XCTAssertEqual(harness.tool.executions, 0)
        XCTAssertTrue(harness.results().first?.content.contains("修改 App 运行时") == true)
    }

    func testReadsNeedNoPermission() async {
        let harness = await Harness(answer: .deny, op: "read")
        await harness.run("first")
        XCTAssertEqual(harness.tool.executions, 1)
        XCTAssertEqual(harness.responder.permissionRequests, 0)
    }

    func testDelegatedSessionInheritsButCannotRequest() async {
        let harness = await Harness(answer: .allowForSession)
        let child = AISession(id: UUID().uuidString, agentMask: harness.session.agentMask, delegationDepth: 1)
        child.decisionParent = harness.session
        let denied = await child.authorizePermission(Harness.permission, tool: "probe", detail: nil)
        XCTAssertNotNil(denied)
        XCTAssertEqual(harness.responder.permissionRequests, 0)

        harness.session.setPermissionGrant(.session, for: Harness.permission)
        let inherited = await child.authorizePermission(Harness.permission, tool: "probe", detail: nil)
        XCTAssertNil(inherited)
    }

    func testSnapshotRoundTripKeepsSessionGrants() throws {
        let snapshot = SessionSnapshot(
            id: "s", title: "t", createdAt: Date(), updatedAt: Date(), messages: [],
            permissionGrants: ["a", "b"]
        )
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.permissionGrants, ["a", "b"])
    }
}

private final class Harness: @unchecked Sendable {
    static let permission = AppAgentPermission(id: "test.modify_runtime", title: "修改 App 运行时", summary: "测试")

    let agent: AIAgent
    let session: AISession
    let tool: PermissionTool
    let responder: PermissionResponder
    let store: AppAgentPermissionStore

    init(answer: DecisionOutcome, op: String = "write") async {
        let suite = "permission-tests-\(UUID().uuidString)"
        store = AppAgentPermissionStore(defaults: UserDefaults(suiteName: suite)!, key: "always")
        tool = PermissionTool()
        let tools = ToolCentral()
        await tools.register(tool)
        let providers = ModelProviderCentral()
        await providers.register(name: "p", provider: PermissionProvider(tool: tool.name, op: op))
        var profile = AIAgentProfile(
            autoPersist: false, toolPermissionPolicy: PermissionPolicy(), registerBuiltInTools: false
        )
        profile.permissionStore = store
        agent = AIAgent(
            id: "permission-\(UUID().uuidString)", profile: profile,
            toolCentral: tools, providerCentral: providers,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
        session = await agent.createSession(title: "Permission")
        responder = PermissionResponder(answer: answer)
        let registry = DecisionResponderCentral()
        registry.register(responder)
        session.decisionResponders = registry
    }

    func run(_ text: String) async {
        for await _ in session.sendMessage(text) {
        }
    }

    func results() -> [AIAgentMessage.ToolCallResult] {
        session.messages.flatMap(\.content).compactMap {
            if case .toolResult(let result) = $0 {
                return result
            }
            return nil
        }
    }
}

private struct PermissionPolicy: ToolPermissionPolicy {
    var permissions: [AppAgentPermission] {
        [Harness.permission]
    }

    func requiredPermission(
        for tool: any ToolProtocol, arguments: [String: JSONValue], session: AISession
    ) -> AppAgentPermission? {
        arguments["op"]?.stringValue == "read" ? nil : Harness.permission
    }
}

private final class PermissionResponder: DecisionResponder, @unchecked Sendable {
    @Locked private(set) var permissionRequests = 0
    @Locked private(set) var otherRequests = 0
    let answer: DecisionOutcome

    init(answer: DecisionOutcome) {
        self.answer = answer
    }

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        if case .permission = request {
            $permissionRequests.mutate {
                $0 += 1
            }
            return answer
        }
        $otherRequests.mutate {
            $0 += 1
        }
        return .deny
    }
}

private final class PermissionTool: ToolProtocol, @unchecked Sendable {
    let name = "permission_probe"
    let description = "Permission regression probe"
    let parameters = Tool.Schema(properties: ["op": .string(description: "Operation")], required: ["op"])
    let safetyLevel: Tool.SafetyLevel = .dangerous
    @Locked private(set) var executions = 0

    func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        arguments["op"]?.stringValue == "read" ? .safe : .dangerous
    }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        $executions.mutate {
            $0 += 1
        }
        return .text("executed")
    }
}

private struct PermissionProvider: ModelProvider {
    let tool: String
    let op: String
    let name = "permission-provider"
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
            id: UUID().uuidString, name: tool, arguments: ["op": .string(op)]
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
