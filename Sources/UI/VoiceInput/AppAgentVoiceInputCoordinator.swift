//
//  AppAgentVoiceInputCoordinator.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 语音输入的渲染状态：手势阶段 overlay 所需的全部展示信息。
struct AppAgentVoiceInputRenderState {
    /// 手指状态：当前手指在宿主坐标系中的位置。
    var fingerLocation: CGPoint

    /// 识别状态：语音识别在 UI 上呈现为未开始、加载中或录音中。
    var recognitionState: AppAgentVoiceRecognitionVisualState = .loading

    /// 抬起行为：当前手指位置对应的松手后动作。
    var releaseAction: AppAgentVoiceInputReleaseAction = .send

    /// 识别文本：语音识别管理器实时返回的文本内容。
    var transcriptText = ""

    var showsTranscriptCursor: Bool {
        !transcriptText.isEmpty
    }
}

/// 语音输入触觉反馈的抽象：协调器只表达“何时震动”，不关心震动如何实现。
protocol AppAgentVoiceInputFeedbackProviding {
    func prepare()
    func impact(reason: String)
}

/// 默认触觉反馈实现：UIImpactFeedbackGenerator，保留日志便于对照调试。
struct AppAgentVoiceInputHapticFeedback: AppAgentVoiceInputFeedbackProviding {
    let generator: UIImpactFeedbackGenerator

    func prepare() {
        generator.prepare()
    }

    func impact(reason: String) {
        print("[AppAgentVoiceInput] haptic impact reason=\(reason)")
        generator.prepare()
        generator.impactOccurred(intensity: 1)
    }
}

/// 协调器 → 宿主的输出：宿主负责把这些语义映射到 overlay / inputBar / session。
protocol AppAgentVoiceInputCoordinatorDelegate: AnyObject {
    /// 手势开始：宿主应展示语音输入面板。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didBeginAt location: CGPoint)

    /// 渲染状态变化：宿主应把 renderState 同步给 overlay。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didUpdate renderState: AppAgentVoiceInputRenderState)

    /// 松手发送（含识别仍在进行中）：宿主应把识别文本回填到输入框。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestBackfill text: String)

    /// 松手编辑：宿主应让 overlay 进入编辑态（面板保持展示）。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didEnterEditModeWith text: String)

    /// 编辑态点击发送：宿主应把文本作为消息发出。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestSend text: String)

    /// 本次语音输入结束：宿主应隐藏语音输入面板。
    func voiceInputDidFinish(_ coordinator: AppAgentVoiceInputCoordinator)
}

/// 语音输入协调器：一次语音输入（按下 → 移动 → 松手 → 可选编辑收尾）的唯一状态主人。
///
/// 边界约定：
/// - 输入：宿主转发的手势值事件、overlay 编辑态回调；
/// - 依赖：识别管理器（事件流）、releaseActionResolver（几何判定留在视图层）、触觉反馈抽象；
/// - 输出：delegate 语义回调，不直接触碰任何视图。
///
/// 主线程使用；识别事件流由管理器保证主线程投递。
final class AppAgentVoiceInputCoordinator {

    weak var delegate: AppAgentVoiceInputCoordinatorDelegate?

    /// 几何判定注入：手指位置 → 松手行为。由 overlay 提供（视图是自身几何的唯一权威）。
    var releaseActionResolver: ((CGPoint) -> AppAgentVoiceInputReleaseAction)?

    /// 手势阶段的渲染状态；nil 表示当前没有进行中的语音手势（含已交接给编辑态）。
    private(set) var renderState: AppAgentVoiceInputRenderState?

    var isActive: Bool {
        renderState != nil
    }

    private let recognitionManager: AppAgentVoiceRecognitionProviding
    private let feedback: AppAgentVoiceInputFeedbackProviding
    private var recognitionTask: Task<Void, Never>?

    init(
        recognitionManager: AppAgentVoiceRecognitionProviding = AppAgentVoiceRecognitionManager.shared,
        feedback: AppAgentVoiceInputFeedbackProviding
    ) {
        self.recognitionManager = recognitionManager
        self.feedback = feedback
    }

    deinit {
        recognitionTask?.cancel()
    }

    // MARK: - 手势输入

    /// 手势开始：建立本次语音输入状态、启动识别，并请求宿主展示面板。
    func begin(source: AppAgentInputBarVoiceInputSource, location: CGPoint) {
        renderState = AppAgentVoiceInputRenderState(fingerLocation: location)
        startRecognition()
        delegate?.voiceInput(self, didBeginAt: location)
        render()
        feedback.impact(reason: beginHapticReason(for: source))
        // 预热选区切换反馈，让后续滑入取消/编辑/发送区域的震动更及时。
        feedback.prepare()
    }

    /// 手势移动：按当前位置重新判定“此刻抬起会执行什么行为”。
    func move(to location: CGPoint) {
        refreshReleaseAction(location: location)
    }

    /// 手势抬起：用最终位置刷新行为后，按 send/cancel/edit 收尾。
    func end(at location: CGPoint) {
        guard isActive else { return }
        refreshReleaseAction(location: location)

        switch renderState?.releaseAction ?? .cancel {
        case .send:
            finishSend()
        case .cancel:
            finishCancel()
        case .edit:
            finishEdit()
        }
    }

    /// 系统取消/手势失败：刷新位置保持 UI 一致后统一按取消收尾。
    func systemCancel(at location: CGPoint) {
        guard isActive else { return }
        refreshReleaseAction(location: location)
        finishCancel()
    }

    /// 宿主 API：外部更新实时识别文本（不改变手指当前选择的抬起行为）。
    func updateTranscript(_ text: String) {
        guard var state = renderState else { return }
        state.transcriptText = text
        renderState = state
        render()
    }

    // MARK: - 编辑态收尾（overlay 回调经宿主转入）

    func editCancel() {
        feedback.impact(reason: "edit-cancel")
        delegate?.voiceInputDidFinish(self)
    }

    func editSend(text: String) {
        feedback.impact(reason: "edit-send")
        delegate?.voiceInputDidFinish(self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        delegate?.voiceInput(self, didRequestSend: trimmed)
    }

    // MARK: - 识别事件

    private func startRecognition() {
        recognitionTask?.cancel()
        let events = recognitionManager.startRecording()
        recognitionTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.handleRecognitionEvent(event)
            }
        }
    }

    /// 识别事件只影响 loading/recording 展示与文本，不能覆盖手指当前选择的 send/cancel/edit。
    private func handleRecognitionEvent(_ event: AppAgentVoiceRecognitionEvent) {
        switch event {
        case .loading:
            guard var state = renderState else { return }
            state.recognitionState = .loading
            renderState = state
            render()
        case .recording(let context):
            guard var state = renderState else { return }
            state.recognitionState = .recording
            state.transcriptText = context.combinedText
            renderState = state
            render()
        case .ended:
            recognitionTask = nil
            // 手势仍进行中时识别意外结束（权限拒绝/中断等），按结束收尾；
            // 已交接给编辑态（renderState == nil）时不再干预面板。
            guard isActive else { return }
            finish()
        }
    }

    private func stopRecognition(reason: AppAgentVoiceRecognitionEndReason) {
        recognitionManager.requestStopRecording(reason: reason)
    }

    // MARK: - 收尾

    private func finishSend() {
        let transcript = renderState?.transcriptText ?? ""
        feedback.impact(reason: "stop-send")
        stopRecognition(reason: .userStopped)
        finish()
        delegate?.voiceInput(self, didRequestBackfill: transcript)
    }

    private func finishCancel() {
        feedback.impact(reason: "stop-cancel")
        stopRecognition(reason: .cancelled)
        finish()
    }

    private func finishEdit() {
        let transcript = renderState?.transcriptText ?? ""
        feedback.impact(reason: "stop-edit")
        stopRecognition(reason: .userStopped)
        // 手势语音阶段结束；renderState 置空后识别 ended 事件不会再触发 didFinish，
        // 编辑态由 overlay 驱动、经 editCancel/editSend 收尾。
        renderState = nil
        delegate?.voiceInput(self, didEnterEditModeWith: transcript)
    }

    private func finish() {
        renderState = nil
        delegate?.voiceInputDidFinish(self)
    }

    // MARK: - 内部

    private func refreshReleaseAction(location: CGPoint) {
        guard var state = renderState else { return }
        let previousAction = state.releaseAction
        let nextAction = releaseActionResolver?(location) ?? previousAction
        state.fingerLocation = location
        state.releaseAction = nextAction
        renderState = state
        if previousAction != nextAction {
            print("[AppAgentVoiceInput] selectedAction \(previousAction) -> \(nextAction), location=\(location)")
            feedback.impact(reason: selectionHapticReason(for: nextAction))
        }
        render()
    }

    private func render() {
        guard let renderState else { return }
        delegate?.voiceInput(self, didUpdate: renderState)
    }

    private func beginHapticReason(for source: AppAgentInputBarVoiceInputSource) -> String {
        switch source {
        case .keyboardModeLongPress:
            return "start-keyboard-mode-long-press"
        case .voiceModePress:
            return "start-voice-mode-press"
        }
    }

    private func selectionHapticReason(for action: AppAgentVoiceInputReleaseAction) -> String {
        switch action {
        case .send:
            return "select-send"
        case .cancel:
            return "select-cancel"
        case .edit:
            return "select-edit"
        }
    }
}

#endif
