#if canImport(UIKit) && canImport(JavaScriptCore)
import XCTest
import UIKit
@testable import AppAgent

@objc(AppAgentHookProbe)
class AppAgentHookProbe: NSObject {

    @objc dynamic func canShow() -> Bool {
        true
    }

    @objc dynamic func add(_ a: Int, to b: Int) -> Int {
        a + b
    }

    @objc dynamic func greeting(_ name: String) -> String {
        "hello \(name)"
    }

    @objc dynamic func offset(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: 1, dy: 2)
    }

    @objc dynamic class func buildTag() -> String {
        "1"
    }
}

@objc(AppAgentHookSlotProbe)
class AppAgentHookSlotProbe: NSObject {

    @objc dynamic func enabled() -> Bool {
        true
    }
}

/// 方法拦截是进程级的：每个用例结束前必须恢复，否则会串到别的用例。
final class HotfixMethodHookTests: XCTestCase {

    @MainActor
    func testInsteadReturnsBoolAndRemoveRestores() {
        let probe = AppAgentHookProbe()
        let hooks = HotfixHookSet()
        let output = DefaultHotfixProvider.evaluate("""
            appagent.hook('AppAgentHookProbe', 'canShow', 'instead', function (inv) {
                return false;
            });
            'patched';
            """, hooks: hooks)
        XCTAssertEqual(output, "patched")
        XCTAssertFalse(probe.canShow())
        hooks.removeAll()
        XCTAssertTrue(probe.canShow())
    }

    @MainActor
    func testModesReadAndWriteArgumentsAndReturnValues() {
        let probe = AppAgentHookProbe()
        let hooks = HotfixHookSet()
        let output = DefaultHotfixProvider.evaluate("""
            appagent.hook('AppAgentHookProbe', 'add:to:', 'before', function (inv) {
                inv.setArg(0, inv.args[0] * 10);
            });
            appagent.hook('AppAgentHookProbe', 'greeting:', 'instead', function (inv) {
                return inv.invokeOriginal() + '!';
            });
            appagent.hook('AppAgentHookProbe', 'offset:', 'after', function (inv) {
                var rect = inv.getReturnValue();
                rect.width = rect.width * 2;
                inv.setReturnValue(rect);
            });
            'patched';
            """, hooks: hooks)
        XCTAssertEqual(output, "patched")
        XCTAssertEqual(probe.add(1, to: 2), 12)
        XCTAssertEqual(probe.greeting("map"), "hello map!")
        XCTAssertEqual(probe.offset(CGRect(x: 0, y: 0, width: 3, height: 4)), CGRect(x: 1, y: 2, width: 6, height: 4))
        hooks.removeAll()
        XCTAssertEqual(probe.add(1, to: 2), 3)
        XCTAssertEqual(probe.greeting("map"), "hello map")
        XCTAssertEqual(probe.offset(.zero), CGRect(x: 1, y: 2, width: 0, height: 0))
    }

    @MainActor
    func testHookClassAndReflectionCalls() {
        let hooks = HotfixHookSet()
        let output = DefaultHotfixProvider.evaluate("""
            appagent.hookClass('AppAgentHookProbe', 'buildTag', 'instead', function (inv) {
                return 'patched-' + inv.invokeOriginal();
            });
            var probe = appagent.newObject('AppAgentHookProbe');
            [appagent.call(probe, 'add:to:', [2, 3]), appagent.callClass('AppAgentHookProbe', 'buildTag', [])].join(',');
            """, hooks: hooks)
        XCTAssertEqual(output, "5,patched-1")
        XCTAssertEqual(AppAgentHookProbe.buildTag(), "patched-1")
        hooks.removeAll()
        XCTAssertEqual(AppAgentHookProbe.buildTag(), "1")
    }

    @MainActor
    func testRejectedCallsFailTheEvaluationAndRollBackEarlierHooks() {
        let probe = AppAgentHookProbe()
        let earlierHook = """
            appagent.hook('AppAgentHookProbe', 'canShow', 'instead', function () {
                return false;
            });
            """
        let cases: [(call: String, reason: String)] = [
            ("appagent.hook('AppAgentHookProbe', 'initWithName:', 'after', function () {});", "init family"),
            ("appagent.hook('AppAgentHookProbe', 'add:to:', 'around', function () {});", "unknown hook mode"),
            ("appagent.hook('AppAgentMissingHookClass', 'add:to:', 'before', function () {});", "not found"),
            ("appagent.hook('NSObject', 'canShow', 'after', function () {});", "has no instance method"),
            ("appagent.hook('AppAgentHookProbe', 'canShow', 'after', function () {});", "already hooked"),
            ("appagent.call(appagent.newObject('AppAgentHookProbe'), 'add:to:', [1]);", "takes 2 arguments"),
            ("appagent.call(appagent.newObject('AppAgentHookProbe'), 'add:to:', ['a', 2]);", "argument 0")
        ]
        for item in cases {
            let hooks = HotfixHookSet()
            let output = DefaultHotfixProvider.evaluate(earlierHook + item.call + " 'patched';", hooks: hooks)
            XCTAssertTrue(output.hasPrefix("JS error: bridge:"), "\(item.call): \(output)")
            XCTAssertTrue(output.contains(item.reason), output)
            XCTAssertEqual(hooks.count, 0)
            XCTAssertTrue(probe.canShow(), item.call)
        }
    }

    func testSynchronousSlotIsManagedLikeAnyOtherSlot() async {
        let provider = DefaultHotfixProvider()
        let probe = AppAgentHookSlotProbe()
        let script = """
            appagent.hook('AppAgentHookSlotProbe', 'enabled', 'instead', function () {
                return false;
            });
            'patched';
            """
        let applied = await provider.applySynchronously(name: "sync", javascript: script, applyMode: "instant", summary: "")
        XCTAssertTrue(applied.success, applied.message)
        XCTAssertFalse(probe.enabled())

        // 同步入口的槽位不绑 scene，之后任何 scene 的调用都能管它。
        let context = HostInspectionContext(sceneIdentifier: "hook-scene-\(UUID())")
        let listed = await provider.list(context: context)
        XCTAssertEqual(listed.map(\.name), ["sync"])
        let disabled = await provider.setEnabled(name: "sync", enabled: false, context: context)
        XCTAssertTrue(disabled)
        XCTAssertTrue(probe.enabled())
        let reenabled = await provider.setEnabled(name: "sync", enabled: true, context: context)
        XCTAssertTrue(reenabled)
        XCTAssertFalse(probe.enabled())
        // 重新 apply 同名槽位先恢复旧拦截，不会撞上「已被拦截」。
        let replaced = await provider.apply(name: "sync", javascript: script, applyMode: "instant",
                                            summary: "", context: context)
        XCTAssertTrue(replaced.success, replaced.message)
        XCTAssertFalse(probe.enabled())
        let removed = await provider.remove(name: "sync", context: context)
        XCTAssertTrue(removed)
        XCTAssertTrue(probe.enabled())
    }
}
#endif
