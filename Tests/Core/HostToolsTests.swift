import XCTest
@testable import AppAgent

/// Unit tests for the session-naming logic, host-introspection storage tools,
/// and group-based tool policy added for the codex-style multi-session goal.
final class HostToolsTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession() -> AISession {
        AISession(id: "host-tools-test", title: "New Chat")
    }

    private func json(_ output: Tool.Output) -> JSONValue? {
        if case .json(let v) = output { return v }
        return nil
    }

    private func errorText(_ output: Tool.Output) -> String? {
        if case .error(let s) = output { return s }
        return nil
    }

    // MARK: - Session naming

    func testDeriveTitleTrimsAndTruncates() {
        XCTAssertEqual(AISession.deriveTitle(from: "  Hello world  "), "Hello world")
        XCTAssertNil(AISession.deriveTitle(from: "   \n  "))
        let long = String(repeating: "字", count: 40)
        let derived = AISession.deriveTitle(from: long, maxLength: 24)
        XCTAssertEqual(derived?.count, 25) // 24 chars + ellipsis
        XCTAssertEqual(derived?.hasSuffix("…"), true)
    }

    func testIsDefaultTitle() {
        XCTAssertTrue(AISession.isDefaultTitle("New Chat"))
        XCTAssertTrue(AISession.isDefaultTitle("对话"))
        XCTAssertTrue(AISession.isDefaultTitle("  "))
        XCTAssertFalse(AISession.isDefaultTitle("我的行程规划"))
    }

    func testFirstUserMessageAutoTitles() {
        let session = makeSession()
        session.addUserMessage("帮我规划北京到上海的行程")
        XCTAssertEqual(session.title, "帮我规划北京到上海的行程")
        // A second user message must not overwrite the derived title.
        session.addUserMessage("再加一个杭州")
        XCTAssertEqual(session.title, "帮我规划北京到上海的行程")
    }

    func testAutoTitleSkippedWhenTitleAlreadyCustom() {
        let session = AISession(id: "custom", title: "我的会话")
        session.addUserMessage("hello")
        XCTAssertEqual(session.title, "我的会话")
    }

    func testRenameIgnoresEmptyAndTrims() {
        let session = makeSession()
        session.rename("   ")
        XCTAssertEqual(session.title, "New Chat")
        session.rename("  行程助手  ")
        XCTAssertEqual(session.title, "行程助手")
    }

    // MARK: - AppUserDefaultsTool

    func testUserDefaultsReadWriteRemoveList() async throws {
        let suite = "host-tools-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tool = AppUserDefaultsTool(defaults: defaults)
        let session = makeSession()

        // write string
        _ = try await tool.execute(arguments: ["op": .string("write"), "key": .string("aa.name"), "value": .string("Ducc")], session: session)
        // write JSON number
        _ = try await tool.execute(arguments: ["op": .string("write"), "key": .string("aa.count"), "value": .string("42")], session: session)
        // write JSON bool
        _ = try await tool.execute(arguments: ["op": .string("write"), "key": .string("aa.flag"), "value": .string("true")], session: session)

        let readName = try await tool.execute(arguments: ["op": .string("read"), "key": .string("aa.name")], session: session)
        XCTAssertEqual(json(readName)?["value"]?.stringValue, "Ducc")
        XCTAssertEqual(json(readName)?["exists"]?.boolValue, true)

        let readCount = try await tool.execute(arguments: ["op": .string("read"), "key": .string("aa.count")], session: session)
        XCTAssertEqual(json(readCount)?["value"]?.numberValue, 42)

        let readFlag = try await tool.execute(arguments: ["op": .string("read"), "key": .string("aa.flag")], session: session)
        XCTAssertEqual(json(readFlag)?["value"]?.boolValue, true)

        let list = try await tool.execute(arguments: ["op": .string("list"), "prefix": .string("aa.")], session: session)
        let keys = json(list)?["keys"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertEqual(Set(keys), ["aa.count", "aa.flag", "aa.name"])

        _ = try await tool.execute(arguments: ["op": .string("remove"), "key": .string("aa.name")], session: session)
        let readAfterRemove = try await tool.execute(arguments: ["op": .string("read"), "key": .string("aa.name")], session: session)
        XCTAssertEqual(json(readAfterRemove)?["exists"]?.boolValue, false)
    }

    func testUserDefaultsRequiresKey() async throws {
        let tool = AppUserDefaultsTool(defaults: UserDefaults(suiteName: "x-\(UUID().uuidString)")!)
        let out = try await tool.execute(arguments: ["op": .string("read")], session: makeSession())
        XCTAssertNotNil(errorText(out))
    }

    // MARK: - AppSandboxFileTool

    func testSandboxFileLifecycle() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aa-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = AppSandboxFileTool(root: root)
        let session = makeSession()

        let write = try await tool.execute(arguments: [
            "op": .string("write"), "path": .string("notes/todo.txt"), "content": .string("buy milk")
        ], session: session)
        XCTAssertEqual(json(write)?["success"]?.boolValue, true)

        let read = try await tool.execute(arguments: ["op": .string("read"), "path": .string("notes/todo.txt")], session: session)
        XCTAssertEqual(json(read)?["content"]?.stringValue, "buy milk")

        let list = try await tool.execute(arguments: ["op": .string("list"), "path": .string("notes")], session: session)
        let names = json(list)?["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(names, ["todo.txt"])

        let del = try await tool.execute(arguments: ["op": .string("delete"), "path": .string("notes/todo.txt")], session: session)
        XCTAssertEqual(json(del)?["success"]?.boolValue, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/todo.txt").path))
    }

    func testSandboxRejectsEscapeAndAbsolute() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aa-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = AppSandboxFileTool(root: root)
        let session = makeSession()

        let escape = try await tool.execute(arguments: ["op": .string("read"), "path": .string("../../etc/passwd")], session: session)
        XCTAssertNotNil(errorText(escape))

        let absolute = try await tool.execute(arguments: ["op": .string("read"), "path": .string("/etc/passwd")], session: session)
        XCTAssertNotNil(errorText(absolute))
    }

    // MARK: - Group-based ToolPolicy

    func testGroupPolicyFiltersByGroup() async {
        let central = ToolCentral()
        await central.register(AppUserDefaultsTool())      // host-storage
        await central.register(AppSandboxFileTool())       // host-storage
        await central.register(TodoTool())                 // core

        // allowedGroups keeps only host-storage
        let allowStorage = ToolCentral.ToolPolicy(allowedGroups: [ToolGroups.hostStorage])
        let onlyStorage = await central.resolveTools(policies: [allowStorage])
        XCTAssertEqual(Set(onlyStorage.keys), ["app_user_defaults", "app_sandbox_file"])

        // excludedGroups drops host-storage
        let excludeStorage = ToolCentral.ToolPolicy(excludedGroups: [ToolGroups.hostStorage])
        let noStorage = await central.resolveTools(policies: [excludeStorage])
        XCTAssertEqual(Set(noStorage.keys), ["todo"])
    }

    func testGroupPolicyApplyIgnoresGroupsWithoutResolver() {
        let policy = ToolCentral.ToolPolicy(allowedGroups: ["host-storage"])
        // Name-only apply cannot see groups, so it leaves names untouched.
        let survivors = ToolCentral.ToolPolicy.apply([policy], to: ["a", "b"])
        XCTAssertEqual(survivors, ["a", "b"])
    }

    func testAgentGroupConvenienceMutatesPolicy() async {
        let agent = await AIAgentCentral().create(
            name: "grp-test",
            profile: AIAgentProfile(identity: "t", registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        agent.restrictToolGroups([ToolGroups.hostStorage, ToolGroups.session])
        XCTAssertEqual(agent.toolPolicy?.allowedGroups, [ToolGroups.hostStorage, ToolGroups.session])

        agent.disableToolGroups([ToolGroups.hostRuntime])
        XCTAssertEqual(agent.toolPolicy?.excludedGroups, [ToolGroups.hostRuntime])

        agent.enableToolGroups([ToolGroups.hostRuntime])
        XCTAssertNil(agent.toolPolicy?.excludedGroups)
    }
}
