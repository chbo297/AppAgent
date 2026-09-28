//
//  AppAgentViewController+ChatPanel.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Chat Panel（接线层）
//
// BODragScroll 的尺寸、档位和滚动交接在 AppAgentChatPanelCoordinator；
// 这里只把 ViewController 环境、键盘避让和消息通路接到 coordinator。

extension AppAgentViewController {

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
        chatPanelView.onNewSessionRequested = { [weak self] in
            self?.startNewSession()
        }
        chatPanelCoordinator.onWillRevealMessages = { [weak self] in
            self?.prepareChatForPresentation()
        }
        // 过程区展开态由 ViewController 持有：列表每轮结束都会整体重建，
        // 只有把「用户点开了哪一轮」记在这边才不会被重建擦掉。
        chatPanelView.listView.onActivityToggled = { [weak self] message in
            self?.handleActivityToggled(message)
        }
    }

    /// 重新进入同一个页面也属于重新浏览；先读取权威终局，再释放留白。
    /// 普通布局、键盘变化和运行通知不走这里，也不清除已展示的 reasoning / 展开选择。
    func prepareChatForPresentation() {
        guard isViewLoaded else { return }
        // 发送消息会先插入乐观占位再自动展开；此时 Core 可能尚未建立本轮记录。
        // 不能用上一轮快照覆盖刚插入的提问与占位。
        if let latest = chatMessages.last,
           latest.role == .assistant, latest.status == .streaming, latest.turnID == nil {
            guard let start = latest.activity?.startedAt,
                  let session = currentSession,
                  let record = session.turnRecord(turnID: session.currentTurnID),
                  record.startedAt >= start else { return }
        }
        if currentSession != nil {
            reloadFromSession(reason: .browsing)
        } else {
            chatPanelView.listView.beginNewPresentation()
        }
    }

    /// 新建一个会话并切换过去；未绑定 agent 时无操作。
    func startNewSession() {
        guard let agent else { return }
        Task { @MainActor in
            let session = await agent.createSession(title: "对话")
            switchSession(to: session.id)
        }
    }

    /// 将当前 viewport、安全区和 inputBar 展开宽度交给 coordinator 更新固定面板几何。
    func layoutChatPanel() {
        let inputBarExpandedFrame = AppAgentInputBarFramePolicy.preferredExpandedFrame(inputBarLayoutContext)
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
        animation: AppAgentInputBarFrameAnimation
    ) {
        let keyboardLift = chatPanelKeyboardLift(for: inputBarExpandedFrame)

        // 面板几何与键盘、inputBar 宽度都无关：键盘只把整个容器上移（下面的 `shiftedBounds`），
        // inputBar 的可变展开宽只驱动容器横向平移，面板尺寸只按 view 算。
        chatPanelCoordinator.updateLayout(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets
        )

        let shiftedBounds = view.bounds.offsetBy(dx: 0, dy: -keyboardLift)
        let layout = AppAgentChatPanelContainerLayout(
            bounds: shiftedBounds,
            inputBarFrame: inputBarFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )
        // 横向完全收起后重新展开；用实际显隐边界，不能把每帧 resize 当成重新进入。
        if chatPanelContainer.alpha <= 0.01, chatPanelContainer.isVisuallyHidden,
           layout.panelAlpha > 0.01 {
            prepareChatForPresentation()
        }
        chatPanelContainer.apply(layout, animation: animation)

        // 决策卡片要停在 inputBar 上方：面板 viewport 会一直延伸到 inputBar 底下那一段。
        let panelBottomInView = chatPanelContainer.frame.maxY
        chatPanelView.decisionCardBottomInset = max(0, panelBottomInView - inputBarFrame.minY + 8)
    }

    /// inputBar 展开态相对无键盘底部位置实际上移的距离；其他输入框触发键盘时结果为 0。
    private func chatPanelKeyboardLift(for inputBarExpandedFrame: CGRect) -> CGFloat {
        let restingInputBarBottom = view.bounds.maxY - max(0, view.safeAreaInsets.bottom)
        return max(0, restingInputBarBottom - inputBarExpandedFrame.maxY)
    }

    /// 业务主动切换档位，实际动画和中途打断由 BODragScroll 管理。
    func setChatPanelDetent(_ detent: AppAgentChatPanelDetent, animated: Bool, source: String = #function) {
        chatPanelCoordinator.move(to: detent, animated: animated, source: "VC.\(source)")
    }

    /// 将消息列表滚到最新一条；真实 session、mock、键盘和 inputBar 共用这一条路径。
    func scrollToBottom(animated: Bool, source: String = #function) {
        chatPanelView.listView.scrollToBottom(animated: animated, source: "VC.\(source)")
    }

    /// mock 与真实 session 共用：新消息出现时若面板收在 peek，直接发起一次 half 移动。
    func revealChatPanelForNewMessagesIfNeeded() {
        guard chatPanelCoordinator.isAtPeekDetent else { return }
        chatPanelCoordinator.move(to: .half, animated: true, preservingReplyHeight: true)
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

    /// 发送后收尾：清空草稿并收起键盘（两条发送通路共用，别各写一份）。
    func finishInputBarAfterSend() {
        inputBar.clearText()
        inputBar.textField.resignFirstResponder()
    }

    private func sendFixedDebugReply(to text: String) {
        finishInputBarAfterSend()

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
