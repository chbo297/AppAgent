import XCTest
@testable import AppAgent

final class HotfixScopeTests: XCTestCase {
    func testEveryHotfixOperationReceivesHostContextByDefault() async throws {
        let provider = RecordingHotfixScopeProvider()
        let tool = HotfixTool(provider: provider)
        let session = AISession(id: "hotfix-scope")
        session.inspectionSceneIdentifier = "scene"
        for op in ["list", "apply", "toggle", "remove"] {
            _ = try await tool.execute(arguments: [
                "op": .string(op), "name": .string("patch"), "javascript": .string("1")
            ], session: session)
        }
        let calls = await provider.calls
        XCTAssertEqual(calls, Array(repeating: HostInspectionContext(sceneIdentifier: "scene"), count: 4))
    }

    func testExplicitScopeIsDeniedBeforeProviderIncludingToggle() async throws {
        let provider = RecordingHotfixScopeProvider()
        let tool = HotfixTool(provider: provider)
        let session = AISession(id: "hotfix-denied")
        session.decisionResponders = DecisionResponderCentral()
        for op in ["list", "apply", "toggle", "remove"] {
            let output = try await tool.execute(arguments: [
                "op": .string(op), "scope": .string("all"),
                "name": .string("patch"), "javascript": .string("1")
            ], session: session)
            guard case .error = output else { return XCTFail("must deny \(op)") }
        }
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

private actor RecordingHotfixScopeProvider: HotfixProvider {
    var calls: [HostInspectionContext] = []
    func apply(name: String, javascript: String, applyMode: String, summary: String,
               context: HostInspectionContext) async -> HotfixApplyResult {
        calls.append(context)
        return .init(success: true, applyMode: applyMode, message: "OK.", needsRestart: false)
    }
    func setEnabled(name: String, enabled: Bool, context: HostInspectionContext) async -> Bool {
        calls.append(context)
        return true
    }
    func list(context: HostInspectionContext) async -> [HotfixPatchInfo] {
        calls.append(context)
        return []
    }
    func remove(name: String, context: HostInspectionContext) async -> Bool {
        calls.append(context)
        return true
    }
}
