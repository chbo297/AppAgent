import XCTest
@testable import AppAgent

final class UnifiedCapabilityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-capability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func json(_ output: Tool.Output) -> JSONValue? {
        if case .json(let value) = output {
            return value
        }
        return nil
    }

    func testFileToolUsesLogicalUrisForWorkspaceLifecycle() async throws {
        let root = try temporaryDirectory()
        let registry = FileResourceRegistry(agentWorkspaceURL: root)
        let tool = FileTool(registry: registry)
        let session = AISession(id: UUID().uuidString)

        let catalog = try await tool.execute(arguments: ["op": .string("catalog")], session: session)
        XCTAssertEqual(json(catalog)?["count"]?.numberValue, 4)
        let resources = json(catalog)?["resources"]?.arrayValue ?? []
        XCTAssertTrue(
            resources.contains {
                resource in
                resource["uri"]?.stringValue == "agent://workspace"
            }
        )

        let write = try await tool.execute(arguments: [
            "op": .string("write"),
            "uri": .string("agent://workspace/notes/todo.txt"),
            "content": .string("buy milk\ncall home")
        ], session: session)
        XCTAssertEqual(json(write)?["success"]?.boolValue, true)

        let read = try await tool.execute(arguments: [
            "op": .string("read"),
            "uri": .string("agent://workspace/notes/todo.txt"),
            "offset": .number(2),
            "limit": .number(1)
        ], session: session)
        XCTAssertEqual(json(read)?["content"]?.stringValue, "2|call home")

        let search = try await tool.execute(arguments: [
            "op": .string("search"),
            "uri": .string("agent://workspace"),
            "pattern": .string("milk")
        ], session: session)
        XCTAssertEqual(json(search)?["count"]?.numberValue, 1)

        let physical = try await tool.execute(arguments: [
            "op": .string("reveal_path"),
            "uri": .string("agent://workspace/notes/todo.txt")
        ], session: session)
        XCTAssertEqual(json(physical)?["path"]?.stringValue, root.appendingPathComponent("notes/todo.txt").path)
    }

    func testFileToolRejectsTraversalAndProtectedResourceMutation() async throws {
        let root = try temporaryDirectory()
        let registry = FileResourceRegistry(
            agentWorkspaceURL: root,
            agentSessionsURL: root.appendingPathComponent("sessions", isDirectory: true)
        )
        let tool = FileTool(registry: registry)
        let session = AISession(id: UUID().uuidString)

        let traversal = try await tool.execute(arguments: [
            "op": .string("read"),
            "uri": .string("agent://workspace/../outside.txt")
        ], session: session)
        if case .error = traversal {
        } else {
            XCTFail("Traversal must be rejected")
        }

        let write = try await tool.execute(arguments: [
            "op": .string("write"),
            "uri": .string("agent://sessions/session.json"),
            "content": .string("{}")
        ], session: session)
        XCTAssertTrue(write.stringValue.contains("read-only") || write.stringValue.contains("Session"))
    }

    func testSkillCatalogDoesNotLoadLinkedResourceContents() async throws {
        let root = try temporaryDirectory()
        let skillRoot = root.appendingPathComponent("skills/sample", isDirectory: true)
        let referenceRoot = skillRoot.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceRoot, withIntermediateDirectories: true)
        try """
        ---
        name: sample
        description: Sample skill
        category: development
        ---
        # Body
        Use the reference when needed.
        """.write(
            to: skillRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "reference body".write(
            to: referenceRoot.appendingPathComponent("api.md"),
            atomically: true,
            encoding: .utf8
        )

        let manager = SkillsManager(userSkillsURL: root.appendingPathComponent("skills"))
        let metadata = await manager.listSkills()
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata.first?.name, "sample")
        XCTAssertEqual(metadata.first?.linkedFiles, ["references/api.md"])

        let loaded = await manager.skill(named: "sample")
        XCTAssertEqual(loaded?.content, "# Body\nUse the reference when needed.")
        XCTAssertEqual(loaded?.linkedFiles["references/api.md"], "reference body")
    }
}
