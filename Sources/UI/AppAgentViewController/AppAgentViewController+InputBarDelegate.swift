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

    // 场景：inputBar 的输入框激活或失焦时触发，用当前已观察到的键盘高度重新计算 inputBar 是否需要避让。
    // 激活时面板若收在 peek，自动弹到半屏，让用户输入时能看到对话。
    public func inputBar(_ bar: AppAgentInputBar, didChangeTextInputFocus isFocused: Bool) {
        logInputBarDelegate("didChangeTextInputFocus isFocused=\(isFocused)")
        layoutInputBar(reason: .keyboard)
        if isFocused {
            if chatPanelCoordinator.isAtPeekDetent {
                setChatPanelDetent(.half, animated: true)
            }
            scrollToBottom(animated: true)
        }
    }

    // 场景：草稿换行、清空或切换输入源后，展开态应有高度变了；按新高度重排输入栏与对话面板。
    public func inputBarDidChangeExpandedHeight(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidChangeExpandedHeight")
        layoutInputBar(reason: .layout)
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
        let reason: AppAgentUIChangeReason = kind == .expandedResize
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

    // 场景：点击加号按钮时触发；面板的展开 / 收起由 inputBar 自己完成。
    public func inputBarDidTapPlus(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidTapPlus panel=\(bar.isShowingAttachmentPanel)")
    }

    // 场景：加号面板里点了「图片」或「文件」，弹出对应的系统选择器。
    public func inputBar(_ bar: AppAgentInputBar, didSelectAttachmentSource source: AppAgentInputBarAttachmentSource) {
        logInputBarDelegate("didSelectAttachmentSource source=\(source)")
        attachmentPickSessionId = currentSessionId
        attachmentPicker.present(source, remainingImageSlots: bar.remainingImageAttachmentSlots)
    }

    // 场景：发送前点掉了附件，或再选一个文件替换了旧的；拷进工作区的那份没人会再用，删掉。
    public func inputBar(_ bar: AppAgentInputBar, didDiscardAttachments attachments: [AIAgentMessage.Attachment]) {
        let files = attachments.filter { attachment in
            attachment.kind == .file
        }
        let registry = agent?.profile.fileResources ?? FileResourceRegistry()
        guard !files.isEmpty, let root = registry.descriptor(for: "agent://workspace")?.rootURL else {
            return
        }
        Task.detached(priority: .utility) {
            for file in files {
                AttachmentFileStaging.discard(file, workspaceRoot: root)
            }
        }
    }

    func makeAttachmentPicker() -> AppAgentAttachmentPicker {
        let picker = AppAgentAttachmentPicker()
        picker.presenter = self
        picker.workspaceRoot = { [weak self] in
            let registry = self?.agent?.profile.fileResources ?? FileResourceRegistry()
            return registry.descriptor(for: "agent://workspace")?.rootURL
        }
        picker.onPicked = { [weak self] attachments in
            guard let self else {
                return
            }
            // 图片 / 文件是异步读完的；这期间切走了会话，就不能塞进另一个会话的输入框，拷进来的文件也删掉。
            guard self.currentSessionId == self.attachmentPickSessionId else {
                self.inputBar(self.inputBar, didDiscardAttachments: attachments)
                return
            }
            self.inputBar.addAttachments(attachments)
        }
        picker.onError = { [weak self] message in
            self?.presentAttachmentError(message)
        }
        return picker
    }

    private func presentAttachmentError(_ message: String) {
        guard presentedViewController == nil, !isBeingDismissed else {
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    // 场景：loop 运行中输入框为空，加号位置显示为停止按钮，点击它时触发。
    public func inputBarDidTapStop(_ bar: AppAgentInputBar) {
        logInputBarDelegate("inputBarDidTapStop")
        stopCurrentRun()
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
