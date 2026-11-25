import Foundation
import CoreGraphics
import AppKit

struct H5TestFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String = "expectation failed") throws {
    if !condition {
        throw H5TestFailure(description: message)
    }
}

func requireThrows(_ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        return
    }
    throw H5TestFailure(description: "invalid input was accepted")
}

@MainActor
enum H5Tests {
    static var passed = 0
    static var failed = 0

    static func run(_ name: String, _ operation: () throws -> Void) {
        do {
            try operation()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
        fflush(stdout)
    }

    /// 测试用：按文件和插槽开关拼一份会话工作区，交给真实的内容校验。
    static func workspace(files: [String: String] = ["index.html": "<p>ok</p>"], title: String = "",
                          slot: Bool = false, state: [String: String] = [:]) -> SessionWorkspace {
        SessionWorkspace(isShown: true, title: title,
                         h5: SessionWorkspace.H5(files: files, state: state),
                         slots: slot ? ["map": SessionWorkspace.Slot(isShown: true)] : [:])
    }

    static func content(files: [String: String] = ["index.html": "<p>ok</p>"], slot: Bool = false) throws
        -> AppAgentWorkspaceH5Content {
        try AppAgentWorkspaceH5Content(workspace: workspace(files: files, slot: slot), fallbackTitle: "fallback")
    }

    static func contentTests() {
        run("content/titles fall back to session title, then 工作区") {
            try require(try content().title == "fallback")
            let empty = try AppAgentWorkspaceH5Content(workspace: workspace(), fallbackTitle: "")
            try require(empty.title == "工作区")
            let named = try AppAgentWorkspaceH5Content(workspace: workspace(title: "比较"), fallbackTitle: "x")
            try require(named.title == "比较")
        }
        run("content/index.html is the entry, other files are resources, slot flag follows slot layer") {
            let value = try content(files: ["index.html": "<p>a</p>", "app.js": "1", "css/a.css": "b{}"], slot: true)
            try require(value.html == "<p>a</p>" && value.resources == ["app.js": "1", "css/a.css": "b{}"])
            try require(value.hasSlot)
            try require(try content(files: [:], slot: true).html.isEmpty)
        }
        run("content/path whitelist including 240-byte path") {
            let longPath = String(repeating: "a", count: 237) + ".js"
            try require(longPath.utf8.count == 240)
            for path in ["index.html", "a.css", "dir/b.js", "x.json", "icon.svg", longPath] {
                try require(SessionWorkspaceLimits.isValidPath(path), path)
            }
        }
        for path in ["", "/a.js", "a//b.js", "a/", "./a.js", "a/../b.js", "a%2e.js", "https://x/a.js",
                     "a\\b.js", "a.png", "a.js?x", String(repeating: "a", count: 238) + ".js"] {
            run("content/reject path \(String(reflecting: path))") {
                try require(!SessionWorkspaceLimits.isValidPath(path))
                try requireThrows {
                    _ = try content(files: ["index.html": "x", path: "x"])
                }
            }
        }
        run("content/index.html exact 1 MiB and overflow") {
            _ = try content(files: ["index.html": String(repeating: "a", count: 1_048_576)])
            try requireThrows {
                _ = try content(files: ["index.html": String(repeating: "a", count: 1_048_577)])
            }
        }
        run("content/file exact 512 KiB and overflow") {
            _ = try content(files: ["index.html": "x", "a.js": String(repeating: "a", count: 524_288)])
            try requireThrows {
                _ = try content(files: ["index.html": "x", "a.js": String(repeating: "a", count: 524_289)])
            }
        }
        run("content/file count 128 accepted, 129 rejected") {
            var files = ["index.html": "x"]
            for index in 0..<127 {
                files["f\(index).js"] = "1"
            }
            _ = try content(files: files)
            files["one-more.js"] = "1"
            try requireThrows {
                _ = try content(files: files)
            }
        }
        run("content/all files exact 4 MiB and overflow") {
            var files = ["index.html": String(repeating: "a", count: 1_048_576)]
            for index in 0..<6 {
                files["r\(index).js"] = String(repeating: "b", count: 524_288)
            }
            files["tail.js"] = String(repeating: "c", count: 4_194_304 - 1_048_576 - 6 * 524_288)
            _ = try content(files: files)
            files["tail.js"]! += "c"
            try requireThrows {
                _ = try content(files: files)
            }
        }
        run("content/page state exact 128 KiB and overflow") {
            let limit = SessionWorkspaceLimits.maximumStateBytes
            let fits = workspace(state: ["k": String(repeating: "a", count: limit - 1)])
            try require(SessionWorkspaceLimits.violation(in: fits) == nil)
            let over = workspace(state: ["k": String(repeating: "a", count: limit)])
            try require(SessionWorkspaceLimits.violation(in: over) != nil)
        }
    }

    static func touchTests() {
        let size = CGSize(width: 400, height: 800)
        let region = CGRect(x: 10, y: 20, width: 100, height: 150)

        func seeded() throws -> AppAgentWorkspaceUIPolicy {
            var policy = AppAgentWorkspaceUIPolicy()
            policy.invalidate(size: size)
            try require(policy.accept(epoch: policy.epoch, revision: 1, viewport: size, rects: [region]))
            return policy
        }

        run("touch/default closed, epoch invalidation and resize") {
            var policy = AppAgentWorkspaceUIPolicy()
            try require(policy.resolve(.touch(point: .zero, size: .zero, occlusions: [])) == .web)
            policy = try seeded()
            let epoch = policy.epoch
            policy.invalidate(size: CGSize(width: 800, height: 400))
            try require(policy.epoch == epoch + 1 && policy.revision == 0 && policy.regions.isEmpty)
            try require(!policy.accept(epoch: epoch, revision: 2, viewport: size, rects: [region]))
        }
        run("touch/uniform scale, hit/miss, current size and occlusions") {
            var policy = AppAgentWorkspaceUIPolicy()
            policy.invalidate(size: size)
            try require(policy.accept(epoch: policy.epoch, revision: 1,
                                      viewport: CGSize(width: 200, height: 400), rects: [region]))
            try require(policy.regions == [CGRect(x: 20, y: 40, width: 200, height: 300)])
            let point = CGPoint(x: 30, y: 50)
            try require(policy.resolve(.touch(point: point, size: size, occlusions: [])) == .slot)
            try require(policy.resolve(.touch(point: CGPoint(x: 5, y: 5), size: size, occlusions: [])) == .web)
            try require(policy.resolve(.touch(point: point, size: CGSize(width: 401, height: 800), occlusions: [])) == .web)
            try require(policy.resolve(.touch(point: point, size: size,
                                         occlusions: [CGRect(x: 25, y: 45, width: 20, height: 20)])) == .web)
            try require(policy.resolve(.touch(point: point, size: size, occlusions: [.zero])) == .slot)
            try require(policy.resolve(.touch(point: CGPoint(x: CGFloat.nan, y: 50), size: size, occlusions: [])) == .web)
            try require(policy.resolve(.touch(point: CGPoint(x: 30, y: CGFloat.infinity), size: size, occlusions: [])) == .web)
        }
        run("touch/stale epoch/revision revoke previous regions without advancing revision") {
            for (epochOffset, revision) in [(0, 0), (0, 1), (-1, 2), (1, 2), (0, -1)] {
                var policy = try seeded()
                try require(!policy.accept(epoch: policy.epoch + epochOffset, revision: revision,
                                           viewport: size, rects: [region]))
                try require(policy.regions.isEmpty && policy.revision == 1)
                try require(policy.accept(epoch: policy.epoch, revision: 2, viewport: size, rects: [region]))
            }
        }
        run("touch/revision JS safe integer ceiling and empty update") {
            var policy = try seeded()
            try require(policy.accept(epoch: policy.epoch, revision: 9_007_199_254_740_991,
                                      viewport: size, rects: []))
            try require(policy.regions.isEmpty)
            try require(!policy.accept(epoch: policy.epoch, revision: 9_007_199_254_740_992,
                                       viewport: size, rects: [region]))
        }
        run("touch/64 regions accepted, 65 rejected atomically") {
            var policy = try seeded()
            try require(policy.accept(epoch: policy.epoch, revision: 2, viewport: size,
                                      rects: Array(repeating: region, count: 64)))
            try require(!policy.accept(epoch: policy.epoch, revision: 3, viewport: size,
                                       rects: Array(repeating: region, count: 65)))
            try require(policy.regions.isEmpty && policy.revision == 2)
        }
        run("touch/viewport/native nonfinite, zero and negative dimensions") {
            for value: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
                for invalid in [CGSize(width: value, height: 800), CGSize(width: 400, height: value)] {
                    var policy = try seeded()
                    try require(!policy.accept(epoch: policy.epoch, revision: 2,
                                               viewport: invalid, rects: [region]))
                    try require(policy.regions.isEmpty)
                    policy.invalidate(size: invalid)
                    try require(!policy.accept(epoch: policy.epoch, revision: 1,
                                               viewport: size, rects: [region]))
                }
            }
        }
        run("touch/nonuniform layout scale rejected, small rounding tolerated") {
            var policy = try seeded()
            try require(policy.accept(epoch: policy.epoch, revision: 2,
                                      viewport: CGSize(width: 399, height: 800), rects: [region]))
            try require(!policy.accept(epoch: policy.epoch, revision: 3,
                                       viewport: CGSize(width: 300, height: 800), rects: [region]))
            try require(policy.regions.isEmpty)
        }
        run("touch/out-of-bounds, negative/zero/nonfinite rects reject entire batch") {
            var invalid = [
                CGRect(x: -1, y: 0, width: 5, height: 5),
                CGRect(x: 0, y: -1, width: 5, height: 5),
                CGRect(x: 399, y: 0, width: 2, height: 5),
                CGRect(x: 0, y: 799, width: 5, height: 2),
                CGRect(x: 0, y: 0, width: 0, height: 5),
                CGRect(x: 0, y: 0, width: 5, height: 0),
                CGRect(x: 20, y: 20, width: -5, height: 5),
                CGRect(x: 20, y: 20, width: 5, height: -5)
            ]
            for value: CGFloat in [.nan, .infinity, -.infinity] {
                invalid.append(CGRect(x: value, y: 0, width: 5, height: 5))
                invalid.append(CGRect(x: 0, y: value, width: 5, height: 5))
                invalid.append(CGRect(x: 0, y: 0, width: value, height: 5))
                invalid.append(CGRect(x: 0, y: 0, width: 5, height: value))
            }
            for rect in invalid {
                var policy = try seeded()
                try require(!policy.accept(epoch: policy.epoch, revision: 2,
                                           viewport: size, rects: [region, rect]), "\(rect)")
                try require(policy.regions.isEmpty && policy.revision == 1)
            }
        }
        run("touch/exact viewport edges accepted") {
            var policy = try seeded()
            try require(policy.accept(epoch: policy.epoch, revision: 2,
                                      viewport: size, rects: [CGRect(origin: .zero, size: size)]))
            try require(policy.resolve(.touch(point: CGPoint(x: 399, y: 799), size: size, occlusions: [])) == .slot)
            try require(policy.resolve(.touch(point: CGPoint(x: 401, y: 801), size: size, occlusions: [])) == .web)
        }
        run("invoke/native tap gate: no touch, stale touch and reused touch are rejected") {
            var gate = AppAgentWorkspaceTapGate()
            try require(!gate.consume(at: 10))
            gate.recordTouch(at: 10)
            try require(gate.consume(at: 10.2))
            try require(!gate.consume(at: 10.3), "one touch allows one invoke")
            gate.recordTouch(at: 20)
            try require(!gate.consume(at: 20 + AppAgentWorkspaceTapGate.window + 0.1))
            gate.recordTouch(at: 30)
            try require(!gate.consume(at: 29), "clock going backwards is rejected")
            gate.recordTouch(at: 40)
            gate.reset()
            try require(!gate.consume(at: 40.1))
        }
    }
}

@main
struct WorkspaceH5DirectedTests {
    @MainActor
    static func main() {
        H5Tests.contentTests()
        H5Tests.touchTests()
        if !CommandLine.arguments.contains("--core-only") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            H5Tests.webKitTests()
        } else {
            print("SKIP scheme/WKWebView (--core-only); not a full H5 validation")
        }
        print("RESULT \(H5Tests.passed) passed, \(H5Tests.failed) failed")
        exit(H5Tests.failed == 0 ? 0 : 1)
    }
}
