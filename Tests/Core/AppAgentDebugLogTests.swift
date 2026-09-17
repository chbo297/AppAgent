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
