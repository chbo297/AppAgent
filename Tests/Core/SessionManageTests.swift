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

    func testDeleteRemovesSession() async throws {
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

    func testClearWipesHistoryButKeepsSession() async throws {
        let agent = await makeAgent()
        let s1 = await agent.createSession(title: "First")
        let target = await agent.createSession(title: "Target")
        target.addUserMessage("one")
        target.addUserMessage("two")

        let result = try await run(["op": .string("clear"), "session_id": .string(target.id)], on: s1)
        XCTAssertEqual(result["success"]?.boolValue, true)
        XCTAssertEqual(result["removed_messages"]?.numberValue, 2)
        XCTAssertEqual(agent.session(id: target.id)?.messages.count, 0)
    }
}

/// 记录宿主收到的激活请求（闭包里不能直接改局部变量）。
private final class ActivationBox: @unchecked Sendable {
    var requested: String?
}

