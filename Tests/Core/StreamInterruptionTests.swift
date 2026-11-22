import XCTest
@testable import AppAgent

/// 「切后台再回来，界面就不动了」这一类打断的回归。
///
/// 真机上的故障链是：进程被冻结 → SSE 连接被撕掉 → `URLSession.bytes` 既不吐字节也不抛错
/// → 执行循环停在 `for try await` 上等 CFNetwork 的 300s 空闲超时。这里用「吐半截然后永远
/// 静默」的假 provider 把那条链复现出来，断言 25s 级的看门狗把它变成一次可恢复的重试。
final class StreamInterruptionTests: XCTestCase {

    func testNetworkRetryExhaustionAndRecoveryShareOneTerminal() async throws {
        for failures in [1, 4] {
            let provider = failures == 1
                ? NetworkFailureProvider(failures: failures, error: URLError(.networkConnectionLost))
                : NetworkFailureProvider(failures: failures)
            let fallback = NetworkFailureProvider(failures: 0)
            let central = ModelProviderCentral()
            await central.register(name: "p", provider: provider)
            await central.register(name: "q", provider: fallback)
            let agent = AIAgent(
                id: "network-\(UUID().uuidString)",
                profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
                toolCentral: ToolCentral(), providerCentral: central,
                modelPolicy: ModelPolicy(primary: "p/m", fallbacks: ["q/m"]),
                memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
            )
            let session = await agent.createSession(title: "网络终局")
            let executor = LLMExecutor(
                session: session,
                retryPolicy: RetryPolicy(baseDelay: 0, jitterFactor: 0)
            )
            var terminals = 0
            var finalError: Error?
            for await event in executor.run("测试") {
                switch event {
                case .completed:
                    terminals += 1
                case .error(let error):
                    terminals += 1
                    finalError = error
                default:
                    break
                }
            }
            XCTAssertEqual(terminals, 1)
            XCTAssertEqual(provider.attempts, failures == 1 ? 2 : 4)
            XCTAssertEqual(fallback.attempts, 0, "连接故障即使有半截正文也不探测其他模型")
            let record = try XCTUnwrap(session.turnRecord(turnID: 1))
            if failures == 1 {
                XCTAssertNil(finalError)
                XCTAssertNil(session.uiState.lastError)
                XCTAssertNil(record.failureMessage)
                XCTAssertEqual(record.outcome, .answered)
                XCTAssertEqual(session.messages.filter {
                    $0.role == .assistant
                }.map(\.text), ["恢复成功"])
            } else {
                let message = try XCTUnwrap(finalError).localizedDescription
                XCTAssertEqual(record.failureMessage, message)
                let restored = try JSONDecoder().decode(
                    AIAgentTurnRecord.self, from: JSONEncoder().encode(record)
                )
                XCTAssertEqual(restored.failureMessage, message)
                XCTAssertEqual(session.uiState.lastError?.localizedDescription, message)
                XCTAssertTrue(message.contains("Host: gateway.example"))
                XCTAssertTrue(message.contains("找不到指定主机"))
                XCTAssertTrue(message.contains("NSURLErrorDomain / -1003"))
                XCTAssertTrue(message.hasSuffix("网络错误，请稍后重试。"))
                XCTAssertEqual(record.failedStage, .streaming)
            }
        }
    }

    func testNetworkDetailsPreferFailingHostAndRedactSensitiveURLs() throws {
        let address = "https://fixture-user:fixture'password@redirect.example/private-path?token=fixture-token&apiKey=fixture-key#fragment"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSLocalizedDescriptionKey: "连接已中断：\(address)；请检查网络。",
            NSURLErrorFailingURLErrorKey: URL(string: address)!,
            "private-metadata": "must-not-display"
        ])
        let failure = try XCTUnwrap(ModelNetworkError(error, baseURL: "https://configured.example/v1"))
        XCTAssertEqual(failure.host, "redirect.example")
        XCTAssertEqual(failure.code, -1005)
        XCTAssertTrue(failure.detail.contains("连接已中断"))
        XCTAssertTrue(failure.detail.contains("请检查网络"))
        for secret in ["fixture-user", "fixture'password", "private-path", "fixture-token",
                       "fixture-key", "fragment", "must-not-display"] {
            XCTAssertFalse(failure.localizedDescription.contains(secret))
        }
        let stringURL = NSError(domain: NSURLErrorDomain, code: -1003, userInfo: [
            NSURLErrorFailingURLStringErrorKey: address,
            NSLocalizedDescriptionKey: "无法解析服务器名称"
        ])
        XCTAssertEqual(ModelNetworkError(stringURL, baseURL: "")?.host, "redirect.example")
        let plain = NSError(domain: NSURLErrorDomain, code: -1003, userInfo: [
            NSLocalizedDescriptionKey: "无法解析服务器名称"
        ])
        let fallback = try XCTUnwrap(ModelNetworkError(
            plain, baseURL: "https://fixture-user:fixture-password@configured.example/private?token=fixture-token"
        ))
        XCTAssertEqual(fallback.host, "configured.example")
        XCTAssertEqual(fallback.detail, plain.localizedDescription)
        let credentialError = NSError(domain: NSURLErrorDomain, code: -1003, userInfo: [
            NSLocalizedDescriptionKey: "无法连接 fixture-api-key；请求头 fixture-header-secret"
        ])
        let redacted = try XCTUnwrap(ModelNetworkError(
            credentialError, baseURL: "",
            secrets: ["fixture-api-key", "fixture-header-secret"]
        ))
        XCTAssertEqual(redacted.detail, "无法连接 [已隐藏]；请求头 [已隐藏]")
        XCTAssertNil(ModelNetworkError(
            AIAgentError.toolExecutionFailed(toolName: "web_fetch", underlying: plain),
            baseURL: "https://configured.example"
        ), "工具网络失败不能变成模型网络失败")
    }

    func testCancellationIsNotNetworkFailureOrRetry() async throws {
        let errors: [Error] = [
            CancellationError(), AIAgentError.cancelled, URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ]
        for error in errors {
            let classified = ErrorClassifier.classify(error)
            XCTAssertFalse(classified.retryable)
            XCTAssertFalse(classified.shouldFallback)
            XCTAssertNotEqual(classified.reason, .transport)
            XCTAssertNil(ModelNetworkError(error, baseURL: "https://configured.example"))
        }
        let provider = NetworkFailureProvider(failures: 4, error: URLError(.cancelled))
        let central = ModelProviderCentral()
        await central.register(name: "p", provider: provider)
        let agent = AIAgent(
            id: "network-cancel-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            toolCentral: ToolCentral(), providerCentral: central,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession()
        let executor = LLMExecutor(session: session, retryPolicy: RetryPolicy(baseDelay: 0))
        var terminals = 0
        for await event in executor.run("取消") {
            switch event {
            case .error(let error):
                terminals += 1
                XCTAssertTrue(ErrorClassifier.isCancellation(error))
            case .completed:
                terminals += 1
                XCTFail("取消不能标为回答完成")
            default:
                break
            }
        }
        XCTAssertEqual(terminals, 1)
        XCTAssertEqual(provider.attempts, 1)
        XCTAssertEqual(session.turnRecord(turnID: 1)?.outcome, .cancelled)
    }

    // MARK: - 看门狗本身

    func testIdleGuardTurnsSilenceIntoStreamStalled() async throws {
        let upstreamCancelled = Locked(wrappedValue: false)
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(1)   // 先有进展，再静默：否则测的是「首字节超时」而不是「中途卡死」
            continuation.onTermination = { @Sendable _ in upstreamCancelled.wrappedValue = true }
        }

        var received: [Int] = []
        var caught: Error?
        do {
            for try await value in StreamIdleGuard.wrap(upstream, idleLimit: 0.3) {
                received.append(value)
            }
            XCTFail("静默的流必须以错误收尾，不能自然结束")
        } catch {
            caught = error
        }

        XCTAssertEqual(received, [1], "判死之前已经到手的元素要照常交付")
        guard case .streamStalled(let idle)? = caught as? ModelError else {
            return XCTFail("期望 ModelError.streamStalled，实际 \(String(describing: caught))")
        }
        XCTAssertGreaterThanOrEqual(idle, 0.3)
        XCTAssertTrue(upstreamCancelled.wrappedValue, "判死后必须把上游取消掉，否则连接白挂着烧 token")
    }

    func testIdleGuardDoesNotKillSteadyStream() async throws {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            Task {
                for value in 1...5 {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    continuation.yield(value)
                }
                continuation.finish()
            }
        }

        var received: [Int] = []
        for try await value in StreamIdleGuard.wrap(upstream, idleLimit: 0.5) {
            received.append(value)
        }
        XCTAssertEqual(received, [1, 2, 3, 4, 5], "每 60ms 有进展就不该被 500ms 的上界误杀")
    }

    func testIdleGuardDisabledWhenLimitIsNotPositive() async throws {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(7)
            continuation.finish()
        }
        var received: [Int] = []
        for try await value in StreamIdleGuard.wrap(upstream, idleLimit: 0) {
            received.append(value)
        }
        XCTAssertEqual(received, [7])
    }

    // MARK: - 执行循环：卡死 → 重试 → 正文不叠

    func testStalledStreamRetriesAndDiscardsPartialText() async throws {
        let provider = StallingProvider(stallAttempts: 1)
        let central = ModelProviderCentral()
        await central.register(name: "p", provider: provider)

        var profile = AIAgentProfile(autoPersist: false, registerBuiltInTools: false)
        profile.streamIdleTimeout = 0.3
        let agent = AIAgent(
            id: "stall-\(UUID().uuidString)",
            profile: profile,
            toolCentral: ToolCentral(),
            providerCentral: central,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "卡死回归")
        provider.readStreamingText = { [weak session] in session?.uiState.streamingText ?? "<released>" }

        let executor = LLMExecutor(
            session: session,
            retryPolicy: RetryPolicy(maxRetries: 1, baseDelay: 0, jitterFactor: 0)
        )
        let terminals = try await withDeadline(seconds: 10, "卡死的流没有被看门狗收掉") {
            var count = 0
            for await event in executor.run("测试") {
                if case .completed = event { count += 1 }
                if case .error = event { count += 1 }
            }
            return count
        }

        XCTAssertEqual(terminals, 1, "每轮恰好一个终止事件")
        XCTAssertEqual(provider.attempts, 2, "卡死应当触发一次重试")
        XCTAssertEqual(
            session.messages.filter { $0.role == .assistant }.map(\.text),
            ["完整回答"],
            "落库的只能是重试成功那次的正文"
        )
        XCTAssertEqual(session.turnRecord(turnID: 1)?.outcome, .answered)
        XCTAssertEqual(
            provider.streamingTextAtAttemptStart,
            ["", ""],
            "重试前必须清掉上一次尝试的正文，否则界面上「半截 + 完整」会接成两遍"
        )
    }

    // MARK: - 限流额度

    func testCancelledWaiterDoesNotHoldAPermit() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let holderEntered = AsyncSemaphore()
        let holderMayFinish = AsyncSemaphore()

        let holder = Task {
            try await limiter.withPermit {
                holderEntered.signal()
                await holderMayFinish.wait()
            }
        }
        await holderEntered.wait()

        // 额度已被占满，这一个只能排队。必须等它**真的排上队**再取消：早一步取消会被
        // `acquire` 开头的 checkCancellation 吃掉，那样测的就不是排队路径了。
        let queued = Task { try await limiter.withPermit { } }
        let enqueued = await poll(until: { await limiter.pendingWaiters == 1 })
        XCTAssertTrue(enqueued, "第二个请求没有进入等待队列，后面的断言就不成立了")

        // 排队期间被取消必须**立刻**退出，而不是等到额度释放。持有者此刻还攥着唯一那个额度，
        // 所以队列清空只可能来自取消本身。
        queued.cancel()
        let drained = await poll(until: { await limiter.pendingWaiters == 0 })
        XCTAssertTrue(drained, "排队中被取消的请求没退出，它还占着队列位置等额度")

        // 队列已经清空才敢 await：`Task.value` 不响应调用方的取消，挂住就只能靠 CI 超时。
        if drained {
            do {
                try await queued.value
                XCTFail("被取消的等待者应当抛 CancellationError")
            } catch is CancellationError {
                // 预期
            }
        }

        holderMayFinish.signal()
        try await holder.value

        // 额度必须完整归还：取消的那个没占过，持有者放掉了自己那份。
        try await withDeadline(seconds: 5, "额度泄漏了，后续请求拿不到名额") {
            try await limiter.withPermit { }
        }
    }
}

// MARK: - Helpers

private final class NetworkFailureProvider: ModelProvider, @unchecked Sendable {
    let name = "network"
    let baseURL = "https://gateway.example/v1"
    let apiKey = ""
    let apiProtocol: APIProtocol = .openaiCompletions
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    let failures: Int
    let error: Error
    @Locked private(set) var attempts = 0

    init(failures: Int, error: Error = NSError(
        domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
        userInfo: [NSLocalizedDescriptionKey: "找不到指定主机"]
    )) {
        self.failures = failures
        self.error = error
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let attempt = $attempts.mutate {
            $0 += 1
            return $0
        }
        return AsyncThrowingStream { continuation in
            if attempt <= failures {
                continuation.yield(.textDelta("未完成正文"))
                continuation.finish(throwing: error)
            } else {
                continuation.yield(.textDelta("恢复成功"))
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
        }
    }
}

/// 有界轮询：条件成立返回 true，超时返回 false。
///
/// 等 actor 状态变化时用它而不是 `withDeadline`：那条路要 await 一个子任务，
/// 而 `Task.value` 不响应调用方的取消 —— 反向验证时会从「失败」退化成「挂住」。
private func poll(
    timeout: TimeInterval = 5,
    until condition: @Sendable () async -> Bool
) async -> Bool {
    let step: TimeInterval = 0.01
    for _ in 0..<Int(timeout / step) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
    }
    return await condition()
}

/// 把「挂住不返回」变成一次明确失败。
///
/// 看门狗这类用例的反向验证（故意关掉闸门）表现为永不返回；没有这层包装，
/// 回归就从「失败」退化成「测试卡住」，CI 上只能看到超时。
private func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ message: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        while let result = try await group.next() {
            guard let value = result else {
                XCTFail(message)
                throw CancellationError()
            }
            return value
        }
        throw CancellationError()
    }
}

/// 只够测试用的一次性信号：把「持有者已进入临界区」这类时序写死，不靠 sleep 猜。
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = ReadersWriterLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending: [CheckedContinuation<Void, Never>] = lock.writeSync {
            signalled = true
            let list = waiters
            waiters = []
            return list
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.writeSync {
                if signalled { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// 前 `stallAttempts` 次尝试：吐半截正文，然后**永远静默**（既不结束也不报错）——
/// 这正是 App 被挂起后 `URLSession.bytes` 的行为。
private final class StallingProvider: ModelProvider, @unchecked Sendable {
    let name = "stalling"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    let stallAttempts: Int

    @Locked private(set) var attempts = 0
    /// 每次尝试**开始时**界面上的流式正文。重试前没清掉，第二项就会是上一次的半截。
    @Locked private(set) var streamingTextAtAttemptStart: [String] = []
    /// 由测试注入，读的是 session 的 uiState；provider 本身不认识 session。
    var readStreamingText: (@Sendable () -> String)?

    init(stallAttempts: Int) {
        self.stallAttempts = stallAttempts
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let attempt = $attempts.mutate { count -> Int in
            count += 1
            return count
        }
        let observed = readStreamingText?() ?? ""
        $streamingTextAtAttemptStart.mutate { $0.append(observed) }

        return AsyncThrowingStream { continuation in
            if attempt <= stallAttempts {
                continuation.yield(.textDelta("半截回答"))
                // 不 finish：模拟连接已断但 URLSession 不通知的状态。
                // 下游判死后会取消，届时这条流被 onTermination 收掉。
            } else {
                continuation.yield(.textDelta("完整回答"))
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
        }
    }
}
