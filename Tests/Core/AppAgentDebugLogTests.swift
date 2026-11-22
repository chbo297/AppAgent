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

    // MARK: - 完整诊断载荷

    func testDiagnosticPayloadReassemblesUnicodeAndTrailingError() throws {
        try withDiagnosticLogger { collector in
            let body = String(repeating: "业务\u{1F469}\u{200D}\u{1F4BB}e\u{301}\"\\\r\n", count: 700)
            let tail = #"{"error":{"message":"尾部错误不能丢失"}}"#
            let payload = body + tail
            Logger.diagnosticPayload("DiagnosticTest", metadata: "request=unicode\nstatus=500", payload: payload)

            let lines = collector.lines
            XCTAssertGreaterThan(lines.count, 1)
            let decoded = try reassembleDiagnosticPayload(lines, originalBytes: payload.utf8.count)
            XCTAssertEqual(decoded, payload)
            XCTAssertTrue(decoded.hasSuffix(tail))
            XCTAssertTrue(try XCTUnwrap(lines.first).contains("request=unicode\\nstatus=500"))
            XCTAssertTrue(collector.levels.allSatisfy {
                $0 == .debug
            })
        }
    }

    func testDiagnosticPayloadHonorsEnabledAndMinimumLevel() throws {
        try withDiagnosticLogger { collector in
            let payload = String(repeating: "关闭时不记录", count: 1000)
            Logger.isEnabled = false
            Logger.diagnosticPayload("DiagnosticTest", metadata: "disabled", payload: payload)
            Logger.isEnabled = true
            Logger.minimumLevel = .info
            Logger.diagnosticPayload("DiagnosticTest", metadata: "filtered", payload: payload)
            XCTAssertTrue(collector.lines.isEmpty)

            Logger.minimumLevel = .debug
            Logger.diagnosticPayload("DiagnosticTest", metadata: "enabled", payload: "")
            XCTAssertEqual(collector.lines.count, 1)
            XCTAssertEqual(try reassembleDiagnosticPayload(collector.lines, originalBytes: 0), "")
        }
    }

    func testDiagnosticPayloadForcesRedactionBeforeChunking() throws {
        try withDiagnosticLogger { collector in
            Logger.redactSensitive = false
            let secret = "runtime/\"credential\\part\n-end"
            let encoder = JSONEncoder()
            let encodedSecret = String(decoding: try encoder.encode(secret), as: UTF8.self)
            let credentialValues = [
                "api_key": "shortkey",
                "apiKey": "camel-credential",
                "authorization": "Custom \"opaque value\" tail",
                "token": "plain-token-value",
                "password": "tiny",
                "x_custom_header": "custom-header-value",
                "X-Gateway-Authorization": "gateway-credential"
            ]
            let credentials = String(decoding: try encoder.encode(credentialValues), as: UTF8.self)
            let escapedCredentials = String(decoding: try encoder.encode(credentials), as: UTF8.self)
            let business = #"{"content":"普通业务内容必须保留，token count is 123","max_tokens":4096,"token_count":123}"#

            // 已知凭据横跨原始第 2048 个 Character，且另有 JSON 转义形式和嵌套凭据。
            let prefix = String(repeating: "界", count: 2040)
            let payload = prefix + secret + "\nescaped=" + encodedSecret
                + "\ncredentials=" + credentials + "\nnested=" + escapedCredentials
                + "\n" + String(repeating: "业务", count: 1500) + business
            let metadata = "request=redaction custom=\(secret) escaped=\(encodedSecret) "
                + #"{"password":"metadata-only-value"}"#
            Logger.diagnosticPayload(
                "DiagnosticTest",
                metadata: metadata,
                payload: payload,
                secrets: ["", "credential", secret]
            )

            let lines = collector.lines
            XCTAssertGreaterThan(lines.count, 1)
            let decoded = try reassembleDiagnosticPayload(lines, originalBytes: payload.utf8.count)
            XCTAssertTrue(decoded.hasPrefix(prefix + "<redacted>"))
            XCTAssertTrue(decoded.hasSuffix(business))
            let output = lines.joined(separator: "\n")
            XCTAssertFalse(decoded.contains("opaque value"))
            for value in [secret, String(encodedSecret.dropFirst().dropLast()), "metadata-only-value"]
                + Array(credentialValues.values) {
                XCTAssertFalse(output.contains(value))
                XCTAssertFalse(decoded.contains(value))
            }

            // 裸露的转义 JSON、Unicode 转义凭据也复用同一强制脱敏入口。
            let bareEscaped = String(escapedCredentials.dropFirst().dropLast())
            let redactedBare = Logger.redactDiagnostic(bareEscaped)
            for value in credentialValues.values {
                XCTAssertFalse(redactedBare.contains(value))
            }
            let unicodeSecret = #"{"content":"\u0072untime/\"credential\\part\n-end"}"#
            let safeUnicode = Logger.redactDiagnostic(unicodeSecret, secrets: [secret])
            let unicodeObject = try JSONDecoder().decode([String: String].self, from: Data(safeUnicode.utf8))
            XCTAssertEqual(unicodeObject["content"], "<redacted>")

            // 普通 Logger 开启脱敏时同样识别 JSON 凭据。
            Logger.redactSensitive = true
            Logger.debug("DiagnosticTest", credentials)
            let ordinaryLine = try XCTUnwrap(collector.lines.last)
            for value in credentialValues.values {
                XCTAssertFalse(ordinaryLine.contains(value))
            }
        }
    }

    private func withDiagnosticLogger(_ body: (DiagnosticLogCollector) throws -> Void) rethrows {
        let savedEnabled = Logger.isEnabled
        let savedMinimumLevel = Logger.minimumLevel
        let savedHandler = Logger.handler
        let savedRedactSensitive = Logger.redactSensitive
        defer {
            Logger.isEnabled = false
            Logger.handler = savedHandler
            Logger.minimumLevel = savedMinimumLevel
            Logger.redactSensitive = savedRedactSensitive
            Logger.isEnabled = savedEnabled
        }

        let collector = DiagnosticLogCollector()
        Logger.handler = { level, line in
            if line.hasPrefix("[AppAgent] [DEBUG] [DiagnosticTest] ") {
                collector.append(level: level, line: line)
            }
        }
        Logger.minimumLevel = .debug
        Logger.redactSensitive = true
        Logger.isEnabled = true
        try body(collector)
    }

    private func reassembleDiagnosticPayload(_ lines: [String], originalBytes: Int) throws -> String {
        XCTAssertFalse(lines.isEmpty)
        var payload = ""
        for (index, line) in lines.enumerated() {
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("\r"))
            let marker = try XCTUnwrap(line.range(of: " payload="))
            XCTAssertTrue(line[..<marker.lowerBound].hasSuffix("bytes=\(originalBytes) part=\(index + 1)/\(lines.count)"))
            let chunk = try JSONDecoder().decode(String.self, from: Data(line[marker.upperBound...].utf8))
            XCTAssertLessThanOrEqual(chunk.count, 2048)
            if index + 1 < lines.count {
                XCTAssertEqual(chunk.count, 2048)
            }
            payload += chunk
        }
        return payload
    }

    // MARK: - 落盘日志 + 诊断包

    func testRunLogRotatesWithinSameSecondAndKeepsNewestFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog-rotation-\(UUID().uuidString)", isDirectory: true)
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let runLog = AppAgentRunLog(directory: dir, now: {
            instant
        })
        defer {
            runLog.clear()
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(runLog.maxFileBytes, 2 * 1024 * 1024)
        XCTAssertEqual(runLog.maxFiles, 3)
        runLog.maxFileBytes = 8
        runLog.maxFiles = 3
        var created: [URL] = []

        for index in 0..<12 {
            let message = String(format: "line-%02d", index)
            runLog.append(message)
            runLog.flush()
            let files = runLog.files()
            XCTAssertEqual(files.count, min(index + 1, runLog.maxFiles))
            let newest = try XCTUnwrap(files.last)
            created.append(newest)
            XCTAssertEqual(try String(contentsOf: newest, encoding: .utf8), message + "\n")
        }

        XCTAssertEqual(Set(created).count, 12)
        XCTAssertEqual(created, created.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        })
        XCTAssertTrue(created.allSatisfy {
            $0.lastPathComponent.hasPrefix("appagent-\(AppAgentRunLog.fileStamp(instant))_")
        })
        XCTAssertEqual(runLog.files(), Array(created.suffix(runLog.maxFiles)))
        let retained = try runLog.files().map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        XCTAssertEqual(retained, ["line-09\n", "line-10\n", "line-11\n"])
    }

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

    /// 宿主补充方在导出时拿到自己的 host/<name>/ 目录写入，返回的说明进清单；抛错只记失败不中断导出。
    func testDiagnosticsHostContributorWritesIntoItsDirectory() throws {
        let name = "contrib-\(UUID().uuidString.prefix(8))"
        let written = Locked<Bool>(wrappedValue: false)
        AppAgentDiagnostics.registerHostContributor(name: name) { directory in
            let file = directory.appendingPathComponent("status.json")
            try Data("{}".utf8).write(to: file)
            written.mutate { value in
                value = FileManager.default.fileExists(atPath: file.path)
            }
            return "宿主状态摘要"
        }
        AppAgentDiagnostics.registerHostContributor(name: name + "-fail") { _ in
            throw CocoaError(.fileWriteUnknown)
        }

        let bundle = try AppAgentDiagnostics.exportSync(debugLog: AppAgentDebugLog(capacity: 1))
        defer {
            try? FileManager.default.removeItem(at: bundle.url)
        }

        XCTAssertTrue(written.wrappedValue)
        XCTAssertTrue(bundle.manifest.contains("host/\(name)/ — 宿主状态摘要"), "\(bundle.manifest)")
        XCTAssertTrue(bundle.manifest.contains { line in
            line.hasPrefix("host/\(name)-fail/ — 宿主补充失败")
        }, "\(bundle.manifest)")
    }

    func testRecentFileCopyKeepsNewestWithinByteLimit() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("host-dir-\(UUID().uuidString)", isDirectory: true)
        let dest = fm.temporaryDirectory.appendingPathComponent("host-copy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: dest)
        }
        let now = Date()
        for (index, name) in ["old.json", "mid.json", "new.json"].enumerated() {
            let url = source.appendingPathComponent(name)
            try Data(repeating: 0x61, count: 40).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(index) * 10)], ofItemAtPath: url.path)
        }

        let result = AppAgentDiagnostics.copyRecentFiles(source, to: dest, maxBytes: 100)

        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dest.path).sorted(), ["mid.json", "new.json"])
    }
}

private final class DiagnosticLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: AppAgentLogLevel, line: String)] = []

    func append(level: AppAgentLogLevel, line: String) {
        lock.lock()
        defer {
            lock.unlock()
        }
        entries.append((level, line))
    }

    var lines: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return entries.map {
            $0.line
        }
    }

    var levels: [AppAgentLogLevel] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return entries.map {
            $0.level
        }
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
