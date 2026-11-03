import XCTest
@testable import AppAgent

final class LLMStreamFailureTests: XCTestCase {
    func testProtocolFailuresAreNotLoggedAsSuccessAndCarryRequestID() async throws {
        let previousEnabled = AppAgentDebugLog.shared.isEnabled
        AppAgentDebugLog.shared.isEnabled = true
        defer {
            AppAgentDebugLog.shared.isEnabled = previousEnabled
        }
        let reasons: [ProviderStreamEvent.StopReason?] = [.endTurn, .unknown, nil]
        for reason in reasons {
            let provider = PartialFailureProvider(failures: 0, finishReason: reason)
            let central = ModelProviderCentral()
            await central.register(name: "p", provider: provider)
            let agent = makeAgent(central: central, policy: ModelPolicy(primary: "p/m"))
            let session = await agent.createSession(title: "协议日志回归")
            let executor = LLMExecutor(session: session, retryPolicy: RetryPolicy(maxRetries: 0))
            for await _ in executor.run("测试") {
                // 通过真实执行器生成请求与终态摘要。
            }
            let records = AppAgentDebugLog.shared.snapshot().filter {
                $0.sessionId == session.id
            }
            XCTAssertEqual(records.map(\.kind), [.request, reason == .endTurn ? .success : .failure])
            let requestID = try XCTUnwrap(records.first?.requestId)
            XCTAssertEqual(records.last?.requestId, requestID)
            XCTAssertEqual(provider.requestIDs, [requestID])
            if reason != .endTurn {
                XCTAssertEqual(records.last?.reason, "stream_protocol")
            }
        }
    }

    func testRawResponseSurvivesLongFrameUnknownFormatAndEOFFlush() throws {
        let oldEnabled = Logger.isEnabled
        let oldLevel = Logger.minimumLevel
        let oldHandler = Logger.handler
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-log-test-\(UUID().uuidString)", isDirectory: true)
        let runLog = AppAgentRunLog(directory: dir)
        Logger.isEnabled = true
        Logger.minimumLevel = .debug
        Logger.handler = { _, message in
            runLog.append(message)
        }
        defer {
            Logger.handler = oldHandler
            Logger.minimumLevel = oldLevel
            Logger.isEnabled = oldEnabled
            runLog.flush()
            try? FileManager.default.removeItem(at: dir)
        }
        let prefix = String(repeating: "附近🍜", count: 1200)
        let payload = #"{"type":"response.failed","response":{"id":"resp-test","error":{"message":""#
            + prefix + #"尾部错误详情","code":"server_error"}}}"#
        let trace = ProviderWireTrace(requestID: "wire-test", apiProtocol: .openaiResponses, secrets: [])
        var decoder = ProviderSSEStreamDecoder(apiProtocol: .openaiResponses, trace: trace)
        XCTAssertTrue(try decoder.processLine("unexpected gateway text").isEmpty)
        XCTAssertTrue(try decoder.processLine("event: response.failed").isEmpty)
        XCTAssertTrue(try decoder.processLine("data: \(payload)").isEmpty)
        XCTAssertThrowsError(try decoder.finish()) { error in
            guard case ModelError.upstreamError(_, let code, let message) = error else {
                return XCTFail("EOF 必须传播缓存的原始上游错误")
            }
            XCTAssertEqual(code, "server_error")
            XCTAssertEqual(message, prefix + "尾部错误详情")
        }
        let log = runLog.exportText()
        XCTAssertTrue(log.contains("unexpected gateway text"))
        XCTAssertTrue(log.contains("phase=sse_flush"))
        let pieces = try log.components(separatedBy: "\n").filter {
            $0.contains("phase=response_line seq=3 ")
        }.map { line -> String in
            let range = try XCTUnwrap(line.range(of: " payload="))
            return try JSONDecoder().decode(String.self, from: Data(line[range.upperBound...].utf8))
        }
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), "data: \(payload)")
    }

    func testRetryOnlyPersistsFinalAttemptTextAndNeverUnexecutedCalls() async throws {
        for failures in [1, 2] {
            let provider = PartialFailureProvider(failures: failures)
            let central = ModelProviderCentral()
            await central.register(name: "p", provider: provider)
            let agent = makeAgent(central: central, policy: ModelPolicy(primary: "p/m"))
            let session = await agent.createSession(title: "流失败回归")
            let executor = LLMExecutor(
                session: session,
                retryPolicy: RetryPolicy(maxRetries: 1, baseDelay: 0, jitterFactor: 0)
            )
            var terminals = 0
            for await event in executor.run("测试") {
                switch event {
                case .completed, .error: terminals += 1
                default: break
                }
            }
            XCTAssertEqual(terminals, 1)
            XCTAssertEqual(provider.requests.count, 2)
            XCTAssertTrue(provider.requests.allSatisfy { request in
                !request.contains { $0.role == .assistant }
            }, "失败尝试的半截正文和未执行调用不能进入重试请求")
            let replies = session.messages.filter { $0.role == .assistant }
            XCTAssertEqual(replies.map(\.text), [failures == 1 ? "完整回答" : "半截回答 2"])
            XCTAssertTrue(replies.allSatisfy { $0.toolCalls.isEmpty })
            XCTAssertEqual(replies.first?.turnID, 1)
            let record = try XCTUnwrap(session.turnRecord(turnID: 1))
            XCTAssertTrue(record.isFinished)
            if failures == 1 {
                XCTAssertEqual(record.outcome, .answered)
            } else {
                XCTAssertEqual(record.failedStage, .streaming)
            }
        }
    }

    func testFallbackDoesNotPersistFailedProvidersPartialText() async throws {
        let central = ModelProviderCentral()
        let primary = PartialFailureProvider(failures: 1)
        let fallback = PartialFailureProvider(name: "fallback", failures: 0)
        await central.register(name: "p", provider: primary)
        await central.register(name: "q", provider: fallback)
        let agent = makeAgent(central: central, policy: ModelPolicy(primary: "p/m", fallbacks: ["q/m"]))
        let session = await agent.createSession(title: "流回退回归")
        let executor = LLMExecutor(session: session, retryPolicy: RetryPolicy(maxRetries: 0))
        for await _ in executor.run("测试") {}
        XCTAssertEqual(primary.requests.count, 1)
        // 候选先做一次真实可用性探测，再用同一模型重放原始请求。
        XCTAssertEqual(fallback.requests.count, 2)
        XCTAssertFalse(fallback.requests.flatMap { $0 }.contains { $0.role == .assistant })
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }.map(\.text), ["完整回答"])
        XCTAssertEqual(session.turnRecord(turnID: 1)?.outcome, .answered)
    }

    func testSSEErrorsPreserveProtocolDetailsAndRetryOnlyKnownTransientFailures() throws {
        let cases: [(APIProtocol, String, String?, String?, FailoverReason, Bool)] = [
            (.anthropicMessages, #"{"type":"error","error":{"type":"overloaded_error","message":"原始错误"}}"#,
             "overloaded_error", nil, .overloaded, true),
            (.openaiCompletions, #"{"error":{"type":"rate_limit_error","code":"insufficient_quota","message":"原始错误"}}"#,
             "rate_limit_error", "insufficient_quota", .billing, false),
            (.openaiResponses, #"{"type":"response.failed","response":{"error":{"code":"server_error","message":"原始错误"}}}"#,
             "response.failed", "server_error", .serverError, true),
            (.openaiResponses, #"{"type":"error","code":"rate_limit_exceeded","message":"原始错误"}"#,
             "error", "rate_limit_exceeded", .rateLimited, true),
            (.anthropicMessages, #"{"type":"error","error":{"type":"authentication_error","message":"原始错误"}}"#,
             "authentication_error", nil, .authError, false),
            (.openaiResponses, #"{"type":"error","code":"invalid_request","message":"原始错误"}"#,
             "error", "invalid_request", .formatError, false),
            (.openaiResponses, #"{"type":"error","code":"future_error","message":"原始错误"}"#,
             "error", "future_error", .unknown, false)
        ]
        for (apiProtocol, payload, expectedType, expectedCode, reason, retryable) in cases {
            let trace = ProviderWireTrace(requestID: "error-test", apiProtocol: apiProtocol, secrets: [])
            var decoder = ProviderSSEStreamDecoder(apiProtocol: apiProtocol, trace: trace)
            _ = try decoder.processLine("data: \(payload)")
            XCTAssertThrowsError(try decoder.processLine("")) { error in
                guard case ModelError.upstreamError(let type, let code, let message) = error else {
                    return XCTFail("必须抛出结构化流错误")
                }
                XCTAssertEqual(type, expectedType)
                XCTAssertEqual(code, expectedCode)
                XCTAssertEqual(message, "原始错误")
                let classified = ErrorClassifier.classify(error)
                XCTAssertEqual(classified.reason, reason)
                XCTAssertEqual(classified.retryable, retryable)
                XCTAssertTrue(classified.shouldFallback)
            }
        }
    }

    func testResponsesFailuresUseBoundedRetryAndFallbackWithoutExecutingTools() async throws {
        let cases = [
            (code: "server_error", failures: 1, fallback: false, attempts: 2),
            (code: "server_error", failures: 2, fallback: false, attempts: 2),
            (code: "future_error", failures: 2, fallback: false, attempts: 1),
            (code: "invalid_api_key", failures: 2, fallback: false, attempts: 1),
            (code: "server_error", failures: 2, fallback: true, attempts: 2)
        ]
        for scenario in cases {
            let message = "Our servers are currently overloaded. Please try again later."
            let failure = #"data: {"type":"response.failed","response":{"error":{"code":""#
                + scenario.code + #"","message":""# + message + #""}}}"#
            // 无正文的失败也必须能在重试耗尽后回退。
            let prefix = scenario.fallback ? [] : [
                #"data: {"type":"response.output_text.delta","delta":"半截正文"}"#, "",
                #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"pending","name":"never_execute","arguments":"{}"}}"#, ""
            ]
            let primary = PartialFailureProvider(failures: scenario.failures, failureLines: prefix + [failure])
            let fallback = PartialFailureProvider(failures: 0)
            let central = ModelProviderCentral()
            await central.register(name: "p", provider: primary)
            await central.register(name: "q", provider: fallback)
            let agent = makeAgent(central: central, policy: ModelPolicy(
                primary: "p/m", fallbacks: scenario.fallback ? ["q/m"] : []
            ))
            let session = await agent.createSession(title: "Responses 流回归")
            let executor = LLMExecutor(
                session: session, retryPolicy: RetryPolicy(maxRetries: 1, baseDelay: 0, jitterFactor: 0)
            )
            var terminals = 0
            var failureMessage: String?
            for await event in executor.run("测试") {
                switch event {
                case .completed:
                    terminals += 1
                case .error(let error):
                    terminals += 1
                    failureMessage = error.localizedDescription
                case .toolCallStarted, .toolCallCompleted:
                    XCTFail("失败响应中的调用不得进入工具执行")
                default:
                    break
                }
            }
            XCTAssertEqual(terminals, 1)
            XCTAssertEqual(primary.requests.count, scenario.attempts)
            XCTAssertEqual(fallback.requests.count, scenario.fallback ? 2 : 0)
            XCTAssertFalse((primary.requests + fallback.requests).flatMap {
                $0
            }.contains {
                $0.role == .assistant
            })
            let replies = session.messages.filter {
                $0.role == .assistant
            }
            XCTAssertTrue(replies.allSatisfy {
                $0.toolCalls.isEmpty
            })
            if scenario.failures == 1 || scenario.fallback {
                XCTAssertNil(failureMessage)
                XCTAssertEqual(replies.map(\.text), ["完整回答"])
                XCTAssertEqual(session.turnRecord(turnID: 1)?.outcome, .answered)
            } else {
                XCTAssertTrue(try XCTUnwrap(failureMessage).contains(scenario.code))
                XCTAssertTrue(try XCTUnwrap(failureMessage).contains(message))
                XCTAssertEqual(replies.map(\.text), ["半截正文"])
                XCTAssertEqual(session.turnRecord(turnID: 1)?.failedStage, .streaming)
            }
        }
    }

    func testResponsesOnlyReleaseCompleteValidToolCalls() throws {
        let terminals = [
            #"{"type":"response.failed","response":{"error":{"code":"server_error","message":"failed"}}}"#,
            #"{"type":"response.failed","response":{"error":null}}"#,
            #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
            "[DONE]"
        ]
        for terminal in terminals {
            var calls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [
                0: (id: "pending", name: "never_execute", arguments: #"{"unfinished":"#)
            ]
            let event = SSEEvent(event: "", data: terminal)
            if terminal == "[DONE]" {
                XCTAssertTrue(try OpenAIResponsesMapper.parseSSEEvent(event, activeToolCalls: &calls).isEmpty)
            } else {
                XCTAssertThrowsError(try OpenAIResponsesMapper.parseSSEEvent(event, activeToolCalls: &calls))
            }
            XCTAssertTrue(calls.isEmpty)
        }
    }

    private func makeAgent(central: ModelProviderCentral, policy: ModelPolicy) -> AIAgent {
        AIAgent(
            id: "stream-failure-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            toolCentral: ToolCentral(),
            providerCentral: central,
            modelPolicy: policy,
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
    }
}

private final class PartialFailureProvider: ModelProvider, @unchecked Sendable {
    let name: String
    let baseURL = ""
    let apiKey = ""
    var apiProtocol: APIProtocol {
        failureLines == nil ? .anthropicMessages : .openaiResponses
    }
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    let failures: Int
    let finishReason: ProviderStreamEvent.StopReason?
    let failureLines: [String]?
    @Locked private(set) var requests: [[AIAgentMessage]] = []
    @Locked private(set) var requestIDs: [String?] = []

    init(
        name: String = "partial-failure",
        failures: Int,
        finishReason: ProviderStreamEvent.StopReason? = .endTurn,
        failureLines: [String]? = nil
    ) {
        self.name = name
        self.failures = failures
        self.finishReason = finishReason
        self.failureLines = failureLines
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        $requestIDs.mutate {
            $0.append(ModelRequestLogContext.requestID)
        }
        let attempt = $requests.mutate { requests in
            requests.append(messages)
            return requests.count
        }
        return AsyncThrowingStream { continuation in
            if attempt <= failures {
                if let failureLines {
                    let trace = ProviderWireTrace(requestID: "fixture", apiProtocol: apiProtocol, secrets: [])
                    var decoder = ProviderSSEStreamDecoder(apiProtocol: apiProtocol, trace: trace)
                    do {
                        for line in failureLines {
                            for event in try decoder.processLine(line) {
                                continuation.yield(event)
                            }
                        }
                        for event in try decoder.finish() {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                continuation.yield(.textDelta("半截回答 \(attempt)"))
                continuation.yield(.toolCall(.init(id: "unexecuted", name: "never_execute", arguments: [:])))
                continuation.finish(throwing: ModelError.httpError(statusCode: 503, body: "流中断"))
            } else {
                continuation.yield(.textDelta("完整回答"))
                if let finishReason {
                    continuation.yield(.done(stopReason: finishReason))
                }
                continuation.finish()
            }
        }
    }
}
