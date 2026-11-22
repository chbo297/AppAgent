import XCTest
@testable import AppAgent

final class CoreConcurrencyAuditTests: XCTestCase {
    func testContextInjectionPreservesMessageIdentityAndHostMetadata() async throws {
        let session = AISession(id: "context-metadata")
        let original = AIAgentMessage(
            role: .user, content: [.text("host question")], turnID: 1,
            messageType: .hostEvent, source: .app, displayPolicy: .hidden,
            trigger: "host-event", eventId: "event-1", causedByToolCallId: "call-1")
        let prepared = await session.executor.prepareMessagesForProvider(
            [original], session: session, turnID: 1, isFirstIteration: true)
        let wrapped = try XCTUnwrap(prepared.first)
        XCTAssertTrue(wrapped.text.contains("host question"))
        XCTAssertNotEqual(wrapped.text, original.text)
        XCTAssertEqual(wrapped.id, original.id)
        XCTAssertEqual(wrapped.createdAt, original.createdAt)
        XCTAssertEqual(wrapped.turnID, original.turnID)
        XCTAssertEqual(wrapped.messageType, original.messageType)
        XCTAssertEqual(wrapped.source, original.source)
        XCTAssertEqual(wrapped.displayPolicy, original.displayPolicy)
        XCTAssertEqual(wrapped.trigger, original.trigger)
        XCTAssertEqual(wrapped.eventId, original.eventId)
        XCTAssertEqual(wrapped.causedByToolCallId, original.causedByToolCallId)
    }

    func testSupersededBeforePreparationReportsCancellation() async {
        let firstEntered = expectation(description: "First run has not prepared")
        let firstGate = DispatchSemaphore(value: 0)
        let begins = Locked(wrappedValue: 0)
        BackgroundActivity.install { _ in
            let count = begins.mutate { $0 += 1; return $0 }
            if count == 1 {
                firstEntered.fulfill()
                firstGate.wait()
            }
            return {}
        }
        defer { BackgroundActivity.install(nil) }
        let agent = AIAgent(
            id: "early-cancel", profile: .init(autoPersist: false, registerBuiltInTools: false),
            toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage())
        let session = await agent.sessionManager.createSession(provider: AuditReplyProvider(), modelId: "audit")
        let first = session.sendMessage("superseded before preparation")
        await fulfillment(of: [firstEntered], timeout: 2)
        let replacement = session.sendMessage("replacement")
        firstGate.signal()
        var cancellations = 0
        for await event in first {
            if case .error(let error) = event, case .cancelled = error as? AIAgentError {
                cancellations += 1
            }
        }
        XCTAssertEqual(cancellations, 1, "Expected cancellation must not become runEndedWithoutResult")
        for await _ in replacement {}
    }

    func testConcurrentUserMessageAppendsDoNotLoseHistory() {
        let session = AISession(id: "concurrent-history", title: "Fixed")
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            session.addUserMessage("question-\(index)")
        }
        XCTAssertEqual(session.messages.count, 200)
        XCTAssertEqual(Set(session.messages.compactMap(\.turnID)).count, 200)
        XCTAssertEqual(session.currentTurnID, 200)
    }

    func testLoopDetectionTreatsNestedObjectKeyOrderAsEqual() {
        var detector = ToolLoopDetector()
        let fields = (0..<20).map { ("key-\($0)", JSONValue.number(Double($0))) }
        var criticalCount = 0
        for iteration in 0..<12 {
            let nested = Dictionary(uniqueKeysWithValues: iteration.isMultiple(of: 2) ? fields : fields.reversed())
            let result = detector.record(name: "repeat", arguments: ["nested": .object(nested)])
            if case .critical = result { criticalCount += 1 }
        }
        XCTAssertEqual(criticalCount, 8, "Equivalent nested objects must count as consecutive repeats")
    }

    func testPingPongDetectionRequiresConsistentAlternation() {
        var detector = ToolLoopDetector(config: .init(repeatThreshold: 100, criticalThreshold: 100))
        for name in ["a", "b", "b", "a", "a", "b", "b", "a"] {
            guard case .ok = detector.record(name: name, arguments: [:]) else {
                return XCTFail("Adjacent reversed pairs are not an A-B-A-B loop")
            }
        }
    }

    func testSimultaneousSessionStartsRespectTopLevelLimit() async {
        let gate = ReadySignal()
        let agent = AIAgent(
            id: "run-limit", profile: .init(
                additionalPromptBuilders: [PromptBuilder("hold-run") { _ in
                    await gate.wait()
                    return nil
                }], autoPersist: false, registerBuiltInTools: false),
            toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage())
        let provider = AuditReplyProvider()
        var sessions: [AISession] = []
        for _ in 0..<48 {
            sessions.append(await agent.sessionManager.createSession(title: "Concurrent", provider: provider, modelId: "audit"))
        }
        let candidates = sessions
        let streams = Locked(wrappedValue: [AsyncStream<AIAgentEvent>]())
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let stream = candidates[index].sendMessage("start")
            streams.mutate { $0.append(stream) }
        }
        XCTAssertEqual(agent.sessionManager.runningSessionCount, agent.sessionManager.governor.limit,
                       "Admission must reserve the run synchronously with its limit check")
        await gate.signal()
        for stream in streams.wrappedValue {
            for await _ in stream {}
        }
    }

    func testCancellingSupersededOutputStreamDoesNotClearReplacementUI() async {
        let firstEntered = expectation(description: "First run is preparing")
        let secondEntered = expectation(description: "Replacement is preparing")
        let firstGate = ReadySignal()
        let secondGate = ReadySignal()
        let provider = AuditReplyProvider()
        let agent = AIAgent(
            id: "stale-stream", profile: .init(
                additionalPromptBuilders: [PromptBuilder("gate") { session in
                    if session.currentTurnID == 1 {
                        firstEntered.fulfill()
                        await firstGate.wait()
                    } else {
                        secondEntered.fulfill()
                        await secondGate.wait()
                    }
                    return nil
                }], autoPersist: false, registerBuiltInTools: false),
            toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage())
        let session = await agent.sessionManager.createSession(provider: provider, modelId: "audit")
        let firstStream = session.sendMessage("first")
        let firstDrain = Task { for await _ in firstStream {} }
        await fulfillment(of: [firstEntered], timeout: 2)
        let secondStream = session.sendMessage("second")
        let secondDrain = Task { for await _ in secondStream {} }
        await fulfillment(of: [secondEntered], timeout: 2)

        firstDrain.cancel()
        await firstDrain.value
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.uiState.isStreaming, "A stale stream must not clear the active run's UI")
        XCTAssertNil(session.turnRecord(turnID: 2)?.outcome)

        await firstGate.signal()
        await secondGate.signal()
        await secondDrain.value
    }

    func testCompressionPreservesCompleteSessionHistoryOnSuccessAndFailure() async {
        for failAfterTool in [false, true] {
            let provider = AuditReplyProvider(failAfterTool: failAfterTool, usesTool: true)
            let agent = AIAgent(
                id: "compression", profile: .init(autoPersist: false, registerBuiltInTools: false),
                toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
                memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage())
            let session = await agent.sessionManager.createSession(provider: provider, modelId: "audit")
            var original: [AIAgentMessage] = []
            for turn in 1...8 {
                original.append(.user("question-\(turn) " + String(repeating: "x", count: 400), turnID: turn))
                original.append(.init(role: .assistant, content: [.text("answer-\(turn)")], turnID: turn))
            }
            session.updateMessages(original)
            var terminalCount = 0
            for await event in session.sendMessage("latest question") {
                switch event {
                case .completed, .error: terminalCount += 1
                default: break
                }
            }
            XCTAssertEqual(terminalCount, 1)
            XCTAssertEqual(Array(session.messages.prefix(original.count)).map(\.id), original.map(\.id),
                           "Compression must only change the provider's view, including on a failed turn")
            XCTAssertEqual(provider.requests.count, 2)
            XCTAssertTrue(provider.requests.allSatisfy { $0.count < original.count })
            XCTAssertFalse(session.messages.contains { $0.text.contains("[CONTEXT COMPACTED:") })
            XCTAssertEqual(session.turnRecord(turnID: 9)?.isFinished, true)
        }
    }
}

private final class AuditReplyProvider: ModelProvider, @unchecked Sendable {
    let name = "audit"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "audit", contextWindow: 200)]
    let requestTimeout: TimeInterval = 5
    @Locked private(set) var requests: [[AIAgentMessage]] = []
    private let failAfterTool: Bool
    private let usesTool: Bool

    init(failAfterTool: Bool = false, usesTool: Bool = false) {
        self.failAfterTool = failAfterTool
        self.usesTool = usesTool
    }

    func streamCompletion(messages: [AIAgentMessage], system: [ContentOrCacheControl<SystemPrompt>],
                          tools: [ContentOrCacheControl<any ToolProtocol>], modelId: String)
        -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let iteration = $requests.mutate { $0.append(messages); return $0.count }
        return AsyncThrowingStream { continuation in
            if usesTool && iteration == 1 {
                continuation.yield(.toolCall(.init(id: "call-audit", name: "missing-tool", arguments: [:])))
                continuation.yield(.done(stopReason: .toolUse))
            } else if failAfterTool {
                continuation.yield(.done(stopReason: .unknown))
            } else {
                continuation.yield(.textDelta("complete"))
                continuation.yield(.done(stopReason: .endTurn))
            }
            continuation.finish()
        }
    }
}
