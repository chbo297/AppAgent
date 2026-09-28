//
//  SessionManageTests.swift
//  AppAgent — session_manage tool (codex-style self-awareness)
//
//  Exercises the agent's ability to introspect and manage its own sessions:
//  list (with runtime status + is_current), read history, rename, and delete
//  (including the guard against deleting the current session).
//

import XCTest
@testable import AppAgent

final class SessionManageTests: XCTestCase {

    private func makeAgent() async -> AIAgent {
        let central = AIAgentCentral()
        return await central.create(
            name: "session-manage-test",
            profile: AIAgentProfile(identity: "Test"),
            sessionStorage: InMemorySessionStorage()
        )
    }

    private let tool = SessionManageTool()

    private func run(_ args: [String: JSONValue], on session: AISession) async throws -> JSONValue {
        let out = try await tool.execute(arguments: args, session: session)
        switch out {
        case .json(let v): return v
        case .text(let t): return .string(t)
        case .error(let e): return .object(["error": .string(e)])
        case .image(let image): return .object(["image": .string(image.caption)])
        }
    }

    func testListReportsSessionsStatusAndCurrent() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "First")
        let s2 = await agent.createSession(title: "Second")

        let result = try await run(["op": .string("list")], on: s1)
        XCTAssertEqual(result["count"]?.numberValue, 2)
        XCTAssertEqual(result["current_session_id"]?.stringValue, s1.id)

        let sessions = result["sessions"]?.arrayValue ?? []
        XCTAssertEqual(sessions.count, 2)
        // Every entry carries a status and an is_current flag.
        let currentEntry = sessions.first { $0["session_id"]?.stringValue == s1.id }
        XCTAssertEqual(currentEntry?["is_current"]?.boolValue, true)
        XCTAssertEqual(currentEntry?["status"]?.stringValue, "idle")
        let otherEntry = sessions.first { $0["session_id"]?.stringValue == s2.id }
        XCTAssertEqual(otherEntry?["is_current"]?.boolValue, false)
    }

    func testReadReturnsHistory() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "Reader")
        let other = await agent.createSession(title: "Other")
        other.addUserMessage("hello from other")

        let result = try await run(["op": .string("read"), "session_id": .string(other.id)], on: s1)
        XCTAssertEqual(result["session_id"]?.stringValue, other.id)
        XCTAssertEqual(result["status"]?.stringValue, "idle")
        let messages = result["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"]?.stringValue, "user")
        XCTAssertEqual(messages.first?["text"]?.stringValue, "hello from other")
    }

    func testRenameChangesTitle() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "Home")
        let target = await agent.createSession(title: "Old Name")

        let result = try await run([
            "op": .string("rename"),
            "session_id": .string(target.id),
            "title": .string("New Name")
        ], on: s1)
        XCTAssertEqual(result["success"]?.boolValue, true)
        XCTAssertEqual(target.title, "New Name")
    }

    func testDeleteArchivesSessionRecoverably() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "Home")
        let target = await agent.createSession(title: "Trash Me")
        XCTAssertEqual(agent.allSessions.count, 2)

        let result = try await run([
            "op": .string("delete"),
            "session_id": .string(target.id)
        ], on: s1)
        XCTAssertEqual(result["success"]?.boolValue, true)
        XCTAssertEqual(result["deleted_session_id"]?.stringValue, target.id)
        XCTAssertNil(agent.session(id: target.id))
        XCTAssertEqual(agent.allSessions.count, 1)
        let archives = try await agent.sessionManager.archivedSessions()
        XCTAssertEqual(archives.map(\.id), [target.id])
        let restored = try await run(["op": .string("restore"), "session_id": .string(target.id)], on: s1)
        XCTAssertEqual(restored["success"]?.boolValue, true)
        XCTAssertEqual(agent.allSessions.count, 2)
    }

    func testCannotDeleteCurrentSession() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "Current")

        let result = try await run([
            "op": .string("delete"),
            "session_id": .string(s1.id)
        ], on: s1)
        // Guarded: returns an error and the session survives.
        XCTAssertNotNil(result["error"]?.stringValue)
        XCTAssertNotNil(agent.session(id: s1.id))
    }

    func testDeleteMissingSessionErrors() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "Current")

        let result = try await run([
            "op": .string("delete"),
            "session_id": .string("does-not-exist")
        ], on: s1)
        XCTAssertNotNil(result["error"]?.stringValue)
    }

    // MARK: - 会话控制：新建 / 切换 / 换模型 / 清空

    func testCreateSessionAddsAnotherSession() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "First")

        let result = try await run(["op": .string("create"), "title": .string("由工具新建")], on: s1)
        XCTAssertEqual(result["success"]?.boolValue, true)
        let newID = try XCTUnwrap(result["session_id"]?.stringValue)
        XCTAssertEqual(agent.session(id: newID)?.title, "由工具新建")
        XCTAssertEqual(agent.allSessions.count, 2)
    }

    func testSwitchRequiresHostHandlerAndReportsSuccess() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "First")
        let s2 = await agent.createSession(title: "Second")

        // 宿主未安装切换钩子：明确报错而不是假装成功。
        let denied = try await run(["op": .string("switch"), "session_id": .string(s2.id)], on: s1)
        XCTAssertNotNil(denied["error"]?.stringValue)

        // 安装钩子后返回成功，并把请求的 session id 透传给宿主。
        let box = ActivationBox()
        agent.activateSessionHandler = { id in
            box.requested = id
            return true
        }
        let accepted = try await run(["op": .string("switch"), "session_id": .string(s2.id)], on: s1)
        XCTAssertEqual(accepted["success"]?.boolValue, true)
        XCTAssertEqual(box.requested, s2.id)
    }

    func testSetModelFailsForUnknownReference() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "First")

        let result = try await run([
            "op": .string("set_model"),
            "model": .string("nope/none")
        ], on: s1)
        XCTAssertNotNil(result["error"]?.stringValue)
    }

    func testModelsListsPolicyAndRegisteredModels() async throws {
        let central = ModelProviderCentral()
        await central.register(
            name: "pa",
            provider: AnthropicProvider(
                baseURL: "https://example.com/v1",
                apiKey: "k",
                apiProtocol: .openaiCompletions,
                models: [ModelSpec(id: "A"), ModelSpec(id: "B")]
            )
        )
        let agent = AIAgent(
            id: "models-op",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "pa/A", fallbacks: ["pa/B"]),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "t")

        let result = try await run(["op": .string("models")], on: session)
        XCTAssertEqual(result["count"]?.numberValue, 2)
        XCTAssertEqual(result["policy_primary"]?.stringValue, "pa/A")
        XCTAssertEqual(result["policy_fallbacks"]?.arrayValue?.first?.stringValue, "pa/B")
        let refs = (result["models"]?.arrayValue ?? []).compactMap { $0["reference"]?.stringValue }
        XCTAssertEqual(Set(refs), Set(["pa/A", "pa/B"]))
    }

    func testClearRefusesToWipeHistory() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "First")
        let target = await agent.createSession(title: "Target")
        target.addUserMessage("one")
        target.addUserMessage("two")

        let result = try await run(["op": .string("clear"), "session_id": .string(target.id)], on: s1)
        XCTAssertTrue(result["error"]?.stringValue?.contains("archive + create") == true)
        XCTAssertEqual(agent.session(id: target.id)?.messages.count, 2)
    }

    func testReadPagesEntireHistoryAndClampsLegacyCap() async throws {
        let agent = await makeAgent()
        let current = await agent.createSession(title: "Reader")
        let target = await agent.createSession(title: "Long")
        target.updateMessages((0..<120).map { .user("message \($0)", turnID: $0 + 1) })
        var texts: [String] = []
        for offset in stride(from: 0, to: 120, by: 17) {
            let page = try await run(["op": .string("read"), "session_id": .string(target.id),
                                      "offset": .number(Double(offset)), "limit": .number(17)], on: current)
            texts += (page["messages"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        }
        XCTAssertEqual(texts, (0..<120).map { "message \($0)" })
        let small = try await run(["op": .string("read"), "session_id": .string(target.id),
                                   "max_messages": .number(-10)], on: current)
        XCTAssertEqual(small["returned"]?.numberValue, 1)
        XCTAssertEqual(small["offset"]?.numberValue, 119)
        let large = try await run(["op": .string("read"), "session_id": .string(target.id),
                                   "max_messages": .number(100_000)], on: current)
        XCTAssertEqual(large["limit"]?.numberValue, 500)
        for number in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, Double(Int.max), 1.5] {
            for key in ["offset", "limit", "max_messages", "message_byte_offset"] {
                let rejected = try await run(["op": .string("read"), "session_id": .string(target.id),
                                             key: .number(number)], on: current)
                XCTAssertNotNil(rejected["error"], "\(key): \(number)")
            }
            let search = try await SessionSearchTool().execute(arguments: ["limit": .number(number)], session: current)
            guard case .error = search else { return XCTFail("Invalid search limit accepted: \(number)") }
        }
    }

    func testPermanentDeletionCannotBeRequestedThroughToolParameters() async throws {
        let agent = await makeAgent()
        let current = await agent.createSession(title: "Current")
        let target = await agent.createSession(title: "Keep")
        for op in ["purge", "permanent_delete", "clear"] {
            let result = try await run(["op": .string(op), "session_id": .string(target.id)], on: current)
            XCTAssertNotNil(result["error"])
        }
        for key in ["purge", "permanent_delete", "permanent", "force", "options"] {
            let result = try await run(["op": .string("delete"), "session_id": .string(target.id),
                                        key: .bool(true)], on: current)
            XCTAssertNotNil(result["error"])
        }
        XCTAssertNotNil(agent.session(id: target.id))
        let archives = try await agent.sessionManager.archivedSessions()
        XCTAssertTrue(archives.isEmpty)
    }

    func testReadOnlyExecuteChecksCurrentAndParentWithoutInspectionGrant() async throws {
        let agent = await makeAgent()
        let target = await agent.createSession(title: "Keep")
        let parent = await agent.createSession(title: "Parent")
        var restricted = agent.profile
        restricted.toolMutationPolicy = .readOnly
        let parentMask = AIAgentMask(profile: restricted, toolPolicy: nil, toolCentral: agent.toolCentral, agent: agent)
        let readOnlyParent = AISession(id: "readonly-parent", agentMask: parentMask)
        let child = AISession(id: "child", agentMask: agent.buildMask(), delegationDepth: 1)
        child.decisionParent = readOnlyParent
        for caller in [readOnlyParent, child] {
            for op in ["create", "archive", "delete", "restore", "rename", "switch", "set_model", "merge"] {
                let result = try await run(["op": .string(op), "session_id": .string(target.id),
                                            "title": .string("changed"), "model": .string("no/model"),
                                            "source_session_ids": .array([.string(target.id), .string(parent.id)])],
                                           on: caller)
                XCTAssertTrue(result["error"]?.stringValue?.contains("readOnly") == true, op)
            }
            let read = try await run(["op": .string("read"), "session_id": .string(target.id)], on: caller)
            XCTAssertEqual(read["session_id"]?.stringValue, target.id)
            let list = try await run(["op": .string("list")], on: caller)
            XCTAssertEqual(list["count"]?.numberValue, 2)
        }
        XCTAssertEqual(target.title, "Keep")
    }

    func testMergeToolValidationAndSuccess() async throws {
        let agent = await makeAgent()
        let caller = await agent.createSession(title: "Caller")
        let a = await agent.createSession(title: "A")
        let b = await agent.createSession(title: "B")
        a.addUserMessage("a")
        b.addUserMessage("b")
        for value: JSONValue in [.string(a.id), .array([]), .array([.string(a.id)]),
                                 .array([.string(a.id), .string(a.id)]),
                                 .array([.string(a.id), .number(3)]),
                                 .array([.string(a.id), .string(caller.id)]),
                                 .array([.string(a.id), .string("foreign")])] {
            let result = try await run(["op": .string("merge"), "source_session_ids": value], on: caller)
            XCTAssertNotNil(result["error"])
        }
        let result = try await run(["op": .string("merge"),
                                    "source_session_ids": .array([.string(a.id), .string(b.id)])], on: caller)
        XCTAssertEqual(result["success"]?.boolValue, true)
        let merged = try XCTUnwrap(agent.session(id: try XCTUnwrap(result["session_id"]?.stringValue)))
        XCTAssertEqual(merged.messages.map(\.text), ["a", "b"])
        XCTAssertEqual(agent.allSessions.count, 4)
    }

    func testReadFragmentsPreserveOversizedBlocksAndImagesWithinExecutorBudget() async throws {
        let agent = await makeAgent()
        let caller = await agent.createSession(title: "Reader")
        let source = await agent.createSession(title: "Large history")
        let text = String(repeating: "完整文本\n\"\\", count: 12_000)
        let image = AIAgentMessage.ImageAttachment(data: Data(repeating: 255, count: 100_000), mediaType: "image/png")
        source.updateMessages([
            .init(role: .user, content: [.toolResult(.init(toolCallId: "call", content: text, images: [image]))],
                  turnID: 1),
            .assistant("tail", turnID: 1)
        ])
        var arguments: [String: JSONValue] = ["op": .string("read"), "session_id": .string(source.id),
                                             "offset": .number(0), "limit": .number(1)]
        var joined = ""
        var last: JSONValue = .null
        for _ in 0..<200 {
            let output = try await tool.execute(arguments: arguments, session: caller)
            XCTAssertLessThanOrEqual(output.stringValue.utf8.count, tool.outputMaxBytes ?? 8192)
            XCTAssertEqual(LLMExecutor.clampToolOutput(output.stringValue, maxBytes: tool.outputMaxBytes ?? 8192,
                                                      toolName: tool.name), output.stringValue)
            guard case .json(let page) = output,
                  let part = page["message_json_fragment"]?.stringValue else {
                return XCTFail("Expected an oversized-message fragment")
            }
            joined += part
            last = page
            guard let next = page["next_message_byte_offset"]?.numberValue else { break }
            arguments["message_byte_offset"] = .number(next)
        }
        XCTAssertEqual(last["next_offset"]?.numberValue, 1)
        XCTAssertEqual(last["next_message_byte_offset"], .null)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIAgentMessage.self, from: Data(joined.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(decoded.content), try encoder.encode(source.messages[0].content))
        XCTAssertEqual(decoded.id, source.messages[0].id)

        // Smaller messages reduce the page length rather than truncating JSON or skipping records.
        source.updateMessages((0..<20).map { .user(String(repeating: "x", count: 4_000) + "\($0)") })
        var offset = 0
        var ids: [String] = []
        while offset < 20 {
            let output = try await tool.execute(
                arguments: ["op": .string("read"), "session_id": .string(source.id),
                            "offset": .number(Double(offset)), "limit": .number(20)], session: caller)
            XCTAssertLessThanOrEqual(output.stringValue.utf8.count, tool.outputMaxBytes ?? 8192)
            guard case .json(let page) = output, let messages = page["messages"]?.arrayValue,
                  !messages.isEmpty else { return XCTFail("Pagination made no progress") }
            ids += messages.compactMap { $0["id"]?.stringValue }
            offset = Int(page["next_offset"]?.numberValue ?? 20)
        }
        XCTAssertEqual(ids, source.messages.map(\.id))
    }

    func testSearchToolResultIncludesMatchingPreview() async throws {
        let agent = await makeAgent()
        let caller = await agent.createSession(title: "Reader")
        let source = await agent.createSession(title: "Tool history")
        source.updateMessages([
            .init(role: .user, content: [.toolResult(.init(toolCallId: "call", content: "needle in tool output"))])
        ])
        let output = try await SessionSearchTool().execute(arguments: ["query": .string("needle")], session: caller)
        guard case .json(let result) = output else { return XCTFail("Expected search results") }
        XCTAssertEqual(result["count"]?.numberValue, 1)
        XCTAssertEqual(result["matches"]?.arrayValue?.first?["preview"]?.stringValue, "needle in tool output")
    }
}

/// 记录宿主收到的激活请求（闭包里不能直接改局部变量）。
private final class ActivationBox: @unchecked Sendable {
    var requested: String?
}
