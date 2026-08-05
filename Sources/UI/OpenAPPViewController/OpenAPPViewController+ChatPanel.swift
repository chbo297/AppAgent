//
//  OpenAPPViewController+ChatPanel.swift
//  OpenAPPUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Chat Panel（接线层）
//
// BODragScroll 的尺寸、档位和滚动交接在 OpenAPPChatPanelCoordinator；
// 这里只把 ViewController 环境、键盘避让和消息通路接到 coordinator。

extension OpenAPPViewController {

    /// 初始化对话流面板：层级插在 inputBar 之下，默认半屏档。
    func setupChatPanel() {
        chatPanelContainer.translatesAutoresizingMaskIntoConstraints = true
        chatPanelContainer.installContentView(chatPanelCoordinator.dragScrollView)
        view.insertSubview(chatPanelContainer, belowSubview: inputBar)

        chatPanelView.onSessionListRequested = { [weak self] in
            self?.toggleSessionSidebar()
        }
        chatPanelView.onCollapseRequested = { [weak self] in
            self?.setChatPanelDetent(.peek, animated: true)
        }
    }

    /// 将当前 viewport、安全区和 inputBar 展开宽度交给 coordinator 更新固定面板几何。
    func layoutChatPanel() {
        let inputBarExpandedFrame = OpenAPPInputBarFramePolicy.preferredExpandedFrame(inputBarLayoutContext)
        chatPanelCoordinator.updateLayout(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame,
            bottomAvoidingInset: chatPanelBottomAvoidingInset
        )
        applyChatPanelContainerLayout(
            inputBarFrame: inputBar.frame,
            inputBarExpandedFrame: inputBarExpandedFrame,
            animation: .immediate
        )
    }

    /// 【inputBar frame 接线点】同步 ChatPanel 的横向 frame、alpha，以及键盘触发的整体上移。
    func applyChatPanelContainerLayout(
        inputBarFrame: CGRect,
        inputBarExpandedFrame: CGRect,
        animation: OpenAPPInputBarFrameAnimation
    ) {
        let keyboardLift = chatPanelKeyboardLift(for: inputBarExpandedFrame)
        let shiftedBounds = view.bounds.offsetBy(dx: 0, dy: -keyboardLift)
        let layout = OpenAPPChatPanelContainerLayout(
            bounds: shiftedBounds,
            inputBarFrame: inputBarFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )
        chatPanelContainer.apply(layout, animation: animation)
    }

    /// inputBar 展开态相对无键盘底部位置实际上移的距离；其他输入框触发键盘时结果为 0。
    private func chatPanelKeyboardLift(for inputBarExpandedFrame: CGRect) -> CGFloat {
        let restingInputBarBottom = view.bounds.maxY - max(0, view.safeAreaInsets.bottom)
        return max(0, restingInputBarBottom - inputBarExpandedFrame.maxY)
    }

    /// 业务主动切换档位，实际动画和中途打断由 BODragScroll 管理。
    func setChatPanelDetent(_ detent: OpenAPPChatPanelDetent, animated: Bool) {
        chatPanelCoordinator.move(to: detent, animated: animated)
    }

    /// 将消息列表滚到最新一条；真实 session、mock、键盘和 inputBar 共用这一条路径。
    func scrollToBottom(animated: Bool) {
        chatPanelView.listView.scrollToBottom(animated: animated)
    }

    /// mock 与真实 session 共用：新消息出现时若面板收在 peek，直接发起一次 half 移动。
    func revealChatPanelForNewMessagesIfNeeded() {
        guard chatPanelCoordinator.isAtPeekDetent else { return }
        setChatPanelDetent(.half, animated: true)
    }

    /// 列表底部避让：ChatPanel 已随自身 inputBar 上移时只保留安全区，否则继续避让外部键盘。
    func updateChatPanelListInsets() {
        chatPanelCoordinator.updateBottomAvoidingInset(chatPanelBottomAvoidingInset)
    }

    private var chatPanelBottomAvoidingInset: CGFloat {
        let bottomOcclusion = shouldInputBarAvoidKeyboard
            ? view.safeAreaInsets.bottom
            : max(view.safeAreaInsets.bottom, observedKeyboardHeight)
        return bottomOcclusion
            + OpenAPPInputBar.barHeight
            + 12
    }

    // MARK: - 消息通路

    /// 发送分发：UI 调试模式走模拟回路，否则走真实 session；两者使用同一个 ChatPanel 列表。
    func dispatchOutgoingMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if usesFixedDebugReply {
            sendFixedDebugReply(to: trimmed)
        } else {
            sendMessage(text: trimmed)
        }
    }

    private func sendFixedDebugReply(to text: String) {
        inputBar.clearText()

        let userMessage = ChatMessage(role: .user, text: text)
        chatMessages.append(userMessage)
        chatPanelView.listView.append(userMessage, followLatest: false)

        let replyMessage = ChatMessage(role: .assistant, text: "收到了")
        chatMessages.append(replyMessage)
        chatPanelView.listView.append(replyMessage, followLatest: false)

        // 面板收着时来了新消息，自动弹到半屏，让用户看到回复。
        revealChatPanelForNewMessagesIfNeeded()
        scrollToBottom(animated: true)
    }
}

#endif
