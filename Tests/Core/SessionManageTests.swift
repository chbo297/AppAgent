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
}
