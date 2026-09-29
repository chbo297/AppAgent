import XCTest
@testable import AppAgent

/// app_hook_capture 工具与 HookCaptureStore 的测试：config 的 JSON 形状与开关语义，
/// 以及读路径的磁盘契约（seq 排序 / limit 取尾 / sinceSeq 增量）。写入方在宿主侧，
/// 所以读路径的用例自己按契约造 JSONL，只删自己写的文件。用完清理共享 key。
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
        XCTAssertTrue(s.contains("AppAgentMsgCapture"))
    }

    /// 读路径的磁盘契约。写入方在仓库外（宿主侧缝点），所以这里自己按契约造 JSONL：
    /// **跨文件、seq 故意乱序**。三条策略必须同时成立，否则模型读到的是错序/错窗口的消息流。
    func testRecordsSortBySeqAcrossFilesAndHonorLimitAndSince() throws {
        let channel = "web_nav"
        let other = "talos_in"
        // 真机上这个目录由宿主写入方在用。只在两个 channel 都没有真实数据时才跑，
        // 且只删自己写的文件——绝不 clear 一个可能有别人数据的 channel。
        guard HookCaptureStore.files(channel: channel).isEmpty,
              HookCaptureStore.files(channel: other).isEmpty else {
            throw XCTSkip("捕获目录已有真实数据，跳过以免误删")
        }
        let dir = HookCaptureStore.directory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var written: [String] = []
        func write(_ name: String, seqs: [Int]) throws {
            let path = (dir as NSString).appendingPathComponent(name)
            let lines = seqs.map { "{\"seq\":\($0),\"api\":\"n\($0)\"}" }.joined(separator: "\n")
            try lines.write(toFile: path, atomically: true, encoding: .utf8)
            written.append(path)
        }
        defer { written.forEach { try? FileManager.default.removeItem(atPath: $0) } }

        // 后一个文件里放更小的 seq：只按文件名拼接就会错序。
        try write("cap_\(channel)_1.jsonl", seqs: [3, 1])
        try write("cap_\(channel)_2.jsonl", seqs: [4, 2])
        try write("cap_\(other)_9.jsonl", seqs: [1])

        let all = HookCaptureStore.records(channel: channel, limit: 50, sinceSeq: nil)
        XCTAssertEqual(all.compactMap { ($0["seq"] as? NSNumber)?.intValue }, [1, 2, 3, 4])

        // limit 取的是尾部（最新），不是头部。
        let tail = HookCaptureStore.records(channel: channel, limit: 2, sinceSeq: nil)
        XCTAssertEqual(tail.compactMap { ($0["seq"] as? NSNumber)?.intValue }, [3, 4])

        // sinceSeq 是严格大于，用于增量轮询时不重复读同一条。
        let since = HookCaptureStore.records(channel: channel, limit: 50, sinceSeq: 2)
        XCTAssertEqual(since.compactMap { ($0["seq"] as? NSNumber)?.intValue }, [3, 4])

        // 按 channel 删干净，且不碰其他 channel。
        XCTAssertEqual(HookCaptureStore.clear(channel: channel), 2)
        XCTAssertTrue(HookCaptureStore.records(channel: channel, limit: 50, sinceSeq: nil).isEmpty)
        XCTAssertFalse(HookCaptureStore.files(channel: other).isEmpty)
    }
}
