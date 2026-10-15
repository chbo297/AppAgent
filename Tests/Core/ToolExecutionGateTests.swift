import XCTest
@testable import AppAgent

final class ToolExecutionGateTests: XCTestCase {
    func testRejectionSkipsExecutionAndAuthorizationWithFullArguments() async throws {
        let gate = GateProbe()
        let tool = GateTool()
        let arguments: [String: JSONValue] = [
            "op": .string("write"),
            "target": .object(["path": .string("workspace/item")]),
            "_why": .string("model explanation")
        ]
        let (agent, session, responder) = await makeSession(tool: tool, gate: gate, arguments: arguments)
        defer {
            _ = agent
        }
        session.uiState.appendUnique("\(tool.name):write", forKey: "approvedToolOps")
        await run(session, text: "read only")
        XCTAssertEqual(tool.executions, 0)
        XCTAssertEqual(responder.asked, 0)
        let results = results(session)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.isError, true)
        XCTAssertTrue(results.first?.content.contains("permission ceiling") == true)
        let checks = await gate.checks
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.arguments, arguments.filter {
            $0.key != "_why"
        })
        XCTAssertEqual(checks.first?.turnID, 1)
        XCTAssertEqual(session.turnRecords[1]?.outcome, .answered)
    }

    func testReadsPassAndPolicyUsesEachCurrentUserTurn() async {
        let gate = GateProbe()
        let tool = GateTool()
        let (agent, session, responder) = await makeSession(
            tool: tool, gate: gate, arguments: ["op": .string("read")]
        )
        defer {
            _ = agent
        }
        await run(session, text: "read only")
        XCTAssertEqual(tool.executions, 1)
        XCTAssertEqual(responder.asked, 0)
        XCTAssertEqual(results(session).first?.isError, false)

        let (writeAgent, writeSession, writeResponder) = await makeSession(
            tool: tool, gate: gate, arguments: ["op": .string("write")]
        )
        defer {
            _ = writeAgent
        }
        await run(writeSession, text: "allow writes")
        await run(writeSession, text: "read only")
        XCTAssertEqual(tool.executions, 2, "Only the first user turn allows writes")
        XCTAssertEqual(writeResponder.asked, 1)
        XCTAssertEqual(results(writeSession).map(\.isError), [false, true])
    }

    func testGateRechecksAfterAsynchronousAuthorization() async {
        let gate = GateProbe()
        let tool = GateTool()
        let (agent, session, responder) = await makeSession(
            tool: tool, gate: gate, arguments: ["op": .string("write")], revokeOnApproval: true
        )
        defer {
            _ = agent
        }
        await run(session, text: "allow writes")
        XCTAssertEqual(responder.asked, 1)
        XCTAssertEqual(tool.executions, 0)
        XCTAssertEqual(results(session).first?.isError, true)
        let checks = await gate.checks
        XCTAssertEqual(checks.count, 2)
    }

    func testDelegationInheritsGateAndPreparesBeforeGeneratedUserTurn() async throws {
        let gate = GateProbe()
        let tool = GateTool()
        let (agent, parent, responder) = await makeSession(
            tool: tool, gate: gate, arguments: ["op": .string("write")]
        )
        defer {
            _ = agent
        }
        parent.addUserMessage("read only")
        let output = try await DelegateTaskTool().execute(
            arguments: ["goal": .string("allow writes")], session: parent
        )
        guard case .json = output else {
            return XCTFail("Child should answer after its tool rejection: \(output)")
        }
        let preparations = await gate.preparations
        XCTAssertEqual(preparations, 1)
        let childWasEmpty = await gate.childWasEmpty
        XCTAssertTrue(childWasEmpty, "The ceiling must be bound before sendMessage")
        let checks = await gate.checks
        XCTAssertEqual(checks.count, 1)
        XCTAssertNotEqual(checks.first?.sessionID, parent.id)
        XCTAssertEqual(checks.first?.turnID, 1)
        XCTAssertEqual(tool.executions, 0, "A generated goal must not elevate the parent's ceiling")
        XCTAssertEqual(responder.asked, 0)
    }

    func testAllowingGateDoesNotOverrideReadOnly() async {
        let tool = GateTool()
        let (agent, session, responder) = await makeSession(
            tool: tool, gate: GateProbe(), arguments: ["op": .string("write")], readOnly: true
        )
        defer {
            _ = agent
        }
        await run(session, text: "allow writes")
        XCTAssertEqual(tool.executions, 0)
        XCTAssertEqual(responder.asked, 0)
        XCTAssertTrue(results(session).first?.content.contains("read-only") == true)
    }

    func testDirectRuntimeMutationUsesInstalledToolAndFailsClosedWhenMissing() async throws {
        let gate = GateProbe()
        let tool = GateTool()
        let (agent, session, responder) = await makeSession(
            tool: tool, gate: gate, arguments: ["op": .string("read")]
        )
        defer {
            _ = agent
        }
        session.addUserMessage("read only")
        for name in [tool.name, "missing_runtime_tool"] {
            do {
                _ = try await HostInspectionAccess.context(
                    arguments: ["op": .string("write"), "scope": .string("all")],
                    session: session, tool: name, isMutation: true
                )
                XCTFail("Direct mutation must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(
                    name == tool.name ? "permission ceiling" : "unavailable"
                ))
            }
        }
        XCTAssertEqual(responder.asked, 0)
        XCTAssertEqual(tool.executions, 0)
        let checks = await gate.checks
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.arguments["scope"], .string("all"))
    }

    private func run(_ session: AISession, text: String) async {
        for await _ in session.sendMessage(text) {
        }
    }

    private func results(_ session: AISession) -> [AIAgentMessage.ToolCallResult] {
        session.messages.flatMap(\.content).compactMap {
            if case .toolResult(let result) = $0 {
                return result
            }
            return nil
        }
    }

    private func makeSession(
        tool: GateTool, gate: GateProbe, arguments: [String: JSONValue],
        revokeOnApproval: Bool = false, readOnly: Bool = false
    ) async -> (AIAgent, AISession, GateResponder) {
        let tools = ToolCentral()
        await tools.register(tool)
        let providers = ModelProviderCentral()
        await providers.register(name: "p", provider: GateProvider(tool: tool.name, arguments: arguments))
        let agent = AIAgent(
            id: "gate-\(UUID().uuidString)",
            profile: AIAgentProfile(
                autoPersist: false, toolMutationPolicy: readOnly ? .readOnly : .allowed,
                toolExecutionGate: gate, registerBuiltInTools: false
            ),
            toolCentral: tools, providerCentral: providers,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Gate")
        let responder = GateResponder(gate: gate, revokeOnApproval: revokeOnApproval)
        let registry = DecisionResponderCentral()
        registry.register(responder)
        session.decisionResponders = registry
        return (agent, session, responder)
    }
}

private actor GateProbe: ToolExecutionGate {
    struct Check: Sendable {
        let sessionID: String
        let turnID: Int
        let arguments: [String: JSONValue]
    }

    var checks: [Check] = []
    var preparations = 0
    var childWasEmpty = false
    private var ceilings: [String: Bool] = [:]
    private var revoked = false

    func revoke() {
        revoked = true
    }

    func prepareDelegation(from parent: AISession, to child: AISession) async {
        preparations += 1
        childWasEmpty = child.messages.isEmpty && child.currentTurnID == 0
        ceilings[child.id] = allowsWrites(parent)
    }

    func rejection(
        for tool: any ToolProtocol, arguments: [String: JSONValue], session: AISession
    ) async -> String? {
        checks.append(Check(sessionID: session.id, turnID: session.currentTurnID, arguments: arguments))
        if arguments["op"]?.stringValue == "read" {
            return nil
        }
        return allowsWrites(session) ? nil : "Host permission ceiling rejects this operation."
    }

    private func allowsWrites(_ session: AISession) -> Bool {
        let input = session.messages.last {
            $0.isGenuineUserInput && $0.turnID == session.currentTurnID
        }
        return !revoked && (ceilings[session.id] ?? (input?.text == "allow writes"))
    }
}

private final class GateResponder: DecisionResponder, @unchecked Sendable {
    @Locked private(set) var asked = 0
    let gate: GateProbe
    let revokeOnApproval: Bool

    init(gate: GateProbe, revokeOnApproval: Bool) {
        self.gate = gate
        self.revokeOnApproval = revokeOnApproval
    }

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        $asked.mutate {
            $0 += 1
        }
        if revokeOnApproval {
            await gate.revoke()
        }
        return .allowForSession
    }
}

private final class GateTool: ToolProtocol, @unchecked Sendable {
    let name = "gate_probe"
    let description = "Gate regression probe"
    let parameters = Tool.Schema(properties: ["op": .string(description: "Operation")], required: ["op"])
    let safetyLevel: Tool.SafetyLevel = .sensitive
    @Locked private(set) var executions = 0

    func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        arguments["op"]?.stringValue == "read" ? .safe : .sensitive
    }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        $executions.mutate {
            $0 += 1
        }
        return .text("executed")
    }
}

private struct GateProvider: ModelProvider {
    let tool: String
    let arguments: [String: JSONValue]
    let name = "gate-provider"
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
        return AsyncThrowingStream {
            if shouldCall {
                $0.yield(.toolCall(.init(id: UUID().uuidString, name: tool, arguments: arguments)))
                $0.yield(.done(stopReason: .toolUse))
            } else {
                $0.yield(.textDelta("done"))
                $0.yield(.done(stopReason: .endTurn))
            }
            $0.finish()
        }
    }
}
