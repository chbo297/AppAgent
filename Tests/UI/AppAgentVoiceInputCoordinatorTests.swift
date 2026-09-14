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
        private(set) var startCount = 0
        private(set) var stopReasons: [AppAgentVoiceRecognitionEndReason] = []
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

        func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestBackfill text: String) {
            events.append("backfill:\(text)")
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
        resolver: @escaping (CGPoint) -> AppAgentVoiceInputReleaseAction = { _ in .send }
    ) -> Harness {
        let provider = FakeRecognitionProvider()
        let feedback = FeedbackRecorder()
        let delegate = DelegateRecorder()
        let coordinator = AppAgentVoiceInputCoordinator(
            recognitionManager: provider,
            feedback: feedback
        )
        coordinator.delegate = delegate
        coordinator.releaseActionResolver = resolver
        return Harness(coordinator: coordinator, provider: provider, feedback: feedback, delegate: delegate)
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

    func testEndInSendZoneStopsRecordingFinishesThenBackfills() {
        let harness = makeHarness()
        harness.coordinator.begin(source: .keyboardModeLongPress, location: .zero)
        harness.coordinator.updateTranscript("你好")
        harness.coordinator.end(at: .zero)

        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertEqual(harness.provider.stopReasons.count, 1)
        if case .userStopped = harness.provider.stopReasons[0] {} else {
            XCTFail("send 收尾应以 userStopped 停止识别")
        }
        // 顺序约定：先 finish（隐藏面板）再回填。
        XCTAssertEqual(harness.delegate.events.suffix(2), ["finish", "backfill:你好"])
        XCTAssertEqual(harness.feedback.impactReasons.last, "stop-send")
    }

    func testEndInCancelZoneStopsWithCancelledAndNoBackfill() {
        let harness = makeHarness(resolver: { _ in .cancel })
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.updateTranscript("语音内容")
        harness.coordinator.end(at: .zero)

        XCTAssertFalse(harness.coordinator.isActive)
        if case .cancelled = harness.provider.stopReasons[0] {} else {
            XCTFail("cancel 收尾应以 cancelled 停止识别")
        }
        XCTAssertEqual(harness.delegate.events.last, "finish")
        XCTAssertFalse(harness.delegate.events.contains { $0.hasPrefix("backfill") })
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

    func testEndInEditZoneHandsOffWithoutFinishing() {
        let harness = makeHarness(resolver: { _ in .edit })
        harness.coordinator.begin(source: .voiceModePress, location: .zero)
        harness.coordinator.updateTranscript("编辑我")
        harness.coordinator.end(at: .zero)

        // 手势状态结束，但面板不隐藏（无 finish），进入编辑交接。
        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertEqual(harness.delegate.events.last, "edit:编辑我")
        XCTAssertFalse(harness.delegate.events.contains("finish"))
        if case .userStopped = harness.provider.stopReasons[0] {} else {
            XCTFail("edit 收尾应以 userStopped 停止识别")
        }
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
}
#endif
