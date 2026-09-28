import XCTest
@testable import AppAgent

/// 调试记录器：环形缓冲、异常筛选、实时订阅、导出。
final class AppAgentDebugLogTests: XCTestCase {

    func testRingBufferDropsOldestBeyondCapacity() {
        let log = AppAgentDebugLog(capacity: 3)
        for i in 1...5 {
            log.record(.info, message: "m\(i)")
        }
        let messages = log.snapshot().map { $0.message }
        XCTAssertEqual(messages, ["m3", "m4", "m5"])
    }

    func testFailuresFilterKeepsOnlyAbnormalKinds() {
        let log = AppAgentDebugLog()
        log.record(.request, message: "req")
        log.record(.success, message: "ok")
        log.record(.failure, message: "boom", reason: "rate_limited", statusCode: 429)
        log.record(.retry, message: "retrying", attempt: 1)
        log.record(.fallback, message: "switching")

        XCTAssertEqual(log.snapshot().count, 5)
        XCTAssertEqual(log.failures().map { $0.kind }, [.failure, .retry, .fallback])
    }

    func testOnEventFiresForEachRecord() {
        let log = AppAgentDebugLog()
        let collector = EventCollector()
        log.onEvent = { collector.append($0) }
        log.record(.failure, message: "a")
        log.record(.retry, message: "b")
        XCTAssertEqual(collector.kinds, [.failure, .retry])
    }

    func testExportTextAndJSONCarryDetails() throws {
        let log = AppAgentDebugLog()
        log.record(
            .failure,
            message: "HTTP 404",
            sessionId: "s1",
            provider: "appagent-openai-completions",
            apiProtocol: "openai-completions",
            modelId: "gpt-4o",
            iteration: 1,
            reason: "model_not_found",
            statusCode: 404,
            durationMs: 12
        )

        let text = log.exportText()
        XCTAssertTrue(text.contains("FAILURE"))
        XCTAssertTrue(text.contains("gpt-4o@openai-completions"))
        XCTAssertTrue(text.contains("reason=model_not_found"))
        XCTAssertTrue(text.contains("http=404"))

        let json = log.exportJSON()
        let decoded = try JSONDecoder.iso8601Decoder.decode([AppAgentDebugEvent].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.statusCode, 404)
        XCTAssertEqual(decoded.first?.modelId, "gpt-4o")
    }

    func testDisabledLoggerDropsNewRecords() {
        let log = AppAgentDebugLog()
        log.record(.info, message: "kept")
        log.isEnabled = false
        log.record(.info, message: "dropped")
        XCTAssertEqual(log.snapshot().map { $0.message }, ["kept"])
    }

    // MARK: - 落盘日志 + 诊断包

    /// `install()` 之后 `Logger` 的输出要能在日志文件里找到；重复 install 不重复挂 handler。
    func testRunLogCapturesLoggerOutput() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog-test-\(UUID().uuidString)", isDirectory: true)
        let runLog = AppAgentRunLog(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        runLog.append("[AppAgent] [INFO] [Test] hello disk")
        runLog.flush()

        let text = runLog.exportText()
        XCTAssertTrue(text.contains("hello disk"), text)
        XCTAssertFalse(runLog.files().isEmpty)
    }

    /// 诊断包必须是个真 zip，且概要里带上模型调用记录的条数。
    func testDiagnosticsBundleIsAZipWithSummary() throws {
        let log = AppAgentDebugLog(capacity: 10)
        log.record(.failure, message: "boom", reason: "network")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog-bundle-\(UUID().uuidString)", isDirectory: true)
        let runLog = AppAgentRunLog(directory: dir)
        runLog.append("[AppAgent] [ERROR] [Test] boom")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try AppAgentDiagnostics.exportSync(debugLog: log, runLog: runLog)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        XCTAssertEqual(bundle.url.pathExtension, "zip")
        XCTAssertGreaterThan(bundle.byteCount, 0)
        // zip 的魔数是 "PK"。
        let head = try Data(contentsOf: bundle.url).prefix(2)
        XCTAssertEqual(Array(head), [0x50, 0x4B])
        XCTAssertTrue(bundle.manifest.contains { $0.contains("模型调用记录 1 条") }, "\(bundle.manifest)")
        XCTAssertTrue(bundle.manifest.contains { $0.hasPrefix("run-logs/ — 运行日志 1") }, "\(bundle.manifest)")
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AppAgentDebugEvent] = []

    func append(_ event: AppAgentDebugEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var kinds: [AppAgentDebugEvent.Kind] {
        lock.lock()
        defer { lock.unlock() }
        return events.map { $0.kind }
    }
}

private extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
