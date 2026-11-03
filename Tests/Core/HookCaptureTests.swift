import XCTest
@testable import AppAgent

/// app_hook_capture 工具与 HookCaptureStore 的测试：config 的 JSON 形状与开关语义，
/// 以及读路径的磁盘契约（seq 排序 / limit 取尾 / sinceSeq 增量）。写入方在宿主侧，
/// 所以读路径的用例自己按契约造 JSONL，只删自己写的文件。用完清理共享 key。
final class HookCaptureTests: XCTestCase {

    private let configKey = HookCaptureStore.configKey
    private var previousConfig: Any?

    override func setUp() {
        super.setUp()
        previousConfig = UserDefaults.standard.object(forKey: configKey)
    }

    override func tearDown() {
        if let previousConfig {
            UserDefaults.standard.set(previousConfig, forKey: configKey)
        } else {
            UserDefaults.standard.removeObject(forKey: configKey)
        }
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
            "channel": .string("bridge_in"),
            "apiDeny": .string("logsvr, ubc"),
            "sampleEveryN": .number(3)
        ], session: session)

        var channels = (HookCaptureStore.readConfig()["channels"] as? [String: Any]) ?? [:]
        var entry = (channels["bridge_in"] as? [String: Any]) ?? [:]
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["apiDeny"] as? [String], ["logsvr", "ubc"])
        XCTAssertEqual((entry["sampleEveryN"] as? NSNumber)?.intValue, 3)

        _ = try await tool.execute(arguments: [
            "op": .string("stop"), "channel": .string("bridge_in")
        ], session: session)

        channels = (HookCaptureStore.readConfig()["channels"] as? [String: Any]) ?? [:]
        entry = (channels["bridge_in"] as? [String: Any]) ?? [:]
        XCTAssertEqual(entry["enabled"] as? Bool, false)
        // 关闭仅翻转 enabled，保留既有过滤字段。
        XCTAssertEqual(entry["apiDeny"] as? [String], ["logsvr", "ubc"])
    }

    func testStopAllDisablesEveryChannel() async throws {
        let tool = HookCaptureTool()
        let session = makeSession()
        for ch in ["bridge_in", "bridge_out", "page_console", "page_navigation"] {
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
            arguments: ["op": .string("start"), "channel": .string("../escape")], session: makeSession())
        guard case .error = out else { return XCTFail("expected error for invalid channel") }
    }

    func testStatusReportsChannelsAndDir() async throws {
        _ = try await HookCaptureTool().execute(
            arguments: ["op": .string("start"), "channel": .string("bridge_in")],
            session: makeSession()
        )
        let status = try await HookCaptureTool().execute(
            arguments: ["op": .string("status")],
            session: makeSession()
        )
        let s = try XCTUnwrap(text(status))
        XCTAssertTrue(s.contains("bridge_in"))
        XCTAssertTrue(s.contains("AppAgentMsgCapture"))
    }

    /// 读路径的磁盘契约。写入方在仓库外（宿主侧缝点），所以这里自己按契约造 JSONL：
    /// **跨文件、seq 故意乱序**。三条策略必须同时成立，否则模型读到的是错序/错窗口的消息流。
    func testRecordsSortBySeqAcrossFilesAndHonorLimitAndSince() throws {
        let channel = "page_navigation"
        let other = "bridge_in"
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

    func testReadSeparatesContainersPagesAndProcessRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
        }
        let fixture: [[String: Any]] = [
            ["runId": "old", "seq": 999, "ts": 10, "webviewId": "a", "pageId": "p1", "callId": "same"],
            ["runId": "new", "seq": 1, "ts": 20, "webviewId": "a", "pageId": "p1", "callId": "same"],
            ["runId": "new", "seq": 2, "ts": 21, "webviewId": "b", "pageId": "p1", "callId": "same"],
            ["runId": "new", "seq": 3, "ts": 22, "webviewId": "a", "pageId": "p2", "callId": "same"],
            ["runId": "new", "seq": 4, "ts": 23, "webviewId": "a", "pageId": "p2", "callId": "other"],
            ["runId": "new", "ts": 24, "webviewId": "a", "pageId": "p2", "callId": "same"]
        ]
        let data = try fixture.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n")
        try data.write(to: dir.appendingPathComponent("cap_bridge_in_fixture.jsonl"), atomically: true, encoding: .utf8)

        let recent = HookCaptureStore.readSnapshot(
            directory: dir.path, channel: "bridge_in", limit: 1, sinceSeq: nil
        )
        let last = try XCTUnwrap(recent["records"] as? [[String: Any]]).first
        XCTAssertEqual(last?["ts"] as? Int, 24, "old process seq=999 must not hide new process records")

        let selected = HookCaptureStore.readSnapshot(
            directory: dir.path, channel: "bridge_in", limit: 50, sinceSeq: 1,
            webviewId: "a", callId: "same", runId: "new", pageId: "p2"
        )
        let rows = try XCTUnwrap(selected["records"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["seq"] as? Int, 3)
        let cursor = try XCTUnwrap(selected["nextCursor"] as? [String: Any])
        XCTAssertEqual(cursor["runId"] as? String, "new")
        XCTAssertEqual((cursor["sinceSeq"] as? NSNumber)?.intValue, 3)

        let ambiguous = HookCaptureStore.readSnapshot(
            directory: dir.path, channel: "bridge_in", limit: 50, sinceSeq: 999
        )
        XCTAssertEqual(ambiguous["count"] as? Int, 0)
        XCTAssertTrue((ambiguous["warnings"] as? [String] ?? []).contains("sinceSeq_requires_runId"))
    }

    func testBoundedTailReportsMissingEvidenceWithoutParsingPartialLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
        }
        let lines = """
        {"seq":1,"argsPreview":"\(String(repeating: "汉", count: 300))"}
        {"seq":2,"webviewId":"wanted"}
        {"seq":3,"webviewId":"other"}

        """
        try lines.write(to: dir.appendingPathComponent("cap_bridge_in_fixture.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = HookCaptureStore.readSnapshot(
            directory: dir.path, channel: "bridge_in", limit: 50, sinceSeq: nil,
            webviewId: "wanted", maxScanBytes: 100
        )
        let rows = try XCTUnwrap(snapshot["records"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["seq"] as? Int, 2)
        XCTAssertEqual(snapshot["scanTruncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(snapshot["scannedBytes"] as? Int ?? Int.max, 100)
        let warnings = snapshot["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains {
            $0.hasPrefix("scan_budget_reached")
        })
    }

    func testReadDoesNotFollowCaptureFileSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let external = root.appendingPathComponent("other-data.jsonl")
        try "{\"seq\":1}".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("cap_bridge_in_link.jsonl"), withDestinationURL: external
        )
        let snapshot = HookCaptureStore.readSnapshot(
            directory: dir.path, channel: "bridge_in", limit: 50, sinceSeq: nil
        )
        XCTAssertEqual(snapshot["count"] as? Int, 0)
        XCTAssertEqual(snapshot["scannedFiles"] as? Int, 0)
    }

    func testToolRejectsAmbiguousCursorAndInvalidNumbersWithoutMutation() async throws {
        let tool = HookCaptureTool()
        let original = UserDefaults.standard.string(forKey: configKey)
        let invalidArguments: [[String: JSONValue]] = [
            ["op": .string("read"), "channel": .string("bridge_in"), "sinceSeq": .number(1)],
            ["op": .string("start"), "channel": .string("bridge_in"), "sampleEveryN": .number(.infinity)],
            ["op": .string("start"), "channel": .string("bridge_in"), "maxPreviewBytes": .number(1e30)],
            ["op": .string("read"), "channel": .string("bridge_in"), "limit": .number(2.5)],
            ["op": .string("read"), "channel": .string("bridge_in"), "webviewId": .string("")],
            ["op": .string("clear"), "channel": .number(1)],
            ["op": .string("start"), "channel": .string("bridge_in"), "apiAllow": .number(1)]
        ]
        for invalid in invalidArguments {
            let output = try await tool.execute(arguments: invalid, session: makeSession())
            guard case .error = output else {
                return XCTFail("invalid capture arguments must fail")
            }
            XCTAssertEqual(UserDefaults.standard.string(forKey: configKey), original)
        }
    }
}
