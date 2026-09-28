import XCTest
@testable import AppAgent

final class SessionMergeTests: XCTestCase {
    func testMergePreservesEveryBlockImageAndRecordWhileRemappingLocalIDs() async throws {
        let storage = InMemorySessionStorage()
        let central = ModelProviderCentral()
        let provider = AnthropicProvider(baseURL: "https://example.com", apiKey: "test",
                                         models: [ModelSpec(id: "old"), ModelSpec(id: "current")])
        await central.register(name: "p", provider: provider)
        let agent = AIAgent(id: "merge", profile: .init(identity: "current", autoPersist: false, registerBuiltInTools: false),
                            toolCentral: ToolCentral(), providerCentral: central,
                            modelPolicy: ModelPolicy(primary: "p/old"),
                            memoryStorage: InMemoryMemoryStorage(), sessionStorage: storage)
        let image = AIAgentMessage.ImageAttachment(data: Data([0, 1, 2, 255]), mediaType: "image/png")
        let date = Date(timeIntervalSince1970: 1234)
        let inputs: [AIAgentMessage] = [
            .init(id: "user", role: .user, content: [.text("question")], createdAt: date, turnID: 7),
            .init(id: "assistant", role: .assistant,
                  content: [.text("before"), .toolUse(.init(id: "same-call", name: "screenshot",
                                                          arguments: ["nested": .object(["all": .array([.bool(true)])])])),
                            .text("after")], createdAt: date, turnID: 7),
            .init(id: "result", role: .user,
                  content: [.toolResult(.init(toolCallId: "same-call", content: "full result",
                                             images: [image], isError: true))], createdAt: date, turnID: 7),
            .init(
                id: "answer",
                role: .assistant,
                content: [.text("answer")],
                createdAt: date,
                turnID: 7,
                causedByToolCallId: "same-call"
            )
        ]
        let a = await agent.createSession(title: "A")
        let b = await agent.createSession(title: "B")
        for source in [a, b] {
            source.updateMessages(inputs)
            source.openTurnRecord(turnID: 7, modelRef: "p/old")
            source.advanceTurnRound(turnID: 7, roundCount: 3)
            source.closeTurnRecord(turnID: 7, outcome: .answered, stage: .finished)
            source.promptParts = [.content(SystemPrompt("old system must not be inherited"))]
        }
        let beforeA = try JSONEncoder().encode(a.toSnapshot())
        agent.modelPolicy = ModelPolicy(primary: "p/current")
        let merged = try await agent.sessionManager.mergeSessions([a.id, b.id], title: "Combined")
        XCTAssertEqual(merged.messages.count, 8)
        XCTAssertEqual(merged.messages.compactMap(\.turnID), [1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(Set(merged.messages.map(\.id)).count, 8)
        XCTAssertTrue(Set(inputs.map(\.id)).isDisjoint(with: merged.messages.map(\.id)))
        XCTAssertEqual(merged.messages.map(\.createdAt), Array(repeating: date, count: 8))
        let calls = merged.messages.flatMap(\.toolCalls)
        XCTAssertEqual(Set(calls.map(\.id)).count, 2)
        XCTAssertFalse(calls.contains { $0.id == "same-call" })
        XCTAssertEqual(calls[0].arguments, inputs[1].toolCalls[0].arguments)
        for index in [2, 6] {
            guard case .toolResult(let result) = merged.messages[index].content[0] else {
                return XCTFail("Tool result lost")
            }
            XCTAssertEqual(result.toolCallId, calls[index == 2 ? 0 : 1].id)
            XCTAssertEqual(result.content, "full result")
            XCTAssertEqual(result.images, [image])
            XCTAssertTrue(result.isError)
        }
        XCTAssertEqual(merged.messages[3].causedByToolCallId, calls[0].id)
        XCTAssertEqual(merged.messages[7].causedByToolCallId, calls[1].id)
        for (index, message) in merged.messages.enumerated() {
            XCTAssertEqual(message.text, inputs[index % 4].text)
            XCTAssertEqual(message.content.count, inputs[index % 4].content.count)
        }
        XCTAssertEqual(merged.turnRecords.keys.sorted(), [1, 2])
        var recordA = try XCTUnwrap(a.turnRecord(turnID: 7)); recordA.turnID = 1
        var recordB = try XCTUnwrap(b.turnRecord(turnID: 7)); recordB.turnID = 2
        XCTAssertEqual(merged.turnRecord(turnID: 1), recordA)
        XCTAssertEqual(merged.turnRecord(turnID: 2), recordB)
        XCTAssertEqual(merged.modelId, "current")
        XCTAssertEqual(merged.agentMask?.profile.identity, "current")
        XCTAssertTrue(merged.promptParts.isEmpty)
        XCTAssertFalse(merged.isRunning)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let original = try JSONDecoder().decode(SessionSnapshot.self, from: beforeA)
        XCTAssertEqual(try encoder.encode(a.toSnapshot()), try encoder.encode(original))
        XCTAssertTrue(agent.session(id: a.id) === a)
        XCTAssertTrue(agent.session(id: b.id) === b)
        let saved = try await storage.load(id: merged.id)
        XCTAssertEqual(saved?.messages.count, 8)
        XCTAssertEqual(saved?.turnRecords?.count, 2)
        XCTAssertEqual(merged.addUserMessage("next"), 3)
    }

    func testLegacyTurnsAndRecordOnlyTurnsRemainDistinct() throws {
        let now = Date()
        let snapshots = (0..<2).map { index in
            SessionSnapshot(id: "\(index)", title: "legacy", createdAt: now, updatedAt: now,
                            messages: [.user("first"), .assistant("answer"), .user("second")],
                            turnRecords: [.init(turnID: 99, outcome: .interrupted)])
        }
        let result = try SessionHistoryMerge.merge(snapshots)
        XCTAssertEqual(result.messages.compactMap(\.turnID), [1, 1, 2, 4, 4, 5])
        XCTAssertEqual(result.records.map(\.turnID), [3, 6])
        let restored = AISession(id: "merged", messages: result.messages, turnRecords: result.records)
        XCTAssertEqual(restored.addUserMessage("next"), 7)
    }

    func testRepeatedToolCallIDsAreScopedBySourceAndTurn() throws {
        let now = Date()
        let messages: [AIAgentMessage] = [1, 2].flatMap { turn in
            [
                .init(role: .assistant, content: [.toolUse(.init(id: "call_0", name: "read", arguments: [:]))],
                      turnID: turn),
                .init(role: .user, content: [.toolResult(.init(toolCallId: "call_0", content: "result \(String(describing: turn))"))],
                      turnID: turn)
            ]
        }
        let snapshots = (0..<2).map {
            SessionSnapshot(id: "\($0)", title: "Source", createdAt: now, updatedAt: now, messages: messages)
        }
        let merged = try SessionHistoryMerge.merge(snapshots)
        let callIDs = merged.messages.flatMap(\.toolCalls).map(\.id)
        XCTAssertEqual(Set(callIDs).count, 4)
        for (index, callID) in callIDs.enumerated() {
            guard case .toolResult(let result) = merged.messages[index * 2 + 1].content[0] else {
                return XCTFail("Missing result")
            }
            XCTAssertEqual(result.toolCallId, callID)
        }
    }
}
