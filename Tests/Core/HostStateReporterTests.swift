import XCTest
@testable import AppAgent

final class HostStateReporterTests: XCTestCase {
    /// 第一帧发完整状态；之后没变就不发，变了只发变的字段和删掉的字段。
    func testFirstFrameIsFullStateThenOnlyChangedFields() async throws {
        let store = HostStateStore()
        store.setFields(["page": "home", "map.viewport": "a"])
        store.setDescription("当前最上层页面", forKey: "page")
        let reporter = HostStateReporter()
        try await reporter.installProvider(store)
        let runID = UUID()
        await reporter.startRun(runID)

        let first = try await requireFrame(reporter, runID)
        XCTAssertEqual(first.mode, .state)
        XCTAssertEqual(first.payloads, [.state(HostState(
            fields: ["page": "home", "map.viewport": "a"],
            descriptions: ["page": "当前最上层页面"]
        ))])
        try await reporter.commit(first)

        let unchanged = try await reporter.prepare(runID: runID)
        XCTAssertNil(unchanged, "状态没变就不该再发")

        store.setField("b", forKey: "map.viewport")
        store.setField(nil, forKey: "page")
        let second = try await requireFrame(reporter, runID)
        XCTAssertEqual(second.payloads, [.change(HostStateChange(changed: ["map.viewport": "b"], removed: ["page"]))])
    }

    /// 只有模型请求成功才算看到：丢弃的帧下次重发；上下文压缩后、新一轮都重发全量。
    func testFullStateIsResentUntilCommittedAndAfterReset() async throws {
        let store = HostStateStore()
        store.setFields(["page": "home"])
        let reporter = HostStateReporter()
        try await reporter.installProvider(store)
        let runID = UUID()
        await reporter.startRun(runID)

        let dropped = try await requireFrame(reporter, runID)
        await reporter.discard(dropped)
        let retried = try await requireFrame(reporter, runID)
        XCTAssertEqual(retried.mode, .state)

        // 请求途中上下文被压缩：这帧照样提交，下一帧仍是全量。
        await reporter.invalidateModelBaseline()
        try await reporter.commit(retried)
        let afterCompaction = try await requireFrame(reporter, runID)
        XCTAssertEqual(afterCompaction.mode, .state)

        let nextRun = UUID()
        await reporter.startRun(nextRun)
        do {
            try await reporter.commit(afterCompaction)
            XCTFail("上一轮准备的帧不能在新一轮提交")
        } catch {
        }
        let fresh = try await reporter.prepare(runID: nextRun)
        XCTAssertEqual(fresh?.mode, .state)
    }

    /// 事件随下一帧发出、只发一次；状态没变时这一帧只有事件。
    func testStoreEventReachesNextFrameOnce() async throws {
        let store = HostStateStore()
        store.setFields(["page": "home"])
        let reporter = HostStateReporter()
        try await reporter.installProvider(store)
        let runID = UUID()
        await reporter.startRun(runID)
        try await reporter.commit(try await requireFrame(reporter, runID))

        store.postEvent(trigger: "tap", action: "open-detail", detail: "poi=1")
        for _ in 0..<100 {
            if await !reporter.pendingEvents().isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let frame = try await requireFrame(reporter, runID)
        XCTAssertEqual(frame.mode, .event)
        guard case .event(let event) = frame.payloads.first else {
            return XCTFail("应只带事件")
        }
        XCTAssertEqual(event.action, "open-detail")
        XCTAssertTrue(frame.payloads[0].modelText.contains("\"detail\":\"poi=1\""))
        try await reporter.commit(frame)
        let after = try await reporter.prepare(runID: runID)
        XCTAssertNil(after)
    }

    /// 宿主读取卡住（还不响应取消）：请求不能跟着挂，超时后沿用上一份状态。
    func testUnresponsiveProviderDoesNotHangRequest() async throws {
        let reporter = HostStateReporter()
        await reporter.setStateReadTimeout(0.2)
        let provider = StallingProvider()
        try await reporter.installProvider(provider)
        await provider.setStalls(true)
        let runID = UUID()
        await reporter.startRun(runID)

        let started = Date()
        let frame = try await reporter.prepare(runID: runID)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "超时后必须继续，不能等宿主慢慢返回")
        XCTAssertEqual(frame?.payloads, [.state(HostState(fields: ["page": "installed"]))], "超时沿用上一份状态")
    }

    /// 超长字段截断并注明，不让大段内容每帧都发给模型。
    func testOversizedFieldIsTruncated() async throws {
        let store = HostStateStore()
        store.setFields(["content": String(repeating: "x", count: 30)])
        let reporter = HostStateReporter()
        await reporter.setFieldCharacterLimit(10)
        try await reporter.installProvider(store)
        let content = await reporter.currentFields()?["content"]
        XCTAssertEqual(content, String(repeating: "x", count: 10) + "…（已截断，原文 30 字）")
    }

    /// 换了来源之后，旧来源迟到的读取结果作废，不能覆盖新状态。
    func testLateReadFromReplacedProviderIsDropped() async throws {
        let reporter = HostStateReporter()
        let slow = StallingProvider()
        await slow.setDelay(0.3)
        let replacement = HostStateStore()
        replacement.setFields(["page": "replacement"])

        async let oldInstall = reporter.installProvider(slow)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await reporter.installProvider(replacement)
        let oldResult = try await oldInstall

        XCTAssertFalse(oldResult)
        let page = await reporter.currentFields()?["page"]
        XCTAssertEqual(page, "replacement")
    }

    /// store 不持有reporter：会话没了，reporter跟着释放，之后再发事件也不出事。
    func testReporterIsNotRetainedByStore() async throws {
        let store = HostStateStore()
        var reporter: HostStateReporter? = HostStateReporter()
        weak var weakReporter = reporter
        _ = try await reporter?.installProvider(store)
        reporter = nil
        for _ in 0..<50 where weakReporter != nil {
            await Task.yield()
        }
        XCTAssertNil(weakReporter)
        store.postEvent(trigger: "tap", action: "after-release", detail: nil)
    }

    /// app_state 工具现读会话装上的那个来源；没装来源时报错而不是返回空。
    func testAppStateToolReadsInstalledProvider() async throws {
        let session = AISession(id: "app-state-tool")
        let tool = AppStateTool()
        let missing = try await tool.execute(arguments: [:], session: session)
        guard case .error = missing else {
            return XCTFail("没装来源应报错")
        }

        let store = HostStateStore()
        store.setFields(["page": "home"])
        try await session.installHostStateProvider(store)
        store.setField("detail", forKey: "page")
        let output = try await tool.execute(arguments: [:], session: session)
        guard case .json(let value) = output else {
            return XCTFail("应返回 JSON")
        }
        XCTAssertEqual(value, .object(["page": .string("detail")]))
    }

    /// 端到端：第一次请求带完整状态；工具改了一个字段后，下一次请求只带这个字段的变化。
    func testRequestsCarryFullStateThenOnlyChangedField() async throws {
        let store = HostStateStore()
        store.setFields(["page": "home", "map.viewport": "a"])
        let tools = ToolCentral()
        await tools.register(MovingMapTool(store: store))
        let providers = ModelProviderCentral()
        let provider = HostContextRecordingProvider()
        await providers.register(name: "p", provider: provider)
        let agent = AIAgent(
            id: "host-state-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            toolCentral: tools, providerCentral: providers,
            modelPolicy: ModelPolicy(primary: "p/m"),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Host state")
        try await session.installHostStateProvider(store)

        for await _ in session.sendMessage("go") {
        }

        let frames = provider.recordedFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames[0].contains("\"kind\":\"host_state\""))
        XCTAssertTrue(frames[0].contains("\"page\":\"home\""))
        XCTAssertTrue(frames[1].contains("\"kind\":\"host_state_change\""))
        XCTAssertTrue(frames[1].contains("\"map.viewport\":\"b\""))
        XCTAssertFalse(frames[1].contains("\"page\""), "没变的字段不该重发")
    }

    private func requireFrame(_ reporter: HostStateReporter, _ runID: UUID) async throws -> PreparedHostContext {
        let frame = try await reporter.prepare(runID: runID)
        return try XCTUnwrap(frame)
    }

    func testStableTextSortsKeys() {
        XCTAssertEqual(HostStateStore.stableText(from: ["b": 1, "a": ["x", "y"]]), "{\"a\":[\"x\",\"y\"],\"b\":1}")
        XCTAssertEqual(HostStateStore.stableText(from: "plain"), "plain")
    }
}

/// 模拟「用户挪了地图」：工具执行时改一个字段。
private struct MovingMapTool: ToolProtocol {
    let store: HostStateStore
    let name = "move_map"
    let description = "Move the map."
    let parameters = Tool.Schema(properties: [:], required: [])
    let safetyLevel: Tool.SafetyLevel = .safe

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        store.setField("b", forKey: "map.viewport")
        return .text("moved")
    }
}

/// 第一次请求调工具，第二次结束；记下每次请求带的宿主上下文文本。
private final class HostContextRecordingProvider: ModelProvider, @unchecked Sendable {
    let name = "host-context-recorder"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "m")]
    let requestTimeout: TimeInterval = 5
    private let lock = NSLock()
    private var frames: [String] = []

    func recordedFrames() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return frames
    }

    func streamCompletion(
        messages: [AIAgentMessage], system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>], modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let frame = messages.last { message in
            message.isHostContext
        }?.hostContextPayloads.map(\.modelText).joined(separator: "\n") ?? ""
        lock.lock()
        frames.append(frame)
        let isFirst = frames.count == 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if isFirst {
                continuation.yield(.toolCall(.init(id: "call-1", name: "move_map", arguments: [:])))
                continuation.yield(.done(stopReason: .toolUse))
            } else {
                continuation.yield(.textDelta("done"))
                continuation.yield(.done(stopReason: .endTurn))
            }
            continuation.finish()
        }
    }
}

/// 可控的宿主：可以让读取卡住且不响应取消，或延迟返回。
private actor StallingProvider: HostStateProvider {
    private var stalls = false
    private var delay: TimeInterval = 0

    func setStalls(_ value: Bool) {
        stalls = value
    }

    func setDelay(_ seconds: TimeInterval) {
        delay = seconds
    }

    func currentState() async throws -> [String: String] {
        if stalls {
            // 模拟卡在等主线程回调：忽略取消，2 秒后才回来。
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return ["page": "late"]
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return ["page": "slow"]
        }
        return ["page": "installed"]
    }
}
