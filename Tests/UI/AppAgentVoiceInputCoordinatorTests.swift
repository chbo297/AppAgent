#if canImport(UIKit)
import XCTest
@testable import AppAgent

/// 语音输入协调器的纯逻辑测试：状态机转移、震动 diff、编辑交接。
/// 识别服务与触觉反馈均用替身，不触碰音频系统与视图。
@MainActor
final class AppAgentVoiceInputCoordinatorTests: XCTestCase {

    // MARK: - 替身

    private final class FakeRecognitionProvider: AppAgentVoiceRecognitionProviding {
        var preferredLocales: [Locale] = []
        var canPrewarmNow = true
        var isRecording = false
        private(set) var startCount = 0
        private(set) var stopReasons: [AppAgentVoiceRecognitionEndReason] = []
        private(set) var finishRequests: [(trailingCapture: TimeInterval, finalizationTimeout: TimeInterval)] = []
        private var continuation: AsyncStream<AppAgentVoiceRecognitionEvent>.Continuation?

        func startRecording(locale: Locale?) -> AsyncStream<AppAgentVoiceRecognitionEvent> {
            startCount += 1
            return AsyncStream { continuation in
                self.continuation = continuation
            }
        }

        func requestStopRecording(reason: AppAgentVoiceRecognitionEndReason) {
            stopReasons.append(reason)
        }

        func requestFinishRecording(trailingCapture: TimeInterval, finalizationTimeout: TimeInterval) {
            finishRequests.append((trailingCapture, finalizationTimeout))
        }

        // 测试驱动：手动向事件流投递识别结束事件（携带最终文本）。
        func emitEnded(finalText: String, reason: AppAgentVoiceRecognitionEndReason = .userStopped) {
            continuation?.yield(.ended(AppAgentVoiceRecognitionEndContext(
                reason: reason,
                finalText: finalText,
                timestamp: 0
            )))
        }
    }

    private final class FeedbackRecorder: AppAgentVoiceInputFeedbackProviding {
        private(set) var impactReasons: [String] = []
        private(set) var prepareCount = 0

        func prepare() {
            prepareCount += 1
        }

        func impact(reason: String) {
            impactReasons.append(reason)
        }
    }

    private final class DelegateRecorder: AppAgentVoiceInputCoordinatorDelegate {
        private(set) var events: [String] = []
        private(set) var renderStates: [AppAgentVoiceInputRenderState] = []

        func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didBeginAt location: CGPoint) {
            events.append("begin")
        }

        func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didUpdate renderState: AppAgentVoiceInputRenderState) {
            events.append("update")
            renderStates.append(renderState)
        }

        func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didEnterEditModeWith text: String) {
            events.append("edit:\(text)")
        }

        func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestSend text: String) {
            events.append("send:\(text)")
        }

        func voiceInputDidFinish(_ coordinator: AppAgentVoiceInputCoordinator) {
            events.append("finish")
        }
    }

    private struct Harness {
        let coordinator: AppAgentVoiceInputCoordinator
        let provider: FakeRecognitionProvider
        let feedback: FeedbackRecorder
        let delegate: DelegateRecorder
    }

    private func makeHarness(
        timings: AppAgentVoiceInputTimings = .phase1,
        resolver: @escaping (CGPoint) -> AppAgentVoiceInputReleaseAction = { _ in .send }
    ) -> Harness {
        let provider = FakeRecognitionProvider()
        let feedback = FeedbackRecorder()
        let delegate = DelegateRecorder()
        let coordinator = AppAgentVoiceInputCoordinator(
            recognitionManager: provider,
            feedback: feedback,
            timings: timings
        )
        coordinator.delegate = delegate
        coordinator.releaseActionResolver = resolver
        return Harness(coordinator: coordinator, provider: provider, feedback: feedback, delegate: delegate)
    }

    /// 让识别事件流的消费 Task 有机会跑完（AsyncStream 在 MainActor 上异步投递）。
    private func pump() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    // MARK: - 手势阶段

    func testBeginStartsRecognitionShowsPanelAndVibrates() {
        let harness = makeHarness()
        harness.coordinator.begin(source: .voiceModePress, location: CGPoint(x: 10, y: 10))

        XCTAssertTrue(harness.coordinator.isActive)
        XCTAssertEqual(harness.provider.startCount, 1)
        XCTAssertEqual(harness.delegate.events.prefix(2), ["begin", "update"])
        XCTAssertEqual(harness.feedback.impactReasons, ["start-voice-mode-press"])
        XCTAssertEqual(harness.feedback.prepareCount, 1)
    }

    func testMoveVibratesOnlyWhenReleaseActionChanges() {
        // 中线左侧取消、右侧发送的简化判定。
        let harness = makeHarness(resolver: { $0.x < 100 ? .cancel : .send })
        harness.coordinator.begin(source: .voiceModePress, location: CGPoint(x: 200, y: 0))

        harness.coordinator.move(to: CGPoint(x: 210, y: 0)) // send → send，不震动
        harness.coordinator.move(to: CGPoint(x: 50, y: 0))  // send → cancel，震动一次
        harness.coordinator.move(to: CGPoint(x: 40, y: 0))  // cancel → cancel，不震动

        XCTAssertEqual(
            harness.feedback.impactReasons,
            ["start-voice-mode-press", "select-cancel"]
        )
        XCTAssertEqual(harness.delegate.renderStates.last?.releaseAction, .cancel)
    }

    func testEndInSendZoneFinalizesThenSendsFinalText() async {
        let harness = makeHarness()
        harness.coordinator.begin(source: .keyboardModeLongPress, location: .zero)
        harness.coordinator.updateTranscript("你好")   // 松手时的 partial
        harness.coordinator.end(at: .zero)

        // 松手后进入收尾：请求 finish、震动 stop-send，但尚未 finish/发送。
        XCTAssertEqual(harness.provider.finishRequests.count, 1)
        XCTAssertTrue(harness.provider.stopReasons.isEmpty, "send 走优雅收尾，不应直接 stop")
        XCTAssertFalse(harness.delegate.events.contains("finish"))
        XCTAssertFalse(harness.delegate.events.contains { $0.hasPrefix("send") })
        XCTAssertEqual(harness.feedback.impactReasons.last, "stop-send")

        // 识别器给出更完整的最终文本后：先把最终文本刷到气泡并把消息交给宿主，
        // 等渲染一帧之后才关闭面板（最终结果不能一闪而过）。
        harness.provider.emitEnded(finalText: "你好世界")
        await pump()

        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertEqual(harness.delegate.events.suffix(3), ["update", "send:你好世界", "finish"])
        XCTAssertEqual(
            harness.delegate.renderStates.last?.transcriptText,
            "你好世界",
            "关面板前气泡应先更新成最终文本"
        )
    }

    func testEndInSendZoneWithEmptyFinalSendsNothing() async {
        let harness = makeHarness()
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.end(at: .zero)

        harness.provider.emitEnded(finalText: "")
        await pump()

        XCTAssertEqual(harness.delegate.events.last, "finish")
        XCTAssertFalse(harness.delegate.events.contains { $0.hasPrefix("send") })
    }

    func testEndInCancelZoneStopsWithCancelledAndSendsNothing() {
        let harness = makeHarness(resolver: { _ in .cancel })
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.updateTranscript("语音内容")
        harness.coordinator.end(at: .zero)

        // cancel 不等尾音：立即停止并结束。
        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertTrue(harness.provider.finishRequests.isEmpty, "cancel 不进入优雅收尾")
        if case .cancelled = harness.provider.stopReasons[0] {} else {
            XCTFail("cancel 收尾应以 cancelled 停止识别")
        }
        XCTAssertEqual(harness.delegate.events.last, "finish")
        XCTAssertFalse(harness.delegate.events.contains { $0.hasPrefix("send") })
    }

    func testFinishRequestUsesConfiguredTimings() {
        let harness = makeHarness(timings: AppAgentVoiceInputTimings(trailingCapture: 0.3, finalizationTimeout: 1.2, prewarmWatchdog: 1.5))
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.end(at: .zero)

        XCTAssertEqual(harness.provider.finishRequests.first?.trailingCapture, 0.3)
        XCTAssertEqual(harness.provider.finishRequests.first?.finalizationTimeout, 1.2)
    }

    func testMoveIgnoredWhileFinalizing() {
        let harness = makeHarness(resolver: { $0.x < 100 ? .cancel : .send })
        harness.coordinator.begin(source: .voiceModePress, location: CGPoint(x: 200, y: 0))
        harness.coordinator.end(at: CGPoint(x: 200, y: 0)) // send → 进入收尾

        let requestsAfterEnd = harness.provider.finishRequests.count
        harness.coordinator.move(to: CGPoint(x: 10, y: 0))  // 收尾中移动应被忽略
        harness.coordinator.end(at: CGPoint(x: 10, y: 0))   // 收尾中再次 end 应被忽略

        XCTAssertEqual(harness.provider.finishRequests.count, requestsAfterEnd)
        XCTAssertTrue(harness.provider.stopReasons.isEmpty)
    }

    func testSystemCancelFinishesAsCancel() {
        let harness = makeHarness()
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.systemCancel(at: .zero)

        XCTAssertFalse(harness.coordinator.isActive)
        if case .cancelled = harness.provider.stopReasons[0] {} else {
            XCTFail("系统取消应以 cancelled 停止识别")
        }
        XCTAssertEqual(harness.feedback.impactReasons.last, "stop-cancel")
    }

    // MARK: - 编辑交接

    func testEndInEditZoneFinalizesThenHandsOffWithFinalText() async {
        let harness = makeHarness(resolver: { _ in .edit })
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.updateTranscript("编辑我")
        harness.coordinator.end(at: .zero)

        // 松手后进入收尾：请求 finish，但尚未进编辑态。
        XCTAssertEqual(harness.provider.finishRequests.count, 1)
        XCTAssertFalse(harness.delegate.events.contains { $0.hasPrefix("edit") })
        XCTAssertEqual(harness.feedback.impactReasons.last, "stop-edit")

        // 拿到最终文本后进编辑态（面板保留，无 finish），用最终文本而非松手时的 partial。
        harness.provider.emitEnded(finalText: "编辑我最终")
        await pump()

        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertEqual(harness.delegate.events.last, "edit:编辑我最终")
        XCTAssertFalse(harness.delegate.events.contains("finish"))
    }

    func testEditSendTrimsAndFinishesBeforeSending() {
        let harness = makeHarness()
        harness.coordinator.editSend(text: "  多喝水  ")

        XCTAssertEqual(harness.delegate.events, ["finish", "send:多喝水"])
        XCTAssertEqual(harness.feedback.impactReasons, ["edit-send"])
    }

    func testEditSendWithWhitespaceOnlyDoesNotSend() {
        let harness = makeHarness()
        harness.coordinator.editSend(text: "   ")

        XCTAssertEqual(harness.delegate.events, ["finish"])
    }

    func testEditCancelOnlyFinishes() {
        let harness = makeHarness()
        harness.coordinator.editCancel()

        XCTAssertEqual(harness.delegate.events, ["finish"])
        XCTAssertEqual(harness.feedback.impactReasons, ["edit-cancel"])
    }

    // MARK: - 识别事件

    func testUpdateTranscriptIgnoredWhenInactive() {
        let harness = makeHarness()
        harness.coordinator.updateTranscript("不应生效")

        XCTAssertTrue(harness.delegate.events.isEmpty)
    }

    // MARK: - 预热

    func testPrewarmStartsRecognitionWithoutShowingPanel() {
        let harness = makeHarness()
        harness.coordinator.prewarm(source: .keyboardModeLongPress)

        XCTAssertEqual(harness.provider.startCount, 1)
        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertTrue(harness.delegate.events.isEmpty, "预热不应发出任何 delegate 事件")
    }

    func testPrewarmSkippedWhenNotAllowed() {
        let harness = makeHarness()
        harness.provider.canPrewarmNow = false
        harness.coordinator.prewarm(source: .keyboardModeLongPress)

        XCTAssertEqual(harness.provider.startCount, 0)
        XCTAssertFalse(harness.coordinator.isActive)
    }

    func testBeginAfterPrewarmReusesRecognition() {
        let harness = makeHarness()
        harness.coordinator.prewarm(source: .keyboardModeLongPress)
        harness.coordinator.begin(source: .keyboardModeLongPress, location: .zero)

        // 复用预热已起的识别，不重启。
        XCTAssertEqual(harness.provider.startCount, 1)
        XCTAssertTrue(harness.coordinator.isActive)
        XCTAssertEqual(harness.delegate.events.prefix(2), ["begin", "update"])
    }

    func testBeginSeedsRecordingStateWhenAlreadyRecording() {
        // 预热已让识别就绪（.recording 事件在预热期被丢），展示面板时应直接进入录音中样式而非 loading。
        let harness = makeHarness()
        harness.provider.isRecording = true
        harness.coordinator.begin(source: .keyboardModeLongPress, location: .zero)

        XCTAssertEqual(harness.delegate.renderStates.last?.recognitionState, .recording)
    }

    func testAbortPrewarmStopsWithoutDelegateEvents() {
        let harness = makeHarness()
        harness.coordinator.prewarm(source: .keyboardModeLongPress)
        harness.coordinator.abortPrewarm()

        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertTrue(harness.delegate.events.isEmpty, "取消预热不应发出任何 delegate 事件")
        if case .cancelled = harness.provider.stopReasons.first {} else {
            XCTFail("取消预热应以 cancelled 停止识别")
        }
    }
}
#endif
