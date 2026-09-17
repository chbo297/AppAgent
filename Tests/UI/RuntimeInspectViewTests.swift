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
        XCTAssertEqual(out, "set 0.alpha=0.5")
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
    func setViewValue(path: String, key: String, value: String) async -> String { "set \(path).\(key)=\(value)" }
    func invokeOnView(path: String, selector: String, argumentsJSON: String) async -> String { "view invoked" }
}
#endif
