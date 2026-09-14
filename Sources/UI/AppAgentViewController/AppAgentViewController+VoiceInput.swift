//
//  AppAgentViewController+VoiceInput.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Voice Input（接线层）
//
// 语音输入的状态与策略都在 AppAgentVoiceInputCoordinator 中；
// AppAgentViewController 只负责把手势事件转给协调器、把协调器的语义输出映射到 overlay / inputBar / session。

extension AppAgentViewController {
    /// 初始化语音输入图层：图层常驻在 AppAgentViewController 上，默认隐藏，手势开始时展示。
    func setupVoiceInputOverlay() {
        voiceInputOverlayView.frame = view.bounds
        voiceInputOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        voiceInputOverlayView.onEditCancel = { [weak self] in
            self?.voiceInputCoordinator.editCancel()
        }
        voiceInputOverlayView.onEditSend = { [weak self] text in
            self?.voiceInputCoordinator.editSend(text: text)
        }
        voiceInputCoordinator.delegate = self
        // 几何判定留在 overlay：视图是自身弧形按钮/面板几何的唯一权威。
        voiceInputCoordinator.releaseActionResolver = { [weak self] location in
            self?.voiceInputOverlayView.releaseAction(for: location) ?? .cancel
        }
        view.addSubview(voiceInputOverlayView)
    }

    /// 外部更新实时识别文本时调用：只改文字，不改变手指当前选择的抬起行为。
    public func updateVoiceInputTranscript(_ text: String) {
        voiceInputCoordinator.updateTranscript(text)
    }

    /// 语音输入手势总入口：inputBar 透传值事件，按阶段转给协调器。
    func handleVoiceInputGesture(_ event: AppAgentInputBarVoiceGestureEvent) {
        switch event.phase {
        case .began:
            voiceInputCoordinator.begin(source: event.source, location: event.locationInHost)
        case .moved:
            voiceInputCoordinator.move(to: event.locationInHost)
        case .ended:
            voiceInputCoordinator.end(at: event.locationInHost)
        case .cancelled:
            voiceInputCoordinator.systemCancel(at: event.locationInHost)
        }
    }

    /// 把语音识别文本回填到 inputBar 输入框：切回键盘输入源并聚焦，追加在已有文本之后。
    func backfillVoiceTranscriptToInputBar(_ transcript: String) {
        inputBar.setInputSource(.keyboard, animated: true)
        if !transcript.isEmpty {
            inputBar.text = inputBar.text.isEmpty ? transcript : inputBar.text + transcript
        }
        inputBar.textField.becomeFirstResponder()
    }

    /// 创建语音输入震动发生器：新系统优先绑定 view，旧系统使用传统 medium 样式。
    func makeVoiceRecognitionHapticGenerator() -> UIImpactFeedbackGenerator {
        if #available(iOS 17.5, *) {
            return UIImpactFeedbackGenerator(style: .medium, view: self.view)
        } else {
            return UIImpactFeedbackGenerator(style: .medium)
        }
    }
}

// MARK: - AppAgentVoiceInputCoordinatorDelegate

extension AppAgentViewController: AppAgentVoiceInputCoordinatorDelegate {
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didBeginAt location: CGPoint) {
        voiceInputOverlayView.show(startLocation: location, animated: false)
    }

    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didUpdate renderState: AppAgentVoiceInputRenderState) {
        voiceInputOverlayView.update(
            recognitionState: renderState.recognitionState,
            releaseAction: renderState.releaseAction,
            fingerLocation: renderState.fingerLocation,
            transcriptText: renderState.transcriptText,
            showsTranscriptCursor: renderState.showsTranscriptCursor
        )
    }

    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestBackfill text: String) {
        backfillVoiceTranscriptToInputBar(text)
    }

    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didEnterEditModeWith text: String) {
        voiceInputOverlayView.enterEditMode(text: text)
    }

    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestSend text: String) {
        dispatchOutgoingMessage(text: text)
    }

    func voiceInputDidFinish(_ coordinator: AppAgentVoiceInputCoordinator) {
        voiceInputOverlayView.hide(animated: true)
    }
}

#endif
