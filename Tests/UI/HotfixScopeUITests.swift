#if canImport(UIKit) && canImport(JavaScriptCore)
import XCTest
import UIKit
@testable import AppAgent

final class HotfixScopeUITests: XCTestCase {
    @MainActor
    func testIgnoredBridgeFailuresFailTheWholeEvaluation() {
        let root = UIView()
        let secret = UIView()
        HostInspectionUIKit.markAppAgentOwned(secret)
        let hostView = UIView()
        root.addSubview(secret)
        root.addSubview(hostView)
        let cases: [(call: String, scope: HostInspectionScope, reason: String)] = [
            ("appagent.uiSet('99', 'alpha', '0')", .host, "no view"),
            ("appagent.uiInvoke('99', 'setNeedsLayout', '[]')", .host, "no view"),
            ("appagent.uiInfo('99')", .host, "no view"),
            ("appagent.uiSet('0', 'alpha', '0')", .host, "in scope"),
            ("appagent.uiInvoke('0', 'setNeedsLayout', '[]')", .host, "in scope"),
            ("appagent.uiInvoke('1', 'description', '[]')", .host, "requires all scope"),
            ("appagent.uiInvoke('root', 'setNeedsLayout', '[]')", .host, "out-of-scope subtree"),
            ("appagent.uiInvoke('1', 'absentHotfixSelector', '[]')", .all, "not found"),
            ("appagent.uiInvoke('1', 'setTag:', '[7]')", .all, "not an object"),
            ("appagent.uiInvoke('1', 'setNeedsLayout', '[7]')", .all, "takes 0"),
            ("appagent.uiSet('1', 'alpha', 'invalid')", .host, "Invalid alpha"),
            ("appagent.uiInvoke('1', 'setValue:forKey:', '[1,\"absentHotfixKey\"]')", .all, "Invoke failed")
        ]
        for item in cases {
            // Cover both the bare bridge return and ignored/caught return followed by success text.
            for script in [item.call, "try { \(item.call); } catch (_) {} 'patched';"] {
                let output = DefaultHotfixProvider.evaluate(
                    script, inspection: .init(scope: item.scope), root: root
                )
                XCTAssertTrue(output.hasPrefix("JS error: bridge:"), "\(script): \(output)")
                XCTAssertTrue(output.contains(item.reason), output)
            }
        }
        XCTAssertEqual(secret.alpha, 1)
        XCTAssertEqual(hostView.alpha, 1)
        XCTAssertEqual(hostView.tag, 0)
    }

    @MainActor
    func testBridgeFailureLatchSurvivesLaterSuccessAndResultConversionButDoesNotLeak() {
        let root = UIView()
        let failed = DefaultHotfixProvider.evaluate("""
            appagent.uiInvoke('root', 'description', '[]');
            appagent.uiSet('root', 'alpha', '0.5');
            'patched';
            """, root: root)
        XCTAssertTrue(failed.hasPrefix("JS error: bridge:"), failed)
        XCTAssertTrue(failed.contains("requires all scope"), failed)
        // Failure reporting is not a transaction/rollback; subsequent allowed writes still run.
        XCTAssertEqual(root.alpha, 0.5)
        let converted = DefaultHotfixProvider.evaluate("""
            ({ toString: function() {
                appagent.uiInvoke('root', 'description', '[]');
                return 'patched';
            } });
            """, root: root)
        XCTAssertTrue(converted.hasPrefix("JS error: bridge:"), converted)
        let success = DefaultHotfixProvider.evaluate("""
            appagent.uiSet('root', 'alpha', '1');
            appagent.uiInvoke('root', 'setNeedsLayout', '[]');
            'patched';
            """, root: root)
        XCTAssertEqual(success, "patched")
        XCTAssertEqual(root.alpha, 1)
        XCTAssertTrue(DefaultHotfixProvider.evaluate("throw new Error('broken');", root: root)
            .hasPrefix("JS error:"))
    }

    func testApplyAndReenableCannotHideLookupFailureWithPatchedResult() async {
        // An unavailable explicit scene exercises the real lookup path without creating UIWindow.
        let context = HostInspectionContext(sceneIdentifier: "missing-hotfix-scene-\(UUID())")
        let provider = DefaultHotfixProvider()
        let calls = [
            "appagent.uiSet('root', 'alpha', '0')",
            "appagent.uiInvoke('root', 'description', '[]')",
            "appagent.uiInfo('root')",
            "appagent.uiTree(2)"
        ]
        for (index, call) in calls.enumerated() {
            let name = "bridge-failure-\(index)"
            let applied = await provider.apply(
                name: name, javascript: "\(call); 'patched';", applyMode: "instant",
                summary: "retained slot", context: context
            )
            XCTAssertFalse(applied.success)
            XCTAssertTrue(applied.message.hasPrefix("JS error: bridge:"), applied.message)
            // Preserve existing slot semantics: failure reports do not remove/roll back the slot.
            let stored = await provider.list(context: context)
            XCTAssertEqual(stored.map(\.name), [name])
            XCTAssertEqual(stored.first?.enabled, true)
            let disabled = await provider.setEnabled(name: name, enabled: false, context: context)
            XCTAssertTrue(disabled)
            let reenabled = await provider.setEnabled(name: name, enabled: true, context: context)
            XCTAssertFalse(reenabled)
            let afterReplay = await provider.list(context: context)
            XCTAssertEqual(afterReplay.first?.enabled, true)
            let removed = await provider.remove(name: name, context: context)
            XCTAssertTrue(removed)
        }
        let success = await provider.apply(name: "pure-js", javascript: "'patched'", applyMode: "instant",
                                           summary: "", context: context)
        XCTAssertTrue(success.success)
        let replayed = await provider.setEnabled(name: "pure-js", enabled: true, context: context)
        XCTAssertTrue(replayed)
    }

    func testPatchSlotsCannotBeReadReplacedOrReplayedFromNarrowerScope() async {
        let provider = DefaultHotfixProvider()
        let sdk = HostInspectionContext(scope: .appagent, sceneIdentifier: "A")
        let host = HostInspectionContext(sceneIdentifier: "A")
        let all = HostInspectionContext(scope: .all, sceneIdentifier: "A")
        let applied = await provider.apply(name: "sdk", javascript: "'original'", applyMode: "instant",
                                           summary: "private", context: sdk)
        XCTAssertTrue(applied.success)
        let hidden = await provider.list(context: host)
        XCTAssertTrue(hidden.isEmpty)
        let replaced = await provider.apply(name: "sdk", javascript: "'replacement'", applyMode: "instant",
                                            summary: "host", context: host)
        XCTAssertFalse(replaced.success)
        let enabled = await provider.setEnabled(name: "sdk", enabled: true, context: host)
        let disabled = await provider.setEnabled(name: "sdk", enabled: false, context: host)
        let removed = await provider.remove(name: "sdk", context: host)
        XCTAssertFalse(enabled)
        XCTAssertFalse(disabled)
        XCTAssertFalse(removed)
        let visible = await provider.list(context: all)
        XCTAssertEqual(visible.first?.summary, "private")
        let allowed = await provider.setEnabled(name: "sdk", enabled: true, context: all)
        XCTAssertTrue(allowed)
        let wrongScene = await provider.list(context: .init(scope: .all, sceneIdentifier: "B"))
        XCTAssertTrue(wrongScene.isEmpty)
        let cleaned = await provider.remove(name: "sdk", context: sdk)
        XCTAssertTrue(cleaned)
    }
}
#endif
