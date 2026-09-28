import Foundation
import XCTest
@testable import AppAgent

final class ScreenshotStorageTests: XCTestCase {
    private var temporaryRoot: URL!
    private var documents: URL!
    private let fm = FileManager.default
    private let bytes = Data([0x89, 0x50, 0x4E, 0x47])

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = fm.temporaryDirectory
            .appendingPathComponent("ScreenshotStorageTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defer {
            documents = nil
            temporaryRoot = nil
        }
        if let temporaryRoot { try fm.removeItem(at: temporaryRoot) }
        try super.tearDownWithError()
    }

    private func relativeDirectory(_ scope: HostInspectionScope) -> String {
        scope == .host ? "AppAgentScreenshots" : "AppAgent/diagnostics/screenshots"
    }

    func testHostSDKAndAllDestinationsAndSavedBytes() throws {
        for scope in HostInspectionScope.allCases {
            let expected = documents.appendingPathComponent("\(relativeDirectory(scope))/\(scope.rawValue).png")
            let destination = try ScreenshotTool.destination(stem: scope.rawValue, scope: scope, documents: documents)
            XCTAssertEqual(destination.path, expected.path)
            XCTAssertFalse(fm.fileExists(atPath: destination.path), "Preparing a directory must not create the PNG")
            let saved = try ScreenshotTool.save(bytes, stem: scope.rawValue, scope: scope, documents: documents)
            XCTAssertEqual(saved.path, expected.path)
            XCTAssertEqual(try Data(contentsOf: saved), bytes)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: documents.appendingPathComponent("AppAgentScreenshots").path),
                       ["host.png"])
        XCTAssertEqual(Set(try fm.contentsOfDirectory(
            atPath: documents.appendingPathComponent("AppAgent/diagnostics/screenshots").path
        )), Set(["appagent.png", "all.png"]))
    }

    func testSameNameSDKAndAllSavesNeverOverwriteHostArtifact() throws {
        let hostURL = try ScreenshotTool.save(bytes, stem: "same", scope: .host, documents: documents)
        for scope in [HostInspectionScope.appagent, .all] {
            let sdkBytes = Data(scope.rawValue.utf8)
            let sdkURL = try ScreenshotTool.save(sdkBytes, stem: "same", scope: scope, documents: documents)
            XCTAssertNotEqual(hostURL.path, sdkURL.path)
            XCTAssertEqual(try Data(contentsOf: sdkURL), sdkBytes)
            XCTAssertEqual(try Data(contentsOf: hostURL), bytes)
        }
    }

    func testDocumentsPrefixAliasIsAllowed() throws {
        let alias = temporaryRoot.appendingPathComponent("DocumentsAlias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: documents)
        for scope in HostInspectionScope.allCases {
            let saved = try ScreenshotTool.save(bytes, stem: "alias", scope: scope, documents: alias)
            XCTAssertEqual(saved.path, documents.appendingPathComponent("\(relativeDirectory(scope))/alias.png").path)
            XCTAssertEqual(try Data(contentsOf: saved), bytes)
        }
    }

    func testEveryDirectoryComponentRejectsOutsideAndInsideDocumentsRedirectsBeforeMkdir() throws {
        for scope in HostInspectionScope.allCases {
            let components = relativeDirectory(scope).split(separator: "/").map(String.init)
            for index in components.indices {
                for insideDocuments in [false, true] {
                    let fixture = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let docs = fixture.appendingPathComponent("Documents", isDirectory: true)
                    let redirected = (insideDocuments ? docs : fixture).appendingPathComponent("redirected", isDirectory: true)
                    try fm.createDirectory(at: docs, withIntermediateDirectories: true)
                    try fm.createDirectory(at: redirected, withIntermediateDirectories: true)
                    var link = docs
                    for component in components.prefix(index + 1) {
                        link.appendPathComponent(component, isDirectory: true)
                    }
                    try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.createSymbolicLink(at: link, withDestinationURL: redirected)

                    XCTAssertThrowsError(try ScreenshotTool.destination(stem: "blocked", scope: scope, documents: docs))
                    XCTAssertThrowsError(try ScreenshotTool.save(bytes, stem: "blocked", scope: scope, documents: docs))
                    XCTAssertTrue(try fm.contentsOfDirectory(atPath: redirected.path).isEmpty,
                                  "No descendant mkdir or PNG may follow a redirected component")
                }
            }
        }
    }

    func testDanglingAndSelfReferentialDirectoryLinksAreRejected() throws {
        for scope in HostInspectionScope.allCases {
            for selfReferential in [false, true] {
                let docs = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: docs, withIntermediateDirectories: true)
                let firstComponent = String(relativeDirectory(scope).split(separator: "/")[0])
                let link = docs.appendingPathComponent(firstComponent, isDirectory: true)
                let missing = temporaryRoot.appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
                try fm.createSymbolicLink(at: link, withDestinationURL: selfReferential ? link : missing)
                XCTAssertThrowsError(try ScreenshotTool.save(bytes, stem: "blocked", scope: scope, documents: docs))
                XCTAssertFalse(fm.fileExists(atPath: missing.path))
            }
        }
    }

    func testFileLinksAreRejectedIncludingDanglingAndInDirectoryLinks() throws {
        for scope in HostInspectionScope.allCases {
            let file = try ScreenshotTool.destination(stem: "linked", scope: scope, documents: documents)
            let outside = temporaryRoot.appendingPathComponent("outside-\(scope.rawValue).png")
            let inside = file.deletingLastPathComponent().appendingPathComponent("sibling.png")
            let missing = temporaryRoot.appendingPathComponent("missing-\(scope.rawValue).png")
            let sentinel = Data("do-not-overwrite".utf8)
            try sentinel.write(to: outside)
            try sentinel.write(to: inside)
            for target in [outside, inside, missing, file] {
                try fm.createSymbolicLink(at: file, withDestinationURL: target)
                XCTAssertThrowsError(try ScreenshotTool.destination(stem: "linked", scope: scope, documents: documents))
                XCTAssertThrowsError(try ScreenshotTool.save(bytes, stem: "linked", scope: scope, documents: documents))
                XCTAssertEqual(try Data(contentsOf: outside), sentinel)
                XCTAssertEqual(try Data(contentsOf: inside), sentinel)
                XCTAssertFalse(fm.fileExists(atPath: missing.path))
                XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType, .typeSymbolicLink)
                try fm.removeItem(at: file)
            }
        }
    }

    func testNonDirectoryParentAndNonRegularFileAreRejected() throws {
        for scope in HostInspectionScope.allCases {
            let docs = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            let firstComponent = String(relativeDirectory(scope).split(separator: "/")[0])
            let parent = docs.appendingPathComponent(firstComponent)
            try bytes.write(to: parent)
            XCTAssertThrowsError(try ScreenshotTool.save(bytes, stem: "blocked", scope: scope, documents: docs))
            XCTAssertEqual(try Data(contentsOf: parent), bytes)

            let destination = try ScreenshotTool.destination(stem: "directory", scope: scope, documents: documents)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            XCTAssertThrowsError(try ScreenshotTool.save(bytes, stem: "directory", scope: scope, documents: documents))
            try fm.removeItem(at: destination)
        }
    }

    func testTraversalAndPathSyntaxAreRejectedWithoutCreatingStorageDirectories() throws {
        let invalid = ["..", ".", "../escape", "a/../../escape", "/absolute", "a\\b",
                       "%2e%2e%2fescape", "name.png", "bad\u{0}name"]
        for scope in HostInspectionScope.allCases {
            for stem in invalid {
                XCTAssertThrowsError(try ScreenshotTool.destination(stem: stem, scope: scope, documents: documents))
                XCTAssertThrowsError(try ScreenshotTool.save(bytes, stem: stem, scope: scope, documents: documents))
            }
        }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: documents.path).isEmpty)
    }

    func testValidAndDefaultNamesStayInFixedDirectory() throws {
        for scope in HostInspectionScope.allCases {
            let named = try ScreenshotTool.destination(stem: "截图_A-12", scope: scope, documents: documents)
            XCTAssertEqual(named.lastPathComponent, "截图_A-12.png")
            for stem: String? in [nil, ""] {
                let generated = try ScreenshotTool.destination(stem: stem, scope: scope, documents: documents)
                XCTAssertEqual(generated.pathExtension, "png")
                XCTAssertTrue(generated.lastPathComponent.hasPrefix("shot-"))
                XCTAssertEqual(generated.deletingLastPathComponent().path,
                               documents.appendingPathComponent(relativeDirectory(scope)).path)
            }
        }
    }

    func testMissingOrNonFileDocumentsIsRejected() throws {
        let missing = temporaryRoot.appendingPathComponent("missing-documents", isDirectory: true)
        for root in [missing, URL(string: "https://example.invalid/Documents")!] {
            XCTAssertThrowsError(try ScreenshotTool.destination(stem: "shot", scope: .host, documents: root))
        }
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
    }

    func testSavingIsAMutationForExecutorSafetyAndReadOnlyPolicy() {
        let tool: any ToolProtocol = ScreenshotTool()
        XCTAssertEqual(tool.safetyLevel(for: [:]), .safe)
        XCTAssertEqual(tool.safetyLevel(for: ["save_as_file": .bool(false)]), .safe)
        for scope in HostInspectionScope.allCases {
            let level = tool.safetyLevel(for: ["save_as_file": .bool(true), "scope": .string(scope.rawValue)])
            XCTAssertEqual(level, .moderate)
            XCTAssertGreaterThan(level, .safe, "Executor must schedule saves serially")
            XCTAssertTrue(LLMExecutor.isBlockedByMutationPolicy(.readOnly, level: level))
            XCTAssertFalse(LLMExecutor.isBlockedByMutationPolicy(.allowed, level: level))
        }
        XCTAssertFalse(tool.description.lowercased().contains("workspace"))
    }

    func testDirectSaveExecutionHonorsOwnAndParentReadOnlyWithoutPrompting() async throws {
        var profile = AIAgentProfile()
        profile.toolMutationPolicy = .readOnly
        let parent = AISession(id: UUID().uuidString, agentMask: AIAgentMask(
            profile: profile, toolCentral: ToolCentral()
        ))
        let child = AISession(id: UUID().uuidString)
        child.decisionParent = parent
        let responder = ScreenshotStorageDecisionRecorder()
        parent.decisionResponders = DecisionResponderCentral()
        parent.decisionResponders.register(responder)
        child.decisionResponders = DecisionResponderCentral()
        child.decisionResponders.register(responder)
        for session in [parent, child] {
            for scope in HostInspectionScope.allCases {
                let output = try await ScreenshotTool().execute(
                    arguments: ["save_as_file": .bool(true), "scope": .string(scope.rawValue)], session: session
                )
                guard case .error(let message) = output else {
                    XCTFail("Direct execute must refuse a readOnly save")
                    continue
                }
                XCTAssertEqual(message, HostInspectionError.readOnly.localizedDescription)
            }
        }
        let requests = await responder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidScopeIsAnErrorOutputNotAThrownError() async throws {
        let session = AISession(id: UUID().uuidString)
        session.decisionResponders = DecisionResponderCentral()
        for scope: JSONValue in [.string("invalid"), .string(""), .null, .number(1), .bool(true)] {
            let output = try await ScreenshotTool().execute(arguments: ["scope": scope], session: session)
            guard case .error(let message) = output else {
                XCTFail("Scope parsing must produce Tool.Output.error")
                continue
            }
            XCTAssertEqual(message, HostInspectionError.invalidScope.localizedDescription)
        }
    }

    func testInlineAndSavedSDKCallsRequestSeparateReadAndMutationApproval() async throws {
        let responder = ScreenshotStorageDecisionRecorder()
        let session = AISession(id: UUID().uuidString)
        session.decisionResponders = DecisionResponderCentral()
        session.decisionResponders.register(responder)
        for scope in [HostInspectionScope.appagent, .all] {
            for savesFile in [false, true] {
                let output = try await ScreenshotTool().execute(
                    arguments: ["scope": .string(scope.rawValue), "save_as_file": .bool(savesFile)], session: session
                )
                guard case .error(let message) = output else {
                    XCTFail("Denied approval must stop before capture")
                    continue
                }
                XCTAssertEqual(message, HostInspectionError.denied.localizedDescription)
            }
        }
        let requests = await responder.requests
        XCTAssertEqual(requests, [
            .appAgentInspection(scope: .appagent, isMutation: false),
            .appAgentInspection(scope: .appagent, isMutation: true),
            .appAgentInspection(scope: .all, isMutation: false),
            .appAgentInspection(scope: .all, isMutation: true)
        ])
    }
}

private actor ScreenshotStorageDecisionRecorder: DecisionResponder {
    var requests: [DecisionRequest] = []

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        requests.append(request)
        return .deny
    }
}
