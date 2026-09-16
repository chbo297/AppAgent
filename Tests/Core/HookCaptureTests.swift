import XCTest
@testable import AppAgent

/// app_hook_capture 工具与 HookCaptureStore 的门控配置读写测试。
/// 只覆盖与宿主 LijiMsgTap 互通的关键面——config 的 JSON 形状与开关语义；
/// 不触碰真实 Caches JSONL（读路径依赖真机落盘）。用完清理共享 key。
final class HookCaptureTests: XCTestCase {

    private let configKey = HookCaptureStore.configKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: configKey)
        super.tearDown()
    }

    private func makeSession() -> AISession {
        AISession(id: "hook-capture-test", title: "New Chat")
    }

    private func text(_ output: Tool.Output) -> String? {
        if case .text(let s) = output { return s }
        return nil
    }

    func testStartStopTogglesConfig() async throws {
        let tool = HookCaptureTool()
        let session = makeSession()

        _ = try await tool.execute(arguments: [
            "op": .string("start"),
            "channel": .string("shell_in"),
            "apiDeny": .string("logsvr, ubc"),
            "sampleEveryN": .number(3)
        ], session: session)

        var channels = (HookCaptureStore.readConfig()["channels"] as? [String: Any]) ?? [:]
        var entry = (channels["shell_in"] as? [String: Any]) ?? [:]
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["apiDeny"] as? [String], ["logsvr", "ubc"])
        XCTAssertEqual((entry["sampleEveryN"] as? NSNumber)?.intValue, 3)

        _ = try await tool.execute(arguments: [
            "op": .string("stop"), "channel": .string("shell_in")
        ], session: session)

        channels = (HookCaptureStore.readConfig()["channels"] as? [String: Any]) ?? [:]
        entry = (channels["shell_in"] as? [String: Any]) ?? [:]
        XCTAssertEqual(entry["enabled"] as? Bool, false)
        // 关闭仅翻转 enabled，保留既有过滤字段。
        XCTAssertEqual(entry["apiDeny"] as? [String], ["logsvr", "ubc"])
    }

    func testStopAllDisablesEveryChannel() async throws {
        let tool = HookCaptureTool()
        let session = makeSession()
        for ch in ["talos_in", "talos_out", "shell_in", "shell_out"] {
            _ = try await tool.execute(arguments: ["op": .string("start"), "channel": .string(ch)], session: session)
        }
        _ = try await tool.execute(arguments: ["op": .string("stop_all")], session: session)
        let channels = (HookCaptureStore.readConfig()["channels"] as? [String: Any]) ?? [:]
        for ch in HookCaptureStore.channels {
            let entry = (channels[ch] as? [String: Any]) ?? [:]
            XCTAssertEqual(entry["enabled"] as? Bool, false, "channel \(ch) should be off")
        }
    }

    func testInvalidChannelRejected() async throws {
        let out = try await HookCaptureTool().execute(
            arguments: ["op": .string("start"), "channel": .string("bogus")], session: makeSession())
        guard case .error = out else { return XCTFail("expected error for invalid channel") }
    }

    func testStatusReportsChannelsAndDir() async throws {
        let out = try await HookCaptureTool().execute(arguments: ["op": .string("status")], session: makeSession())
        let s = try XCTUnwrap(text(out))
        XCTAssertTrue(s.contains("talos_in"))
        XCTAssertTrue(s.contains("LijiMsgCapture"))
    }
}
