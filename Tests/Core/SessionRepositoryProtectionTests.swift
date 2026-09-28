import XCTest
@testable import AppAgent

final class SessionRepositoryProtectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("session-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func seed(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "keep".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func denial(_ path: String) throws -> String? {
        let paths = try XCTUnwrap(SandboxPathResolver(sandboxRoot: root).paths(for: path))
        return SessionRepositoryProtection.mutationDenial(
            logical: paths.logical, resolved: paths.resolved, sandboxRoot: root
        )
    }

    func testDefaultRepositoryActiveTrashAndAncestorsCannotBeWrittenInAnyScope() throws {
        _ = try seed("Documents/AppAgent/sessions/active.json")
        _ = try seed("Documents/AppAgent/sessions/trash/deleted.json")
        let policy = HostStoragePolicy(root: root)
        for path in ["Documents/AppAgent/sessions/active.json", "Documents/AppAgent/sessions/trash/deleted.json",
                     "Documents/AppAgent/sessions/trash/new.json", "Documents/AppAgent/sessions",
                     "Documents/AppAgent/sessions/trash", "Documents/AppAgent", "Documents"] {
            let paths = try XCTUnwrap(SandboxPathResolver(sandboxRoot: root).paths(for: path))
            for scope in [HostInspectionScope.host, .appagent, .all] {
                for operation in [HostStoragePolicy.Operation.write, .delete] {
                    XCTAssertNotNil(policy.denial(logical: paths.logical, resolved: paths.resolved,
                                                  scope: scope, operation: operation), "\(scope): \(path)")
                }
            }
        }
        XCTAssertNil(try denial("Documents/AppAgent/files/note.txt"))
        XCTAssertNil(try denial("Documents/AppAgent/sessions-other/note.txt"))
    }

    func testRegisteredCustomRepositoryAndReverseAliasesAreProtected() throws {
        let target = try seed("backing/entry.json")
        let repo = root.appendingPathComponent("custom/history")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("trash"), withIntermediateDirectories: true)
        _ = FileSessionStorage(directory: repo)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("trash/entry.json"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: repo)
        for path in ["custom", "custom/history", "custom/history/trash/entry.json",
                     "alias/trash/new.json", "backing/entry.json", "backing"] {
            XCTAssertNotNil(try denial(path), path)
        }
        XCTAssertNil(try denial("backing/unrelated.txt"))
        XCTAssertNil(try denial("custom/ordinary.txt"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testChainedRepositoryAliasesProtectRelayAndBackingAncestors() throws {
        let target = try seed("Documents/backing/store/session.json")
        let fm = FileManager.default
        let relay = root.appendingPathComponent("Documents/relay/store")
        try fm.createDirectory(at: relay.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: relay, withDestinationURL: target.deletingLastPathComponent())
        let repo = root.appendingPathComponent("Documents/repo")
        try fm.createSymbolicLink(at: repo, withDestinationURL: relay)
        _ = FileSessionStorage(directory: repo)
        let policy = HostStoragePolicy(root: root)
        for path in ["Documents/repo", "Documents/relay", "Documents/relay/store",
                     "Documents/backing", "Documents/backing/store", "Documents/backing/store/session.json",
                     "Documents/relay/store/new.json"] {
            XCTAssertEqual(try denial(path), SessionRepositoryProtection.deniedMessage, path)
            let paths = try XCTUnwrap(SandboxPathResolver(sandboxRoot: root).paths(for: path))
            for operation in [HostStoragePolicy.Operation.write, .delete] {
                XCTAssertNotNil(policy.denial(logical: paths.logical, resolved: paths.resolved,
                                              scope: .all, operation: operation), path)
            }
        }
        XCTAssertNil(try denial("Documents/backing/unrelated.json"))
        XCTAssertNil(try denial("Documents/relay/unrelated.json"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testPrefixLinkDependenciesDoNotReserveUnrelatedSiblings() throws {
        let target = try seed("backing/store/session.json")
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createSymbolicLink(at: prefix,
                                                   withDestinationURL: root.appendingPathComponent("backing"))
        _ = FileSessionStorage(directory: prefix.appendingPathComponent("store"))
        XCTAssertEqual(try denial("prefix"), SessionRepositoryProtection.deniedMessage)
        XCTAssertEqual(try denial("backing"), SessionRepositoryProtection.deniedMessage)
        XCTAssertNil(try denial("prefix/ordinary.txt"))
        XCTAssertNil(try denial("backing/ordinary.txt"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testWarmAliasIndexDetectsCreationReplacementAndRestoredMtime() throws {
        _ = try seed("repo/nested/ordinary.json")
        let first = try seed("first/session.json")
        let second = try seed("second/session.json")
        _ = FileSessionStorage(directory: root.appendingPathComponent("repo"))
        XCTAssertNil(try denial("first/session.json")) // Warm the nested directory cache.
        let fm = FileManager.default
        let nested = root.appendingPathComponent("repo/nested")
        let oldDate = try XCTUnwrap(fm.attributesOfItem(atPath: nested.path)[.modificationDate] as? Date)
        let link = nested.appendingPathComponent("ordinary.json")
        try fm.removeItem(at: link) // A formerly ignored leaf becomes topology.
        try fm.createSymbolicLink(at: link, withDestinationURL: first)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: nested.path)
        XCTAssertEqual(try denial("first/session.json"), SessionRepositoryProtection.deniedMessage)
        XCTAssertNil(try denial("second/session.json"))
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: second)
        XCTAssertEqual(try denial("second/session.json"), SessionRepositoryProtection.deniedMessage)
        XCTAssertNil(try denial("second/unrelated.json"))
    }

    func testDirectoryReplacementInvalidatesWarmAliasCache() throws {
        let fm = FileManager.default
        _ = try seed("repo/nested/ordinary.json")
        let backing = try seed("backing/session.json")
        _ = FileSessionStorage(directory: root.appendingPathComponent("repo"))
        XCTAssertNil(try denial("backing/session.json"))
        let nested = root.appendingPathComponent("repo/nested")
        let oldIdentity = try XCTUnwrap(SandboxPathResolver.identity(of: nested))
        let oldDate = try XCTUnwrap(fm.attributesOfItem(atPath: nested.path)[.modificationDate] as? Date)
        // Keep the original directory alive so its inode cannot be recycled.
        try fm.moveItem(at: nested, to: root.appendingPathComponent("retired"))
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: nested.appendingPathComponent("entry"), withDestinationURL: backing)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: nested.path)
        XCTAssertNotEqual(SandboxPathResolver.identity(of: nested), oldIdentity)
        XCTAssertEqual(try denial("backing/session.json"), SessionRepositoryProtection.deniedMessage)
        XCTAssertNil(try denial("backing/unrelated.json"))
    }

    func testExternalRelayReplacementAndNestedReverseAliasAreRevalidated() throws {
        let fm = FileManager.default
        let external = fm.temporaryDirectory.appendingPathComponent("session-external-\(UUID().uuidString)")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: external) }
        let first = try seed("first/session.json")
        let second = try seed("second/session.json")
        let relay = external.appendingPathComponent("relay")
        try fm.createSymbolicLink(at: relay, withDestinationURL: first)
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: repo.appendingPathComponent("entry"), withDestinationURL: relay)
        try fm.createSymbolicLink(at: repo.appendingPathComponent("external"), withDestinationURL: external)
        _ = FileSessionStorage(directory: repo)
        XCTAssertNil(try denial("second/session.json"))
        let before = try XCTUnwrap(SandboxPathResolver.metadata(of: repo))
        try fm.removeItem(at: relay)
        try fm.createSymbolicLink(at: relay, withDestinationURL: second)
        XCTAssertEqual(SandboxPathResolver.metadata(of: repo), before)
        XCTAssertEqual(try denial("second/session.json"), SessionRepositoryProtection.deniedMessage)
        let third = try seed("third/session.json")
        try fm.createSymbolicLink(at: external.appendingPathComponent(".new-link"), withDestinationURL: third)
        XCTAssertEqual(try denial("third/session.json"), SessionRepositoryProtection.deniedMessage)
        XCTAssertNil(try denial("third/unrelated.txt"))
    }

    func testKnownDanglingAliasIsProtectedAndRevalidatedWhenTargetAppears() throws {
        _ = try seed("repo/ordinary.json")
        let future = root.appendingPathComponent("future")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("future"),
                                                   withDestinationURL: future)
        _ = FileSessionStorage(directory: repo)
        XCTAssertEqual(try denial("future/new.json"), SessionRepositoryProtection.deniedMessage)
        XCTAssertNil(try denial("ordinary.txt"))
        let backing = try seed("backing/session.json")
        try FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: future.appendingPathComponent("entry"),
                                                   withDestinationURL: backing)
        XCTAssertEqual(try denial("backing/session.json"), SessionRepositoryProtection.deniedMessage)
    }

    func testCyclicAliasFailsClosedAndRecoveryInvalidatesWarmCache() throws {
        _ = try seed("repo/ordinary.json")
        let repo = root.appendingPathComponent("repo")
        _ = FileSessionStorage(directory: repo)
        XCTAssertNil(try denial("ordinary.txt"))
        let link = repo.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: link)
        XCTAssertEqual(try denial("ordinary.txt"), SessionRepositoryProtection.unverifiedMessage)
        try FileManager.default.removeItem(at: link)
        XCTAssertNil(try denial("ordinary.txt"))
    }

    func testMoreThan4096SnapshotsAndTombstonesAllowOrdinaryWriters() async throws {
        let repo = root.appendingPathComponent("Documents/AppAgent/sessions")
        let trash = repo.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for index in 0...4096 {
            try Data("snapshot".utf8).write(to: repo.appendingPathComponent("\(index).json"))
            try Data().write(to: trash.appendingPathComponent("\(index).json.purged"))
        }
        _ = FileSessionStorage(directory: repo)
        // file_write/web_fetch/screenshot/skills all use this same mutation guard.
        for path in ["Documents/AppAgent/files/note.txt", "Documents/download.txt",
                     "Documents/AppAgentScreenshots/capture.png", "Documents/AppAgent/skills/new/SKILL.md"] {
            XCTAssertNil(try denial(path), path)
            XCTAssertNil(try denial(path), "warm: \(path)")
        }
        let output = try await FileWriteTool(sandboxRoot: root).execute(
            arguments: ["path": .string("ordinary.txt"), "content": .string("ok")],
            session: AISession(id: "large-repository", title: "Test")
        )
        guard case .json = output else { return XCTFail("Ordinary write rejected: \(output)") }
        let manager = SkillsManager(userSkillsURL: root.appendingPathComponent("Documents/AppAgent/skills"))
        try await manager.createSkill(name: "normal", content: "# test")
        try await manager.deleteSkill(name: "normal")
        XCTAssertEqual(try denial("Documents/AppAgent/sessions/trash/0.json.purged"),
                       SessionRepositoryProtection.deniedMessage)
    }

    func testFileWriteCannotOverwriteRepositoryEvenWithBroadWorkspace() async throws {
        let target = try seed("custom/history/trash/entry.json")
        _ = FileSessionStorage(directory: root.appendingPathComponent("custom/history"))
        let tool = FileWriteTool(sandboxRoot: root)
        let session = AISession(id: "file-test", title: "Test")
        let result = try await tool.execute(arguments: [
            "path": .string("custom/history/trash/entry.json"), "content": .string("erase")
        ], session: session)
        guard case .error = result else { return XCTFail("Expected repository denial: \(result)") }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        let normal = try await tool.execute(arguments: ["path": .string("ordinary.txt"), "content": .string("ok")],
                                            session: session)
        guard case .json = normal else { return XCTFail("Ordinary write rejected: \(normal)") }
    }

    func testIncompleteAliasScanFailsClosed() throws {
        _ = try seed("repo/trash/entry.json")
        _ = FileSessionStorage(directory: root.appendingPathComponent("repo"))
        let target = root.appendingPathComponent("ordinary.txt")
        XCTAssertEqual(SessionRepositoryProtection.mutationDenial(
            logical: target, resolved: target, sandboxRoot: root, scanBudget: 0
        ), SessionRepositoryProtection.unverifiedMessage)
    }

    func testSkillsRejectTraversalAndRepositoryOverlapWithoutBreakingNormalSkills() async throws {
        let skillsRoot = root.appendingPathComponent("skills")
        let manager = SkillsManager(userSkillsURL: skillsRoot)
        for name in ["../sessions", ".", "..", "nested/skill", "nested\\skill"] {
            do {
                try await manager.createSkill(name: name, content: "bad")
                XCTFail("Accepted invalid name: \(name)")
            } catch {}
            do {
                try await manager.deleteSkill(name: name)
                XCTFail("Accepted invalid delete: \(name)")
            } catch {}
        }
        do {
            try await manager.createSkill(name: "ok", content: "bad", category: "../repo")
            XCTFail("Accepted invalid category")
        } catch {}
        try await manager.createSkill(name: "normal", content: "# test", category: "dev")
        try await manager.deleteSkill(name: "normal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent("dev/normal").path))

        let protected = try seed("skills/protected/SKILL.md")
        _ = FileSessionStorage(directory: skillsRoot.appendingPathComponent("protected"))
        do {
            try await manager.deleteSkill(name: "protected")
            XCTFail("Deleted repository through skill manager")
        } catch {}
        do {
            try await manager.createSkill(name: "protected", content: "erase")
            XCTFail("Overwrote repository through skill manager")
        } catch {}
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "keep")
    }

    func testSkillSymlinkEscapeCannotWriteOrDeleteRepository() async throws {
        let target = try seed("repo/SKILL.md")
        let skills = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("escape"),
                                                  withDestinationURL: target.deletingLastPathComponent())
        let manager = SkillsManager(userSkillsURL: skills)
        do {
            try await manager.createSkill(name: "escape", content: "erase")
            XCTFail("Followed skill escape")
        } catch {}
        do {
            try await manager.deleteSkill(name: "escape")
            XCTFail("Deleted through skill escape")
        } catch {}
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
}
