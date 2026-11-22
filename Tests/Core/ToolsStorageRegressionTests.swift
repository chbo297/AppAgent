import XCTest
@testable import AppAgent

final class ToolsStorageRegressionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-storage-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertError(_ output: Tool.Output, parameter: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .error(let message) = output else {
            return XCTFail("Expected invalid \(parameter) to fail, got \(output)", file: file, line: line)
        }
        XCTAssertTrue(message.contains(parameter), message, file: file, line: line)
    }

    private func fileTool(_ root: URL) -> FileTool {
        FileTool(registry: FileResourceRegistry(agentWorkspaceURL: root))
    }

    private func fileArguments(
        op: String,
        path: String = ".",
        extra: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var arguments = extra
        arguments["op"] = .string(op)
        arguments["uri"] = .string("agent://workspace/" + path)
        return arguments
    }

    func testFractionalToolLimitsAreRejectedBeforeIO() async throws {
        let root = try temporaryDirectory()
        try "one\ntwo".write(to: root.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        let session = AISession(id: UUID().uuidString)
        assertError(try await fileTool(root).execute(
            arguments: fileArguments(
                op: "read",
                path: "test.txt",
                extra: ["limit": .number(1.5)]
            ),
            session: session
        ), parameter: "limit")
        assertError(try await fileTool(root).execute(
            arguments: fileArguments(
                op: "search",
                extra: ["pattern": .string("one"), "limit": .number(1.5)]
            ),
            session: session
        ), parameter: "limit")
        assertError(try await WebSearchTool().execute(
            arguments: ["query": .string("test"), "limit": .number(1.5)], session: session), parameter: "limit")
        assertError(try await WebFetchTool().execute(
            arguments: ["url": .string("file:///unreachable"), "max_bytes": .number(512.5)], session: session), parameter: "max_bytes")
    }

    func testFilenameSearchHonorsAllAdvertisedGlobWildcards() async throws {
        let root = try temporaryDirectory()
        for name in ["report-1-final.txt", "report-23-final.txt", "report-1-draft.txt"] {
            try "test".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let output = try await fileTool(root).execute(
            arguments: fileArguments(
                op: "search",
                extra: [
                    "pattern": .string("report-?-*.txt"),
                    "target": .string("files")
                ]
            ),
            session: AISession(id: UUID().uuidString)
        )
        guard case .json(let result) = output else { return XCTFail("Expected search results") }
        let matches = Set(result["matches"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        XCTAssertEqual(matches, ["agent://workspace/report-1-final.txt", "agent://workspace/report-1-draft.txt"])
    }

    func testToolIntegerArgumentsRejectUnrepresentableAndOutOfRangeValues() async throws {
        let root = try temporaryDirectory()
        try "one".write(to: root.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        let session = AISession(id: UUID().uuidString)
        for value: JSONValue in [.number(.infinity), .number(.nan), .number(.greatestFiniteMagnitude),
                                  .number(-1), .number(0), .string("5")] {
            assertError(try await fileTool(root).execute(
                arguments: fileArguments(
                    op: "read",
                    path: "test.txt",
                    extra: ["limit": value]
                ),
                session: session
            ), parameter: "limit")
            assertError(try await fileTool(root).execute(
                arguments: fileArguments(
                    op: "search",
                    extra: ["pattern": .string("one"), "limit": value]
                ),
                session: session
            ), parameter: "limit")
            assertError(try await WebSearchTool().execute(
                arguments: ["query": .string("test"), "limit": value], session: session), parameter: "limit")
            assertError(try await WebFetchTool().execute(
                arguments: ["url": .string("file:///unreachable"), "max_bytes": value], session: session), parameter: "max_bytes")
        }
        let output = try await fileTool(root).execute(
            arguments: fileArguments(
                op: "read",
                path: "test.txt",
                extra: [
                    "offset": .number(Double(Int.max) - 1024),
                    "limit": .number(2000)
                ]
            ),
            session: session
        )
        guard case .json(let result) = output else { return XCTFail("Expected empty page for large offset") }
        XCTAssertEqual(result["content"]?.stringValue, "")
    }

    func testPrivateHostDetectionIncludesIPv6AndAlternateIPv4Literals() {
        for host in ["LOCALHOST", "localhost.", "printer.local.", "127.1", "2130706433", "0x7f000001",
                     "0177.0.0.1", "::", "[fc00::1]", "fd12:3456::1", "fe80::1%en0", "::ffff:127.0.0.1",
                     "::ffff:a00:1", "0:0:0:0:0:0:0:1"] {
            XCTAssertTrue(WebFetchTool.isPrivateHost(host), "Expected private host: \(host)")
        }
        for host in ["example.com", "2606:4700:4700::1111", "8.8.8.8", "172.32.1.2"] {
            XCTAssertFalse(WebFetchTool.isPrivateHost(host), "Expected public host: \(host)")
        }
    }

    func testWebClippingDoesNotCreateBrokenUTF8Characters() {
        let clipped = WebFetchTool.clip("中文中文", maxBytes: 4)
        XCTAssertTrue(clipped.truncated)
        XCTAssertTrue(clipped.text.hasPrefix("中\n"), clipped.text)
        XCTAssertFalse(clipped.text.contains("\u{FFFD}"), clipped.text)
    }

    private final class RedirectProtocol: URLProtocol, @unchecked Sendable {
        static let requestedHosts = Locked(wrappedValue: [String]())
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url else { return }
            Self.requestedHosts.mutate { $0.append(url.host ?? "") }
            let redirect = url.host == "redirect.example" || url.host == "public-redirect.example" || url.host == "loop.example"
            let location = url.host == "redirect.example" ? "http://10.0.0.1/private"
                : url.host == "loop.example" ? url.absoluteString : "https://public.example/done"
            let response = HTTPURLResponse(url: url, statusCode: redirect ? 302 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: redirect
                                           ? ["Location": location] : ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !redirect { client?.urlProtocol(self, didLoad: Data("private data".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testRedirectToPrivateHostIsAuthorizedBeforeRequest() async throws {
        RedirectProtocol.requestedHosts.wrappedValue = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let session = AISession(id: UUID().uuidString)
        session.decisionResponders = DecisionResponderCentral()
        let output = try await WebFetchTool(session: transport).execute(arguments: [
            "url": .string("https://redirect.example/start")
        ], session: session)
        assertError(output, parameter: "denied")
        XCTAssertEqual(RedirectProtocol.requestedHosts.wrappedValue, ["redirect.example"])
    }

    func testPublicRedirectsStillWorkAndRedirectLoopsAreBounded() async throws {
        RedirectProtocol.requestedHosts.wrappedValue = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let session = AISession(id: UUID().uuidString)
        let tool = WebFetchTool(session: transport)
        let output = try await tool.execute(arguments: ["url": .string("https://public-redirect.example/start")], session: session)
        guard case .json(let result) = output else { return XCTFail("Expected public redirect to finish") }
        XCTAssertEqual(result["final_url"]?.stringValue, "https://public.example/done")
        XCTAssertEqual(RedirectProtocol.requestedHosts.wrappedValue, ["public-redirect.example", "public.example"])
        let loop = try await tool.execute(arguments: ["url": .string("https://loop.example/start")], session: session)
        guard case .error = loop else { return XCTFail("Expected redirect loop rejection") }
        XCTAssertEqual(RedirectProtocol.requestedHosts.wrappedValue.filter { $0 == "loop.example" }.count, 21)
    }

    func testSkillFrontmatterOnlyEndsAtDelimiterLine() async throws {
        let manager = SkillsManager(userSkillsURL: try temporaryDirectory())
        let body = "# Instructions\nKeep the body---including inline dashes."
        try await manager.createSkill(name: "sample", content: """
        ---
        name: sample
        description: Before---after
        category: dev
        ---
        \(body)
        """)
        let skill = await manager.skill(named: "sample")
        XCTAssertEqual(skill?.description, "Before---after")
        XCTAssertEqual(skill?.category, "dev")
        XCTAssertEqual(skill?.content, body)
    }

    func testSkillFrontmatterPreservesCRLFBodyAndAcceptsQuotedMetadata() async throws {
        let manager = SkillsManager(userSkillsURL: try temporaryDirectory())
        let body = "# Instructions\r\nLine two"
        try await manager.createSkill(name: "sample", content:
            "---\r\nname: \"sample\"\r\ndescription: 'A skill'\r\n---\r\n" + body)
        let skill = await manager.skill(named: "sample")
        XCTAssertEqual(skill?.name, "sample")
        XCTAssertEqual(skill?.description, "A skill")
        XCTAssertEqual(skill?.content, body)
    }

    private actor DelayedMemoryStorage: MemoryStorage {
        private var entries: [MemoryEntry] = []
        private var pending: CheckedContinuation<Void, Never>?
        private var began = false
        func loadAll() async throws -> [MemoryEntry] {
            let snapshot = entries
            if !began {
                began = true
                await withCheckedContinuation { pending = $0 }
            }
            return snapshot
        }
        func waitUntilLoading() async {
            while !began { await Task.yield() }
        }
        func finishLoading() { pending?.resume(); pending = nil }
        func save(_ entries: [MemoryEntry]) async throws { self.entries = entries }
        func append(_ entry: MemoryEntry) async throws { entries.append(entry) }
        func remove(id: String) async throws -> Bool {
            let before = entries.count
            entries.removeAll { $0.id == id }
            return before != entries.count
        }
    }

    func testInFlightMemoryReadCannotReinstallCacheBeforeMutation() async throws {
        let storage = DelayedMemoryStorage()
        let store = MemoryStore(config: MemoryConfig(), storage: storage)
        let loading = Task { await store.allLongTerm() }
        await storage.waitUntilLoading()
        let added = MemoryEntry(content: "new memory")
        try await store.addLongTerm(added)
        await storage.finishLoading()
        _ = await loading.value
        let current = await store.allLongTerm()
        XCTAssertEqual(current.map(\.id), [added.id])
    }

    func testDisabledMemoryDoesNotReportSuccessfulSave() async throws {
        let agent = await AIAgentCentral().create(name: "disabled-memory", profile: AIAgentProfile(
            identity: "test", memoryConfig: MemoryConfig(longTermEnabled: false), registerBuiltInTools: false
        ), sessionStorage: InMemorySessionStorage())
        let session = await agent.createSession()
        let output = try await MemoryTool().execute(arguments: [
            "action": .string("add"), "content": .string("must not claim saved")
        ], session: session)
        assertError(output, parameter: "disabled")
    }

    func testNonpositiveMemoryLimitsReturnEmptyResults() async throws {
        let store = MemoryStore(config: MemoryConfig(longTermMaxEntries: -1, hotMemoryEnabled: false),
                                storage: InMemoryMemoryStorage())
        try await store.addLongTerm(MemoryEntry(content: "new memory"))
        let matches = await store.searchLongTerm(query: "memory", limit: -1)
        let configuredPrompts = await store.assembleMemoryPrompts()
        let explicitPrompts = await store.assembleMemoryPrompts(limit: -1)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertTrue(configuredPrompts.isEmpty)
        XCTAssertTrue(explicitPrompts.isEmpty)
    }

    private actor FirstReadFails: MemoryStorage {
        var first = true
        let entry = MemoryEntry(content: "available after transient failure")
        func loadAll() async throws -> [MemoryEntry] {
            if first { first = false; throw URLError(.cannotOpenFile) }
            return [entry]
        }
        func save(_ entries: [MemoryEntry]) async throws {}
        func append(_ entry: MemoryEntry) async throws {}
        func remove(id: String) async throws -> Bool { false }
    }

    func testTransientMemoryReadFailureIsNotCachedAndCancellationStopsLoading() async throws {
        let store = MemoryStore(config: MemoryConfig(), storage: FirstReadFails())
        let first = await store.allLongTerm()
        let second = await store.allLongTerm()
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.allLongTerm()
        }
        let cancelledResult = await cancelled.value
        XCTAssertTrue(cancelledResult.isEmpty)
    }

    private struct RuntimeProbe: RuntimeInspectProvider {
        func uiHierarchy(context: HostInspectionContext) async -> String { "tree" }
        func classList(matching filter: String?, context: HostInspectionContext) async -> [String] { [] }
        func methodList(ofClass className: String, context: HostInspectionContext) async -> [String] { [] }
        func propertyList(ofClass className: String, context: HostInspectionContext) async -> [String] { [] }
        func propertyValue(keyPath: String, ofClass className: String?, context: HostInspectionContext) async -> String? { nil }
        func invoke(className: String, selector: String, argumentsJSON: String, context: HostInspectionContext) async -> String { "" }
        func viewTree(maxDepth: Int, context: HostInspectionContext) async -> String { String(maxDepth) }
    }

    func testRuntimeDepthRejectsUnrepresentableValuesAndKeepsClampingIntegers() async throws {
        let tool = RuntimeInspectTool.ui(provider: RuntimeProbe())
        let session = AISession(id: UUID().uuidString)
        for value: JSONValue in [.number(.infinity), .number(.nan), .number(.greatestFiniteMagnitude), .number(1.5)] {
            assertError(try await tool.execute(arguments: ["op": .string("view_tree"), "maxDepth": value],
                                               session: session), parameter: "maxDepth")
        }
        let output = try await tool.execute(arguments: ["op": .string("view_tree"), "maxDepth": .number(1000)],
                                            session: session)
        XCTAssertEqual(output.stringValue, "40")
    }
}
