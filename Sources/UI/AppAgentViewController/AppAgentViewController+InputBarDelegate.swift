//
//  AppAgentViewController+InputBarDelegate.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - AppAgentInputBarDelegate

extension AppAgentViewController: AppAgentInputBarDelegate {
    func setupInputBar() {
        inputBar.delegate = self
        inputBar.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(inputBar)
    }

    // 场景：文字输入态点击发送或键盘提交文本时触发。
    public func inputBar(_ bar: AppAgentInputBar, didSendText text: String) {
        logInputBarDelegate("didSendText textLength=\(text.count)")
        dispatchOutgoingMessage(text: text)
    }

    // 场景：inputBar 内部切换键盘/语音输入源后触发。
    public func inputBar(_ bar: AppAgentInputBar, didChangeInputSource source: AppAgentInputBarInputSource) {
        logInputBarDelegate("didChangeInputSource source=\(source)")
    }

    // 场景：inputBar 的 textField 激活或失焦时触发，用当前已观察到的键盘高度重新计算 inputBar 是否需要避让。
    public func inputBar(_ bar: AppAgentInputBar, didChangeTextInputFocus isFocused: Bool) {
        logInputBarDelegate("didChangeTextInputFocus isFocused=\(isFocused)")
        layoutInputBar(reason: .keyboard)
        if isFocused {
            scrollToBottom(animated: true)
        }
    }

    // 场景：收起态点击 menu 按钮，或手势结算后判定需要展开输入栏时触发。
    public func inputBarDidRequestExpand(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidRequestExpand")
        expandInputBar(animated: true)
    }

    // 场景：展开态点击 menu 按钮，或手势结算后判定需要收起输入栏时触发。
    public func inputBarDidRequestCollapse(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidRequestCollapse")
        collapseInputBar(animated: true)
    }

    // 场景：拖拽 menu 按钮过程中，inputBar 持续提出 frame 变化意图时触发。
    public func inputBar(
        _ bar: AppAgentInputBar,
        wantsFrame frame: CGRect,
        panKind kind: AppAgentInputBarFramePanKind
    ) {
        logInputBarDelegate("wantsFrame kind=\(kind) frame=\(formatInputBarDelegateRect(frame))")
        let constrainedFrame: CGRect
        switch kind {
        case .expandedResize:
            isDraggingExpandedInputBar = true
            isDraggingCollapsedInputBar = false
            resetCollapsedMoveTracking()
            beginExpandedResizeDecisionTrackingIfNeeded(initialFrame: inputBar.frame)
            constrainedFrame = constrainedExpandedInputBarFrame(frame)
            updateExpandedResizeWidthHoldTracking(width: constrainedFrame.width)
        case .collapsedMove:
            isDraggingExpandedInputBar = false
            isDraggingCollapsedInputBar = true
            resetExpandedResizeInteractionTracking()
            constrainedFrame = rubberBandedCollapsedInputBarFrame(frame)
            resetExpandedResizeWidthHoldTracking()
        }
        let reason: AppAgentInputBarFrameChangeReason = kind == .expandedResize
            ? .expandedResizePan
            : .collapsedMovePan
        applyInputBarFrame(constrainedFrame, animation: .immediate, reason: reason)
        if kind == .expandedResize {
            updateExpandedResizeDecisionHapticIfNeeded(frame: inputBar.frame)
        }
    }

    // 场景：menu 按钮拖拽改变 inputBar frame 的手势结束时触发；展开 resize 和收起 move 在这里统一分发。
    public func inputBar(
        _ bar: AppAgentInputBar,
        didEndFramePan context: AppAgentInputBarFramePanEndContext
    ) {
        logInputBarDelegate(
            "didEndFramePan kind=\(context.kind) velocity=\(formatInputBarDelegatePoint(context.velocity)) frame=\(formatInputBarDelegateRect(context.frame)) didHoldNearFinalPosition=\(context.didHoldNearFinalPosition)"
        )
        switch context.kind {
        case .expandedResize:
            finishExpandedInputBarResize(velocity: context.velocity, frame: context.frame)
        case .collapsedMove:
            finishCollapsedInputBarMove(context)
        }
    }

    // 场景：文字输入态长按输入区域，或语音输入态按住“按住说话”区域时触发；began/moved/ended/cancelled 都通过这个方法透传。
    public func inputBar(
        _ bar: AppAgentInputBar,
        didReceiveVoiceInputGesture event: AppAgentInputBarVoiceGestureEvent
    ) {
        logInputBarDelegate(
            "didReceiveVoiceInputGesture source=\(event.source) phase=\(event.phase) location=\(formatInputBarDelegatePoint(event.locationInHost))"
        )
        handleVoiceInputGesture(event)
    }

    // 场景：点击输入源切换按钮中的语音图标时触发，默认由 inputBar 内部完成键盘/语音模式切换。
    public func inputBarDidTapVoice(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidTapVoice")
        // Override in subclass or set up delegate chain
    }

    // 场景：点击加号按钮时触发，用于宿主接入附件、工具或更多能力入口。
    public func inputBarDidTapPlus(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidTapPlus")
        // Override in subclass or set up delegate chain
    }

    func logInputBarDelegate(_ message: @autoclosure () -> String) {
        guard Self.isInputBarDelegateDebugLoggingEnabled else { return }
        print("[AppAgentInputBarDelegate] \(message())")
    }

    func formatInputBarDelegatePoint(_ point: CGPoint) -> String {
        String(format: "(%.1f, %.1f)", point.x, point.y)
    }

    func formatInputBarDelegateRect(_ rect: CGRect) -> String {
        String(
            format: "(x: %.1f, y: %.1f, w: %.1f, h: %.1f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

}

#endif
