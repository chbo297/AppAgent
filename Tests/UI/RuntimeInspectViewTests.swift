#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

/// 运行时视图寻址与取值解析（app_runtime_inspect 的 view_* 系列依赖它们）。
final class RuntimeInspectViewTests: XCTestCase {

    /// root / 0 / 1/0 三种路径都能落到正确的视图，越界返回 nil。
    func testViewPathResolution() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let first = UIView()
        let second = UIView()
        let nested = UILabel()
        second.addSubview(nested)
        root.addSubview(first)
        root.addSubview(second)

        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "root", root: root) === root)
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "", root: root) === root)
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "0", root: root) === first)
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "1/0", root: root) === nested)
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "9", root: root))
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "1/0/0", root: root))
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "abc", root: root))
    }

    /// 视图树打印带可寻址路径，并遵守 maxDepth。
    func testAddressableTreeIncludesPathsAndRespectsDepth() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let child = UIView()
        let grandchild = UILabel()
        grandchild.text = "hi"
        child.addSubview(grandchild)
        root.addSubview(child)

        var deep = ""
        DefaultRuntimeInspectProvider.describeAddressable(
            view: root, path: "root", depth: 0, maxDepth: 5, into: &deep
        )
        XCTAssertTrue(deep.contains("[root]"))
        XCTAssertTrue(deep.contains("[0]"))
        XCTAssertTrue(deep.contains("[0/0]"))
        XCTAssertTrue(deep.contains("text=\"hi\""))

        var shallow = ""
        DefaultRuntimeInspectProvider.describeAddressable(
            view: root, path: "root", depth: 0, maxDepth: 1, into: &shallow
        )
        XCTAssertTrue(shallow.contains("[0]"))
        XCTAssertFalse(shallow.contains("[0/0]"))
        XCTAssertTrue(shallow.contains("more subviews"))
    }

    func testValueParsers() {
        XCTAssertEqual(DefaultRuntimeInspectProvider.parseRect("10, 20,30,40"), CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertNil(DefaultRuntimeInspectProvider.parseRect("10,20,30"))
        XCTAssertEqual(DefaultRuntimeInspectProvider.parsePoint("5,6"), CGPoint(x: 5, y: 6))
        XCTAssertNil(DefaultRuntimeInspectProvider.parsePoint("5"))
        XCTAssertTrue(DefaultRuntimeInspectProvider.parseBool("YES"))
        XCTAssertTrue(DefaultRuntimeInspectProvider.parseBool("1"))
        XCTAssertFalse(DefaultRuntimeInspectProvider.parseBool("no"))

        let red = DefaultRuntimeInspectProvider.parseColor("#FF0000")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        red?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.01)
        XCTAssertEqual(g, 0, accuracy: 0.01)
        XCTAssertEqual(a, 1, accuracy: 0.01)

        let half = DefaultRuntimeInspectProvider.parseColor("00FF0080")
        half?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(g, 1, accuracy: 0.01)
        XCTAssertEqual(a, 0.5, accuracy: 0.01)

        XCTAssertNotNil(DefaultRuntimeInspectProvider.parseColor("clear"))
        XCTAssertNil(DefaultRuntimeInspectProvider.parseColor("not-a-color"))
    }

    /// 工具层参数校验：缺 path/key/value 时明确报错，不静默成功。
    func testToolValidatesViewOpArguments() async throws {
        let tool = RuntimeInspectTool(provider: RecordingRuntimeProvider())
        let session = AISession(id: "s", title: "t")

        let missingPath = try await tool.execute(arguments: ["op": .string("view_info")], session: session)
        guard case .error = missingPath else { return XCTFail("expected error for missing path") }

        let missingKey = try await tool.execute(
            arguments: ["op": .string("view_set"), "path": .string("0")], session: session
        )
        guard case .error = missingKey else { return XCTFail("expected error for missing key") }

        let ok = try await tool.execute(
            arguments: [
                "op": .string("view_set"), "path": .string("0"),
                "key": .string("alpha"), "value": .string("0.5")
            ],
            session: session
        )
        guard case .text(let out) = ok else { return XCTFail("expected text output") }
        XCTAssertEqual(out, "OK. set 0.alpha=0.5")
    }

    /// 写类操作只认 `OK.` 前缀为成功。provider 的失败文案形态很多
    /// （`Invalid rect '…'`、`UIView has no text/title to set.`…），靠「失败前缀清单」
    /// 认失败漏一个就会把「没生效的修改」当成功交给模型。
    func testMutationsWithoutOKPrefixSurfaceAsErrors() async throws {
        let tool = RuntimeInspectTool(provider: FailingRuntimeProvider())
        let session = AISession(id: "s", title: "t")

        let badValue = try await tool.execute(arguments: [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("frame"), "value": .string("garbage")
        ], session: session)
        guard case .error(let viewSetMessage) = badValue else {
            return XCTFail("expected view_set failure to be an error")
        }
        XCTAssertTrue(viewSetMessage.contains("Invalid rect"))

        let badKVCWrite = try await tool.execute(arguments: [
            "op": .string("property_set"), "keyPath": .string("nope"), "value": .string("1")
        ], session: session)
        guard case .error = badKVCWrite else {
            return XCTFail("expected property_set failure to be an error")
        }
    }

    /// 读也一样：`property_value` 以前绕过判定直接 `.text(...)`，
    /// 于是 "Failed to read …" 会被模型当成读到的值。
    func testPropertyValueFailureSurfacesAsError() async throws {
        let tool = RuntimeInspectTool(provider: FailingRuntimeProvider())
        let session = AISession(id: "s", title: "t")

        let failed = try await tool.execute(arguments: [
            "op": .string("property_value"), "keyPath": .string("nope")
        ], session: session)
        guard case .error(let message) = failed else {
            return XCTFail("expected property_value failure to be an error")
        }
        XCTAssertTrue(message.hasPrefix("Failed to read"))
    }

    /// 反射只能传/收对象：`setTag:` 收 NSInteger、`isHidden` 返回 BOOL，
    /// 按对象指针调过去会写坏值或直接崩，所以调用前按类型编码拒掉。
    func testSelectorRejectionBlocksPrimitiveArgumentsAndReturns() {
        let view = UIView()
        XCTAssertNil(DefaultRuntimeInspectProvider.selectorRejection(
            #selector(UIView.setNeedsLayout), on: view, argCount: 0
        ))
        let primitiveArg = DefaultRuntimeInspectProvider.selectorRejection(
            NSSelectorFromString("setTag:"), on: view, argCount: 1
        )
        XCTAssertTrue(primitiveArg?.contains("not an object") == true, "got \(primitiveArg ?? "nil")")
        // 拒绝文案必须以 "(selector " 起头，工具层按这个前缀判失败。
        XCTAssertTrue(primitiveArg?.hasPrefix("(selector ") == true)
        let primitiveReturn = DefaultRuntimeInspectProvider.selectorRejection(
            NSSelectorFromString("isHidden"), on: view, argCount: 0
        )
        XCTAssertTrue(primitiveReturn?.contains("not an object") == true, "got \(primitiveReturn ?? "nil")")
        let wrongArity = DefaultRuntimeInspectProvider.selectorRejection(
            #selector(UIView.setNeedsLayout), on: view, argCount: 1
        )
        XCTAssertTrue(wrongArity?.contains("argument") == true, "got \(wrongArity ?? "nil")")
    }
}

/// 只记录调用的桩 provider，用于验证工具的分发与参数校验。
private struct RecordingRuntimeProvider: RuntimeInspectProvider {
    func uiHierarchy() async -> String { "hierarchy" }
    func classList(matching filter: String?) async -> [String] { ["A"] }
    func methodList(ofClass className: String) async -> [String] { ["- m"] }
    func propertyList(ofClass className: String) async -> [String] { ["@property p"] }
    func propertyValue(keyPath: String, ofClass className: String?) async -> String? { "value" }
    func invoke(className: String, selector: String, argumentsJSON: String) async -> String { "invoked" }
    func viewTree(maxDepth: Int) async -> String { "tree depth=\(maxDepth)" }
    func viewInfo(path: String) async -> String { "info \(path)" }
    func setViewValue(path: String, key: String, value: String) async -> String { "OK. set \(path).\(key)=\(value)" }
    func invokeOnView(path: String, selector: String, argumentsJSON: String) async -> String { "view invoked" }
}

/// 全部以 provider 真实的失败文案回答，用于验证工具层的成功/失败判定。
private struct FailingRuntimeProvider: RuntimeInspectProvider {
    func uiHierarchy() async -> String { "(no windows)" }
    func classList(matching filter: String?) async -> [String] { [] }
    func methodList(ofClass className: String) async -> [String] { ["(class not found: X)"] }
    func propertyList(ofClass className: String) async -> [String] { ["(class not found: X)"] }
    func propertyValue(keyPath: String, ofClass className: String?) async -> String? {
        "Failed to read \(keyPath): valueForUndefinedKey:"
    }
    func setPropertyValue(keyPath: String, value: String, ofClass className: String?) async -> String {
        "Failed to set \(keyPath): setValue:forUndefinedKey:"
    }
    func invoke(className: String, selector: String, argumentsJSON: String) async -> String {
        "Invoke failed: boom"
    }
    func viewTree(maxDepth: Int) async -> String { "(no key window)" }
    func viewInfo(path: String) async -> String { "(no view at path '\(path)')" }
    func setViewValue(path: String, key: String, value: String) async -> String {
        "Invalid rect '\(value)'. Use \"x,y,width,height\"."
    }
    func invokeOnView(path: String, selector: String, argumentsJSON: String) async -> String {
        "(selector \(selector) not found on UIView)"
    }
}
#endif
