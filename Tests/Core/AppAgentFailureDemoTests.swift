import XCTest
@testable import AppAgent

final class AppAgentFailureDemoTests: XCTestCase {
    func testScriptRunsAllScenariosInOrderThroughRealExecutor() async throws {
        let demo = await AppAgentFailureDemo.make(stepDelay: 0)
        XCTAssertFalse(demo.agent.toolCentral === ToolCentral.default)
        XCTAssertFalse(demo.agent.providerCentral === ModelProviderCentral.default)
        XCTAssertFalse(demo.agent.profile.autoPersist)
        XCTAssertFalse(demo.agent.profile.registerBuiltInTools)
        XCTAssertNil(demo.agent.modelPolicy)
        XCTAssertEqual(Set(demo.session.installedTools.keys), ["demo_operation"])
        let stages: [AIAgentRunStage] = [
            .preparing, .requesting, .requesting, .tooling,
            .streaming, .requesting, .streaming, .finished
        ]
        let requests = [0, 1, 4, 5, 1, 5, 1, 2]
        for (index, scenario) in AppAgentFailureDemo.Scenario.allCases.enumerated() {
            await demo.prepare(scenario)
            var terminalCount = 0
            var outputDeltas = 0
            for await event in demo.session.sendMessage(scenario.message) {
                switch event {
                case .completed, .error: terminalCount += 1
                case .streamingContent: outputDeltas += 1
                default: break
                }
            }
            XCTAssertEqual(terminalCount, 1, scenario.rawValue)
            XCTAssertFalse(demo.session.isRunning)
            let record = try XCTUnwrap(demo.session.turnRecord(turnID: index + 1))
            XCTAssertTrue(record.isFinished, scenario.rawValue)
            XCTAssertEqual(record.stage, stages[index], scenario.rawValue)
            XCTAssertEqual(demo.provider.requestCount, requests[index], scenario.rawValue)
            if scenario == .recoveredTool {
                XCTAssertEqual(record.outcome, .answered)
            } else {
                guard case .failed(let stage, let message) = record.outcome else {
                    XCTFail("场景未失败：\(scenario)"); continue
                }
                XCTAssertEqual(stage, stages[index])
                XCTAssertFalse(message.isEmpty)
            }
            if scenario == .streamInterrupted {
                XCTAssertGreaterThan(outputDeltas, 0)
                let partial = demo.session.messages.filter {
                    $0.turnID == index + 1 && $0.role == .assistant
                }
                XCTAssertEqual(partial.count, 1)
                XCTAssertTrue(partial.first?.text.contains("这是一段已经收到的模型输出") == true,
                              "终局重建不能丢掉已经输出的半截正文")
                XCTAssertTrue(partial.allSatisfy { $0.toolCalls.isEmpty })
            }
        }
        XCTAssertEqual(demo.session.messages.filter(\.isGenuineUserInput).map(\.text),
                       AppAgentFailureDemo.Scenario.allCases.map(\.message))
        let results = demo.session.messages.flatMap { message in
            message.content.compactMap { block -> (Int?, Bool)? in
                guard case .toolResult(let result) = block else { return nil }
                return (message.turnID, result.isError)
            }
        }
        XCTAssertGreaterThanOrEqual(results.filter { $0.0 == 4 && $0.1 }.count, 2)
        XCTAssertEqual(results.filter { $0.0 == 6 && !$0.1 }.count, 1)
        XCTAssertEqual(results.filter { $0.0 == 8 && $0.1 }.count, 1)
        let stored = try await demo.agent.sessionManager.storage.loadAll()
        XCTAssertTrue(stored.isEmpty, "演示不保存会话")
    }

    func testCancellationDuringMockStreamEndsTheTurn() async throws {
        let demo = await AppAgentFailureDemo.make(stepDelay: 10_000_000_000)
        await demo.prepare(.firstRequest)
        let started = expectation(description: "executor started")
        let consumer = Task {
            for await event in demo.session.sendMessage("取消演示") {
                if case .started = event { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        demo.session.cancel()
        await consumer.value
        XCTAssertEqual(demo.session.turnRecord(turnID: 1)?.outcome, .cancelled)
        XCTAssertFalse(demo.session.isRunning)
    }
}
