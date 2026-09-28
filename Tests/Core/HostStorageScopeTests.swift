import XCTest
@testable import AppAgent

final class HostStorageScopeTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var retainedResponders: [Responder] = []

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-storage-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "host-storage-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        retainedResponders.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        if let base { try FileManager.default.removeItem(at: base) }
    }

    private final class Responder: DecisionResponder, @unchecked Sendable {
        @Locked private(set) var requests: [DecisionRequest] = []
        let outcome: DecisionOutcome
        init(_ outcome: DecisionOutcome) { self.outcome = outcome }
        func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
            requests.append(request)
            return outcome
        }
    }

    private func session(_ responder: Responder? = nil, readOnly: Bool = false) -> AISession {
        var profile = AIAgentProfile(identity: "Storage tests", registerBuiltInTools: false)
        if readOnly { profile.toolMutationPolicy = .readOnly }
        let session = AISession(
            id: UUID().uuidString, title: "Storage tests",
            agentMask: AIAgentMask(profile: profile, toolCentral: ToolCentral())
        )
        let registry = DecisionResponderCentral()
        if let responder {
            // The production registry intentionally holds responders weakly.
            retainedResponders.append(responder)
            registry.register(responder)
        }
        session.decisionResponders = registry
        return session
    }

    @discardableResult
    private func seed(_ path: String, content: String = "private SDK marker") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func link(_ path: String, to destination: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    private func file(
        _ op: String, _ path: String, scope: String? = nil, session: AISession? = nil
    ) async throws -> Tool.Output {
        var args: [String: JSONValue] = [
            "op": .string(op), "path": .string(path), "content": .string("replacement")
        ]
        if let scope { args["scope"] = .string(scope) }
        return try await AppSandboxFileTool(root: root).execute(
            arguments: args, session: session ?? self.session()
        )
    }

    private func json(_ output: Tool.Output, file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        guard case .json(let value) = output else {
            XCTFail("Expected JSON, got \(output)", file: file, line: line)
            return .null
        }
        return value
    }

    private func assertError(
        _ output: Tool.Output, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .error = output else {
            return XCTFail("Expected denial, got \(output)", file: file, line: line)
        }
    }

    private func assertSuccess(
        _ output: Tool.Output, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(json(output, file: file, line: line)["success"]?.boolValue, true,
                       file: file, line: line)
    }

    private func names(_ output: Tool.Output, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let value = json(output, file: file, line: line)
        let entries = value["entries"]?.arrayValue ?? []
        XCTAssertEqual(value["count"]?.numberValue, Double(entries.count), file: file, line: line)
        XCTAssertEqual(Set(value.objectValue?.keys.map { $0 } ?? []),
                       ["path", "count", "entries"], file: file, line: line)
        return entries.compactMap { $0["name"]?.stringValue }
    }

    func testDefaultsHostFiltersNamespacesAndBlocksReadWriteRemoveWithoutExistenceHints() async throws {
        let protected = [
            "com.appagent.endpointSettings", "com.appagent.ui.inputBar.wideExpandedWidth",
            "com.appagent.ui.inputBar.collapsedPlacementXY", "appagent.msgcapture.config.v1",
            "com.appagent.futureSetting", "appagent.futureSetting"
        ]
        for key in protected { defaults.set("private SDK marker", forKey: key) }
        defaults.set("host", forKey: "host.theme")
        defaults.set("host sibling", forKey: "com.appagentOther.setting")
        let tool = AppUserDefaultsTool(defaults: defaults)
        let session = session()
        let list = json(try await tool.execute(arguments: ["op": .string("list")], session: session))
        let keys = list["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(keys.contains("host.theme"))
        XCTAssertTrue(keys.contains("com.appagentOther.setting"))
        XCTAssertTrue(Set(keys).isDisjoint(with: protected))
        XCTAssertEqual(list["count"]?.numberValue, Double(keys.count))
        XCTAssertEqual(Set(list.objectValue?.keys.map { $0 } ?? []), ["keys", "count"])

        for key in protected + ["com.appagent.doesNotExist"] {
            for op in ["read", "write", "remove"] {
                let out = try await tool.execute(arguments: [
                    "op": .string(op), "key": .string(key), "value": .string("changed")
                ], session: session)
                guard case .error(let message) = out else { XCTFail("\(out)"); continue }
                XCTAssertEqual(message, HostStoragePolicy.deniedMessage)
            }
        }
        for key in protected { XCTAssertEqual(defaults.string(forKey: key), "private SDK marker") }
        XCTAssertNil(defaults.object(forKey: "com.appagent.doesNotExist"))
        let filtered = json(try await tool.execute(arguments: [
            "op": .string("list"), "prefix": .string("com.appagent.")
        ], session: session))
        XCTAssertEqual(filtered["count"]?.numberValue, 0)
    }

    func testDefaultsExplicitScopesNeedApprovalAndSelectOnlyTheirKeys() async throws {
        let key = "com.appagent.endpointSettings"
        defaults.set("private", forKey: key)
        defaults.set("host", forKey: "host.theme")
        let tool = AppUserDefaultsTool(defaults: defaults)
        for scope in ["appagent", "all"] {
            for blockedSession in [session(), session(Responder(.deny))] {
                for op in ["read", "write", "remove", "list"] {
                    assertError(try await tool.execute(arguments: [
                        "op": .string(op), "scope": .string(scope),
                        "key": .string(key), "value": .string("changed")
                    ], session: blockedSession))
                }
            }
        }
        XCTAssertEqual(defaults.string(forKey: key), "private")
        let responder = Responder(.allowOnce)
        let allowed = session(responder)
        let read = json(try await tool.execute(arguments: [
            "op": .string("read"), "scope": .string("appagent"), "key": .string(key)
        ], session: allowed))
        XCTAssertEqual(read["value"]?.stringValue, "private")
        assertError(try await tool.execute(arguments: [
            "op": .string("read"), "scope": .string("appagent"), "key": .string("host.theme")
        ], session: allowed))
        let sdkList = json(try await tool.execute(arguments: [
            "op": .string("list"), "scope": .string("appagent")
        ], session: allowed))
        let keys = sdkList["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(keys.contains(key))
        XCTAssertTrue(keys.allSatisfy(HostStoragePolicy.isAppAgentDefaultsKey))
        let allList = json(try await tool.execute(arguments: [
            "op": .string("list"), "scope": .string("all")
        ], session: allowed))
        XCTAssertTrue(allList["keys"]?.arrayValue?.contains(.string("host.theme")) == true)
        for scope in ["appagent", "all"] {
            let write = json(try await tool.execute(arguments: [
                "op": .string("write"), "scope": .string(scope),
                "key": .string(key), "value": .string("approved")
            ], session: allowed))
            XCTAssertEqual(write["success"]?.boolValue, true)
            let remove = json(try await tool.execute(arguments: [
                "op": .string("remove"), "scope": .string(scope), "key": .string(key)
            ], session: allowed))
            XCTAssertEqual(remove["success"]?.boolValue, true)
        }
        // An approved call must not widen a later default-scope call on the same tool.
        assertError(try await tool.execute(arguments: [
            "op": .string("read"), "key": .string(key)
        ], session: allowed))
        XCTAssertTrue(responder.requests.contains {
            if case .appAgentInspection(scope: .appagent, isMutation: true) = $0 { return true }
            return false
        })
    }

    func testHostHidesSDKFilesAndPreservesWorkspaceScreenshotsAndPrefixSiblings() async throws {
        let protected = [
            "Documents/AppAgent/sessions/session.json", "Documents/AppAgent/memory/memory.json",
            "Documents/AppAgent/logs/run.log", "Documents/AppAgent/skills/example/SKILL.md",
            "Documents/AppAgent/futureInternal/data", "Documents/AppAgent/files-private/secret",
            "Library/Caches/AppAgentMsgCapture/cap_test.jsonl", "Caches/AppAgentMsgCapture/data",
            "tmp/appagent-diagnostics-123.zip", "tmp/appagent-diagnostics-123/summary.txt",
            "tmp/appagent-debug.log", "tmp/appagent-debug.json", "tmp/AppAgent/logs/fallback.log",
            "tmp/AppAgentMsgCapture/fallback.jsonl"
        ]
        for path in protected {
            try seed(path)
            for op in ["read", "write", "delete"] {
                assertError(try await file(op, path))
            }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "private SDK marker")
        }
        for directory in ["Documents/AppAgent/sessions", "Library/Caches/AppAgentMsgCapture",
                          "tmp/appagent-diagnostics-123"] {
            assertError(try await file("list", directory))
        }
        let artifacts = [
            "Documents/AppAgent/files/note.txt", "Documents/AppAgentScreenshots/capture.png",
            "Documents/AppAgentOther/note.txt", "Library/Caches/AppAgentMsgCaptureOther/data",
            "tmp/ordinary.txt"
        ]
        for path in artifacts {
            let write = json(try await file("write", path))
            XCTAssertEqual(write["success"]?.boolValue, true)
            let read = json(try await file("read", path))
            XCTAssertEqual(read["content"]?.stringValue, "replacement")
        }
        let sdkContainer = names(try await file("list", "Documents/AppAgent"))
        XCTAssertEqual(sdkContainer, ["files"])
        let temporary = names(try await file("list", "tmp"))
        XCTAssertEqual(temporary, ["ordinary.txt"])
        let documents = names(try await file("list", "Documents"))
        XCTAssertEqual(documents, ["AppAgent", "AppAgentOther", "AppAgentScreenshots"])
        let work = names(try await file("list", "Documents/AppAgent/files"))
        XCTAssertEqual(work, ["note.txt"])
        for path in artifacts {
            let result = json(try await file("delete", path))
            XCTAssertEqual(result["success"]?.boolValue, true)
        }
    }

    func testFileScopesRequireApprovalAndAppAgentScopeExcludesHostArtifacts() async throws {
        try seed("Documents/AppAgent/memory/memory.json")
        try seed("Documents/AppAgent/files/work.txt", content: "work")
        try seed("Documents/host.txt", content: "host")
        for scope in ["appagent", "all"] {
            for blockedSession in [session(), session(Responder(.deny))] {
                for op in ["read", "write", "delete", "list"] {
                    assertError(try await file(op, "Documents/AppAgent/memory/memory.json",
                                               scope: scope, session: blockedSession))
                }
            }
        }
        let allowed = session(Responder(.allowOnce))
        let sdkRead = json(try await file("read", "Documents/AppAgent/memory/memory.json",
                                         scope: "appagent", session: allowed))
        XCTAssertEqual(sdkRead["content"]?.stringValue, "private SDK marker")
        for path in ["Documents/host.txt", "Documents/AppAgent/files/work.txt"] {
            for op in ["read", "write", "delete"] {
                assertError(try await file(op, path, scope: "appagent", session: allowed))
            }
        }
        let rootNames = names(try await file("list", "", scope: "appagent", session: allowed))
        XCTAssertEqual(rootNames, ["Documents"])
        let docsNames = names(try await file("list", "Documents", scope: "appagent", session: allowed))
        XCTAssertEqual(docsNames, ["AppAgent"])
        let sdkNames = names(try await file("list", "Documents/AppAgent",
                                           scope: "appagent", session: allowed))
        XCTAssertEqual(sdkNames, ["memory"])
        let allNames = names(try await file("list", "Documents/AppAgent", scope: "all", session: allowed))
        XCTAssertEqual(allNames, ["files", "memory"])
        for path in ["Documents/host.txt", "Documents/AppAgent/memory/memory.json"] {
            let read = json(try await file("read", path, scope: "all", session: allowed))
            XCTAssertNotNil(read["content"]?.stringValue)
            let write = json(try await file("write", path, scope: "all", session: allowed))
            XCTAssertEqual(write["success"]?.boolValue, true)
        }
        let deleted = json(try await file("delete", "Documents/AppAgent/memory",
                                         scope: "appagent", session: allowed))
        XCTAssertEqual(deleted["success"]?.boolValue, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents/host.txt").path))
    }

    func testSharedAncestorsCannotBeOverwrittenOrDeletedEvenWithAllApproval() async throws {
        try seed("Documents/AppAgent/sessions/private.json")
        try seed("Documents/AppAgent/files/work.txt")
        try seed("Library/Caches/AppAgentMsgCapture/private.jsonl")
        try seed("Library/Preferences/shared.plist")
        try seed("tmp/appagent-diagnostics-x.zip")
        try link("documents-alias", to: root.appendingPathComponent("Documents"))
        try link("root-alias", to: root)
        let allowed = session(Responder(.allowOnce))
        for scope in ["host", "appagent", "all"] {
            for path in ["", ".", "./", "Documents", "Documents/AppAgent", "Library",
                         "Library/Caches", "Library/Preferences", "Caches", "tmp", "temp",
                         "documents-alias", "root-alias"] {
                for op in ["write", "delete"] {
                    assertError(try await file(op, path, scope: scope, session: allowed))
                }
            }
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Documents/AppAgent/files/work.txt")),
                       "private SDK marker")
        // An ancestor may be navigated, but a file occupying that same name isn't exposed.
        let fake = base.appendingPathComponent("fake", isDirectory: true)
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("Documents"),
                                                withIntermediateDirectories: true)
        try "secret".write(to: fake.appendingPathComponent("Documents/AppAgent"),
                           atomically: true, encoding: .utf8)
        let out = try await AppSandboxFileTool(root: fake).execute(
            arguments: ["op": .string("list"), "path": .string("Documents")], session: session()
        )
        XCTAssertEqual(names(out), [])
    }

    func testSharedPreferencesRequireAllAndCannotBeBypassedWithAliases() async throws {
        let prefs = try seed("Library/Preferences/com.example.host.plist",
                             content: "<plist>host and SDK settings</plist>")
        try seed("Library/PreferencesOther/host.txt", content: "ordinary")
        try link("Documents/prefs.txt", to: prefs)
        try link("Documents/AppAgent/preferences-alias", to: prefs)
        let allowed = session(Responder(.allowOnce))
        for scope in ["host", "appagent"] {
            for path in ["Library/Preferences/com.example.host.plist", "Documents/prefs.txt",
                         "Documents/AppAgent/preferences-alias"] {
                for op in ["read", "write", "delete"] {
                    assertError(try await file(op, path, scope: scope, session: allowed))
                }
            }
            assertError(try await file("list", "Library/Preferences", scope: scope, session: allowed))
            let listing = names(try await file("list", "Library", scope: scope, session: allowed))
            XCTAssertFalse(listing.contains("Preferences"))
        }
        let ordinary = json(try await file("read", "Library/PreferencesOther/host.txt"))
        XCTAssertEqual(ordinary["content"]?.stringValue, "ordinary")
        let read = json(try await file("read", "Documents/prefs.txt", scope: "all", session: allowed))
        XCTAssertEqual(read["content"]?.stringValue, "<plist>host and SDK settings</plist>")
        let write = json(try await file("write", "Library/Preferences/com.example.host.plist",
                                        scope: "all", session: allowed))
        XCTAssertEqual(write["success"]?.boolValue, true)
    }

    func testSandboxChecksBothLogicalAndResolvedOwnershipAndRejectsEscapes() async throws {
        let secret = try seed("Documents/AppAgent/sessions/private.json")
        let artifact = try seed("Documents/AppAgent/files/ordinary.txt", content: "work")
        try seed("Documents/AppAgent/files/unshared.txt", content: "ordinary work artifact")
        try link("Documents/alias.txt", to: secret)
        try link("Documents/AppAgent/files/alias.txt", to: secret)
        try link("Documents/AppAgent/host-alias.txt", to: artifact)
        try link("Documents/secret-dir", to: secret.deletingLastPathComponent())
        let outside = base.appendingPathComponent("home-other", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try link("outside", to: outside)
        try link("missing-target", to: outside.appendingPathComponent("not-yet-created.txt"))
        let allowed = session(Responder(.allowOnce))
        for path in ["Documents/alias.txt", "Documents/AppAgent/files/alias.txt",
                     "Documents/AppAgent/host-alias.txt", "Documents/secret-dir/private.json",
                     "Documents/secret-dir/new.json"] {
            for op in ["read", "write", "delete"] { assertError(try await file(op, path)) }
        }
        // Logical SDK name resolving to a host artifact must not grant SDK-only access either.
        assertError(try await file("read", "Documents/AppAgent/host-alias.txt",
                                   scope: "appagent", session: allowed))
        for scope in ["host", "appagent", "all"] {
            for path in ["/etc/passwd", "../home-other/secret.txt", "Documents/../../home-other/secret.txt",
                         "..\\home-other\\secret.txt", "outside/secret.txt", "outside/new/child.txt",
                         "missing-target", root.path] {
                for op in ["read", "write", "delete"] {
                    assertError(try await file(op, path, scope: scope, session: allowed))
                }
            }
            assertError(try await file("list", "outside", scope: scope, session: allowed))
        }
        let docs = names(try await file("list", "Documents"))
        XCTAssertEqual(docs, ["AppAgent"])
        let workspace = names(try await file("list", "Documents/AppAgent/files"))
        // ordinary.txt is now ALSO referenced by a protected SDK link: it is
        // mixed storage and cannot be laundered through the workspace exemption.
        XCTAssertEqual(workspace, ["unshared.txt"])
        assertError(try await file("read", "Documents/AppAgent/files/ordinary.txt"))
        let read = json(try await file("read", "Documents/alias.txt", scope: "all", session: allowed))
        XCTAssertEqual(read["content"]?.stringValue, "private SDK marker")
        assertError(try await file("read", "Documents/alias.txt", session: allowed))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret.txt")), "outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("not-yet-created.txt").path))
    }

    func testGenericWorkspaceToolsEnforceCanonicalContainmentForEverySearchEntry() async throws {
        let workspace = root.appendingPathComponent("Documents/AppAgent/files", isDirectory: true)
        try seed("Documents/AppAgent/files/ordinary.txt", content: "needle safe")
        let secret = try seed("Documents/AppAgent/files-private/secret.txt", content: "needle private")
        try link("Documents/AppAgent/files/escape.txt", to: secret)
        try link("Documents/AppAgent/files/escape-dir", to: secret.deletingLastPathComponent())
        try link("Documents/AppAgent/files/missing.txt",
                 to: secret.deletingLastPathComponent().appendingPathComponent("new.txt"))
        try link("workspace-alias", to: workspace)
        let linkedRoot = root.appendingPathComponent("workspace-alias")
        let session = session()
        for configuredRoot in [workspace, linkedRoot] {
            let resolver = SandboxPathResolver(sandboxRoot: configuredRoot)
            // Foundation sometimes shortens /private/var back to /var on macOS.
            XCTAssertEqual(resolver.resolve(".")?.resolvingSymlinksInPath().path,
                           workspace.resolvingSymlinksInPath().path)
            for path in ["../files-private/secret.txt", secret.path, "/etc/passwd", "..\\files-private\\secret.txt",
                         "escape.txt", "escape-dir/secret.txt", "escape-dir/new-dir/new.txt", "missing.txt"] {
                XCTAssertNil(resolver.resolve(path), path)
                assertError(try await FileReadTool(sandboxRoot: configuredRoot).execute(
                    arguments: ["path": .string(path)], session: session
                ))
                assertError(try await FileWriteTool(sandboxRoot: configuredRoot).execute(
                    arguments: ["path": .string(path), "content": .string("changed")], session: session
                ))
            }
            let search = FileSearchTool(sandboxRoot: configuredRoot)
            let filenames = json(try await search.execute(
                arguments: ["pattern": .string("*"), "target": .string("files")], session: session
            ))
            XCTAssertEqual(filenames["matches"]?.arrayValue, [.string("ordinary.txt")])
            let content = json(try await search.execute(
                arguments: ["pattern": .string("needle"), "target": .string("content")], session: session
            ))
            XCTAssertEqual(content["count"]?.numberValue, 1)
            XCTAssertEqual(content["matches"]?.arrayValue?.first?["file"]?.stringValue, "ordinary.txt")
            XCTAssertEqual(content["matches"]?.arrayValue?.first?["content"]?.stringValue, "needle safe")
        }
        let write = json(try await FileWriteTool(sandboxRoot: linkedRoot).execute(
            arguments: ["path": .string("nested/new.txt"), "content": .string("created")], session: session
        ))
        XCTAssertEqual(write["success"]?.boolValue, true)
        let read = json(try await FileReadTool(sandboxRoot: workspace).execute(
            arguments: ["path": .string("nested/new.txt")], session: session
        ))
        XCTAssertEqual(read["content"]?.stringValue, "1|created")
        XCTAssertEqual(try String(contentsOf: secret), "needle private")
    }

    func testRelativeSymlinksRemainScopedAndDeletingAllowedLinkPreservesItsTarget() async throws {
        let artifact = try seed("Documents/AppAgent/files/ordinary.txt", content: "work")
        try seed("Documents/AppAgent/sessions/private.json")
        let fm = FileManager.default
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("Documents/work-link").path,
            withDestinationPath: "AppAgent/files"
        )
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("Documents/AppAgent/files/protected-link").path,
            withDestinationPath: "../sessions"
        )
        let read = json(try await file("read", "Documents/work-link/ordinary.txt"))
        XCTAssertEqual(read["content"]?.stringValue, "work")
        assertError(try await file("write", "Documents/AppAgent/files/protected-link/new.json"))
        let removed = json(try await file("delete", "Documents/work-link"))
        XCTAssertEqual(removed["success"]?.boolValue, true)
        XCTAssertEqual(try String(contentsOf: artifact), "work")
        XCTAssertThrowsError(try fm.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("Documents/work-link").path
        ))
    }

    func testSymlinkCyclesFailClosedForEveryScopeAndWorkspaceSearch() async throws {
        let workspace = root.appendingPathComponent("Documents/AppAgent/files", isDirectory: true)
        try seed("Documents/AppAgent/files/ordinary.txt", content: "work")
        try link("Documents/AppAgent/files/loop-a", to: workspace.appendingPathComponent("loop-b"))
        try link("Documents/AppAgent/files/loop-b", to: workspace.appendingPathComponent("loop-a"))
        let resolver = SandboxPathResolver(sandboxRoot: workspace)
        XCTAssertNil(resolver.resolve("loop-a"))
        XCTAssertNil(resolver.resolve("loop-a/child.txt"))
        let allowed = session(Responder(.allowOnce))
        for scope in ["host", "appagent", "all"] {
            for op in ["list", "read", "write", "delete"] {
                assertError(try await file(op, "Documents/AppAgent/files/loop-a",
                                           scope: scope, session: allowed))
            }
        }
        let matches = json(try await FileSearchTool(sandboxRoot: workspace).execute(
            arguments: ["pattern": .string("*"), "target": .string("files")], session: allowed
        ))
        XCTAssertEqual(matches["matches"]?.arrayValue, [.string("ordinary.txt")])
    }

    func testRelocatedProtectedNamespacesCannotBeReadOrDeletedViaTheirBackingPaths() async throws {
        let prefs = try seed("backing/preferences/shared.plist", content: "mixed settings")
        let secret = try seed("backing/session-store/private.json")
        try link("Library/Preferences", to: prefs.deletingLastPathComponent())
        try link("Documents/AppAgent/sessions", to: secret.deletingLastPathComponent())
        for path in ["backing/preferences/shared.plist", "backing/session-store/private.json"] {
            for op in ["read", "write", "delete"] {
                assertError(try await file(op, path))
            }
        }
        for path in ["backing", "backing/preferences", "backing/session-store"] {
            assertError(try await file("delete", path))
        }
        let listing = names(try await file("list", "backing"))
        XCTAssertEqual(listing, [])
        XCTAssertEqual(try String(contentsOf: prefs), "mixed settings")
        XCTAssertEqual(try String(contentsOf: secret), "private SDK marker")
    }

    func testCaseVariantBackingPathsCannotBypassNamespaceOrAncestorProtection() async throws {
        let secretPath = "backing/session-store/private.json"
        let secret = try seed(secretPath)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("BACKING/session-store/private.json").path) else {
            throw XCTSkip("Requires a case-insensitive filesystem to exercise the alias.")
        }
        try link("Documents/AppAgent/sessions", to: secret.deletingLastPathComponent())
        let listing = names(try await file("list", "BACKING"))
        XCTAssertEqual(listing, [])
        assertError(try await file("list", "BACKING/SESSION-STORE"))
        for op in ["read", "write", "delete"] {
            try seed(secretPath)
            assertError(try await file(op, "BACKING/session-store/PRIVATE.json"))
        }
        try seed(secretPath)
        assertError(try await file("write", "BACKING/session-store/new.json"))
        assertError(try await file("delete", "BACKING"))
        // Missing tails cannot rely on the target's inode yet.
        try link("Documents/AppAgent/futureInternal/missing",
                 to: root.appendingPathComponent("backing/not-created/item.json"))
        assertError(try await file("write", "BACKING/NOT-CREATED/ITEM.json"))
        assertError(try await file("write", "DOCUMENTS/APPAGENT/LOGS/NEW.LOG"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("backing/not-created").path
        ))
        XCTAssertEqual(try String(contentsOf: secret), "private SDK marker")
    }

    func testCaseSensitiveFilesystemKeepsDistinctBackingAndLogicalNamesIndependent() async throws {
        guard SandboxPathResolver.caseSensitiveNames(in: root) == true else {
            throw XCTSkip("Requires a case-sensitive filesystem; do not simulate it by lowercasing.")
        }
        let secret = try seed("backing/session-store/private.json")
        let unrelated = try seed("BACKING/session-store/private.json", content: "host data")
        try link("Documents/AppAgent/sessions", to: secret.deletingLastPathComponent())
        try link("Documents/AppAgent/futureInternal/missing",
                 to: root.appendingPathComponent("backing/not-created/item.json"))
        XCTAssertNotEqual(SandboxPathResolver.identity(of: secret),
                          SandboxPathResolver.identity(of: unrelated))
        XCTAssertFalse(SandboxPathResolver.samePath(secret, unrelated))
        XCTAssertFalse(SandboxPathResolver.contains(
            unrelated, in: secret.deletingLastPathComponent()
        ))
        let listing = names(try await file("list", "BACKING/session-store"))
        XCTAssertEqual(listing, ["private.json"])
        let hostRead = json(try await file("read", "BACKING/session-store/private.json"))
        XCTAssertEqual(hostRead["content"]?.stringValue, "host data")
        let independent = [
            "BACKING/session-store/private.json", "BACKING/not-created/item.json",
            "documents/appagent/sessions/private.json", "tmp/APPAGENT-DIAGNOSTICS-X.zip"
        ]
        for path in independent {
            assertSuccess(try await file("write", path))
            let read = json(try await file("read", path))
            XCTAssertEqual(read["content"]?.stringValue, "replacement")
            assertSuccess(try await file("delete", path))
        }
        assertSuccess(try await file("delete", "BACKING"))
        assertError(try await file("read", "backing/session-store/private.json"))
        assertError(try await file("write", "backing/not-created/item.json"))
        assertError(try await file("delete", "backing"))
        XCTAssertEqual(try String(contentsOf: secret), "private SDK marker")
    }

    func testProtectedSingleFileAndDynamicExportLinksProtectPhysicalTargetsAndAncestors() async throws {
        let aliases = [
            ("Library/Preferences/com.example.plist", "backing/prefs/prefs.plist"),
            ("Documents/AppAgent/sessions/one.json", "backing/session/one.json"),
            ("Documents/AppAgent/futureInternal/secret.txt", "backing/future/secret.txt"),
            ("tmp/appagent-diagnostics-X.zip", "backing/export/export.zip"),
            ("tmp/appagent-diagnostics-Y/nested/secret.txt", "backing/nested/secret.txt")
        ]
        let approved = session(Responder(.allowOnce))
        let denied = session(Responder(.deny))
        for (logical, physical) in aliases {
            let target = try seed(physical)
            try link(logical, to: target)
            let parent = (physical as NSString).deletingLastPathComponent
            let listing = names(try await file("list", parent))
            XCTAssertEqual(listing, [], logical)
            for op in ["read", "write", "delete"] {
                try seed(physical)
                assertError(try await file(op, physical))
            }
            try seed(physical)
            assertError(try await file("delete", parent))
            assertError(try await file("read", physical, scope: "all", session: denied))
            assertError(try await file("write", physical, scope: "all", session: denied))
            for op in ["read", "write", "delete"] {
                // A host-looking physical name overlapping SDK/preferences storage
                // is mixed storage, not permission to widen SDK-only inspection.
                assertError(try await file(op, physical, scope: "appagent", session: approved))
            }
            let allListing = names(try await file("list", parent, scope: "all", session: approved))
            XCTAssertEqual(allListing, [target.lastPathComponent])
            let allRead = json(try await file("read", physical, scope: "all", session: approved))
            XCTAssertEqual(allRead["content"]?.stringValue, "private SDK marker")
            if logical.hasPrefix("Documents/AppAgent/sessions/") {
                // Session history is only mutable via recoverable session management,
                // even after SDK/all inspection has been explicitly approved.
                assertError(try await file("write", physical, scope: "all", session: approved))
                assertError(try await file("delete", physical, scope: "all", session: approved))
                assertError(try await file("delete", parent, scope: "all", session: approved))
                XCTAssertEqual(try String(contentsOf: target), "private SDK marker")
                continue
            }
            assertSuccess(try await file("write", physical, scope: "all", session: approved))
            XCTAssertEqual(try String(contentsOf: target), "replacement")
            // Approval does not permit bulk removal of a protected target's ancestor.
            assertError(try await file("delete", parent, scope: "all", session: approved))
            assertSuccess(try await file("delete", physical, scope: "all", session: approved))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try seed(physical)
        }
        // Recreate targets after attempted destructive operations so this checks
        // the common physical ancestor too, even on the vulnerable implementation.
        for (_, physical) in aliases { try seed(physical) }
        assertError(try await file("delete", "backing"))
        assertError(try await file("delete", "backing", scope: "all", session: approved))
    }

    func testProtectedDirectoryLinksIndexNestedHiddenAndDanglingAliases() async throws {
        let export = try seed("backing/export-dir/private.json")
        let hidden = try seed("backing/hidden/secret.txt")
        let nested = try seed("backing/nested/secret.txt")
        try link("backing/export-dir/.hidden-link", to: hidden)
        try link("backing/export-dir/nested-link", to: nested)
        try link("backing/export-dir/loop", to: export.deletingLastPathComponent())
        try link("tmp/appagent-diagnostics-relocated", to: export.deletingLastPathComponent())
        try link("Library/Preferences/com.example.plist",
                 to: root.appendingPathComponent("backing/future/prefs.plist"))
        for path in ["backing/export-dir/private.json", "backing/hidden/secret.txt",
                     "backing/nested/secret.txt", "backing/future/prefs.plist"] {
            for op in ["read", "write", "delete"] {
                assertError(try await file(op, path))
            }
        }
        assertError(try await file("list", "backing/export-dir"))
        let hiddenNames = names(try await file("list", "backing/hidden"))
        let nestedNames = names(try await file("list", "backing/nested"))
        XCTAssertEqual(hiddenNames, [])
        XCTAssertEqual(nestedNames, [])
        for path in ["backing", "backing/export-dir", "backing/hidden", "backing/nested", "backing/future"] {
            for op in ["write", "delete"] { assertError(try await file(op, path)) }
        }
        XCTAssertEqual(try String(contentsOf: export), "private SDK marker")
        XCTAssertEqual(try String(contentsOf: hidden), "private SDK marker")
        XCTAssertEqual(try String(contentsOf: nested), "private SDK marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backing/future").path))
        let approved = session(Responder(.allowOnce))
        assertSuccess(try await file("write", "backing/future/prefs.plist",
                                    scope: "all", session: approved))
        assertError(try await file("read", "backing/future/prefs.plist"))
    }

    func testAliasScanBudgetExhaustionFailsClosedForEveryOperationAndScope() throws {
        try seed("Documents/host.txt", content: "host")
        for index in 0..<12 {
            try seed("Documents/AppAgent/sessions/shard-\(index)/entry.json")
        }
        let paths = try XCTUnwrap(SandboxPathResolver(sandboxRoot: root).paths(for: "Documents/host.txt"))
        for budget in [0, 3] {
            let policy = HostStoragePolicy(root: root, scanBudget: budget)
            XCTAssertEqual(policy.scannedEntryCount, budget)
            for scope in [HostInspectionScope.host, .appagent, .all] {
                for operation in [HostStoragePolicy.Operation.list, .read, .write, .delete] {
                    XCTAssertEqual(policy.denial(logical: paths.logical, resolved: paths.resolved,
                                                  scope: scope, operation: operation),
                                   HostStoragePolicy.unverifiedMessage)
                }
            }
        }
        XCTAssertEqual(try String(contentsOf: paths.resolved), "host")
    }

    func testLargeRepositoryReusesTopologyCacheWithoutBlockingHostOperations() async throws {
        let repo = root.appendingPathComponent("Documents/AppAgent/sessions")
        let trash = repo.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for index in 0...4096 {
            try Data("snapshot".utf8).write(to: repo.appendingPathComponent("\(index).json"))
            try Data().write(to: trash.appendingPathComponent("\(index).json.purged"))
        }
        try seed("Documents/host.txt", content: "host")
        let resolver = SandboxPathResolver(sandboxRoot: root)
        let host = try XCTUnwrap(resolver.paths(for: "Documents/host.txt"))
        let cold = HostStoragePolicy(root: root, scanBudget: 8)
        XCTAssertGreaterThan(cold.enumeratedEntryCount, 8192)
        XCTAssertLessThan(cold.scannedEntryCount, 8)
        let warm = HostStoragePolicy(root: root, scanBudget: 8)
        XCTAssertEqual(warm.enumeratedEntryCount, 0)
        XCTAssertEqual(warm.scannedEntryCount, cold.scannedEntryCount)
        for policy in [cold, warm] {
            for operation in [HostStoragePolicy.Operation.list, .read, .write, .delete] {
                XCTAssertNil(policy.denial(logical: host.logical, resolved: host.resolved,
                                           scope: .host, operation: operation))
            }
            let protected = try XCTUnwrap(resolver.paths(for: "Documents/AppAgent/sessions/trash/0.json.purged"))
            XCTAssertNotNil(policy.denial(logical: protected.logical, resolved: protected.resolved,
                                         scope: .all, operation: .write))
        }
        assertSuccess(try await file("write", "Documents/host.txt"))
        assertSuccess(try await file("delete", "Documents/host.txt"))
    }

    func testWarmScopeIndexRevalidatesNestedAliasesAndExternalRelayReplacement() throws {
        let fm = FileManager.default
        let nested = root.appendingPathComponent("Documents/AppAgent/logs/nested")
        try seed("Documents/AppAgent/logs/nested/entry")
        let first = try seed("backing/first.txt")
        let second = try seed("backing/second.txt")
        let relay = base.appendingPathComponent("external-relay")
        try fm.createSymbolicLink(at: relay, withDestinationURL: first)
        let resolver = SandboxPathResolver(sandboxRoot: root)
        func readDenial(_ path: String) throws -> String? {
            let paths = try XCTUnwrap(resolver.paths(for: path))
            return HostStoragePolicy(root: root).denial(
                logical: paths.logical, resolved: paths.resolved, scope: .host, operation: .read
            )
        }
        XCTAssertNil(try readDenial("backing/first.txt"))
        XCTAssertEqual(HostStoragePolicy(root: root).enumeratedEntryCount, 0)
        let oldDate = try XCTUnwrap(fm.attributesOfItem(atPath: nested.path)[.modificationDate] as? Date)
        let entry = nested.appendingPathComponent("entry")
        try fm.removeItem(at: entry)
        try fm.createSymbolicLink(at: entry, withDestinationURL: relay)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: nested.path)
        XCTAssertEqual(try readDenial("backing/first.txt"), HostStoragePolicy.deniedMessage)
        XCTAssertNil(try readDenial("backing/second.txt"))
        let before = try XCTUnwrap(SandboxPathResolver.metadata(of: nested))
        try fm.removeItem(at: relay)
        try fm.createSymbolicLink(at: relay, withDestinationURL: second)
        XCTAssertEqual(SandboxPathResolver.metadata(of: nested), before)
        XCTAssertEqual(try readDenial("backing/second.txt"), HostStoragePolicy.deniedMessage)

        let cycle = nested.appendingPathComponent("cycle")
        try fm.createSymbolicLink(at: cycle, withDestinationURL: cycle)
        XCTAssertEqual(try readDenial("backing/unrelated.txt"), HostStoragePolicy.unverifiedMessage)
        try fm.removeItem(at: cycle)
        XCTAssertNil(try readDenial("backing/unrelated.txt"))
    }

    func testAliasSnapshotDoesNotTraverseWorkspaceScreenshotsOrOrdinaryHostTrees() async throws {
        try seed("Documents/AppAgent/sessions/private.json")
        let ordinaryTrees = [
            "Documents/AppAgent/files", "Documents/AppAgentScreenshots",
            "Documents/host-tree", "tmp/ordinary-tree"
        ]
        for directory in ordinaryTrees { try seed(directory + "/first.txt", content: "host") }
        let baseline = HostStoragePolicy(root: root, scanBudget: 8)
        let resolver = SandboxPathResolver(sandboxRoot: root)
        let first = try XCTUnwrap(resolver.paths(for: "Documents/AppAgent/files/first.txt"))
        XCTAssertNil(baseline.denial(logical: first.logical, resolved: first.resolved,
                                    scope: .host, operation: .read))
        for directory in ordinaryTrees {
            for index in 0..<24 { try seed(directory + "/nested/\(index).txt", content: "host") }
            // Unrelated cycles would make the snapshot incomplete if traversed.
            try link(directory + "/cycle-a", to: root.appendingPathComponent(directory + "/cycle-b"))
            try link(directory + "/cycle-b", to: root.appendingPathComponent(directory + "/cycle-a"))
        }
        let snapshot = HostStoragePolicy(root: root, scanBudget: 8)
        XCTAssertEqual(snapshot.scannedEntryCount, baseline.scannedEntryCount)
        XCTAssertLessThan(snapshot.scannedEntryCount, 8)
        for directory in ordinaryTrees {
            for index in 0..<24 {
                let paths = try XCTUnwrap(resolver.paths(for: directory + "/nested/\(index).txt"))
                XCTAssertNil(snapshot.denial(logical: paths.logical, resolved: paths.resolved,
                                            scope: .host, operation: .list))
            }
            let listing = names(try await file("list", directory))
            XCTAssertEqual(listing, ["first.txt", "nested"])
            assertSuccess(try await file("write", directory + "/new.txt"))
            assertSuccess(try await file("delete", directory + "/new.txt"))
        }
        XCTAssertEqual(snapshot.scannedEntryCount, baseline.scannedEntryCount)
    }

    func testReadOnlyAndInvalidScopesFailBeforeAnyStorageMutation() async throws {
        try seed("Documents/host.txt", content: "host")
        try seed("Documents/AppAgent/sessions/private.json")
        defaults.set("host", forKey: "host.theme")
        defaults.set("SDK", forKey: "com.appagent.endpointSettings")
        let responder = Responder(.allowOnce)
        let readOnly = session(responder, readOnly: true)
        for scope in ["host", "appagent", "all"] {
            for path in ["Documents/host.txt", "Documents/AppAgent/sessions/private.json"] {
                for op in ["write", "delete"] {
                    assertError(try await file(op, path, scope: scope, session: readOnly))
                }
            }
            for key in ["host.theme", "com.appagent.endpointSettings"] {
                for op in ["write", "remove"] {
                    assertError(try await AppUserDefaultsTool(defaults: defaults).execute(arguments: [
                        "op": .string(op), "key": .string(key), "value": .string("changed"),
                        "scope": .string(scope)
                    ], session: readOnly))
                }
            }
        }
        XCTAssertTrue(responder.requests.isEmpty)
        for invalid in [JSONValue.string("everything"), .bool(true), .null] {
            assertError(try await AppUserDefaultsTool(defaults: defaults).execute(
                arguments: ["op": .string("list"), "scope": invalid], session: session(responder)
            ))
            assertError(try await AppSandboxFileTool(root: root).execute(
                arguments: ["op": .string("list"), "scope": invalid], session: session(responder)
            ))
        }
        XCTAssertTrue(responder.requests.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "host.theme"), "host")
        XCTAssertEqual(defaults.string(forKey: "com.appagent.endpointSettings"), "SDK")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Documents/host.txt")), "host")
    }
}
