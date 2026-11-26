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

    /// 初始化会话容器和对话流面板：会话容器铺满、插在 inputBar 之下，面板在它里面，默认半屏档。
    func setupChatPanel() {
        sessionContainer.frame = view.bounds
        sessionContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(sessionContainer, belowSubview: inputBar)
        chatPanelContainer.translatesAutoresizingMaskIntoConstraints = true
        chatPanelContainer.installContentView(chatPanelCoordinator.dragScrollView)
        sessionContainer.installChatPanel(chatPanelContainer)

        chatPanelView.onSessionListRequested = { [weak self] in
            self?.toggleSessionSidebar()
        }
        // 面板可见区（展示位置 + 高度）变化的第二个来源：竖向拖拽不经过 inputBar 那条路，
        // 只有面板自己知道。收起进度若改变了输入栏让出的预留高度，就在同一帧（同一动画上下文）
        // 重排输入栏。正在 `applyInputBarFrame` 里时沿用那一次的原因，重排由它收尾补做。
        chatPanelView.onViewportChanged = { [weak self] in
            guard let self else { return }
            if self.currentUIChangeReason == nil,
               self.relayoutInputBarIfReservedLiftChanged(reason: .chatPanelHeightPan) {
                return
            }
            self.notifyUIStateChangeIfNeeded(
                reason: self.currentUIChangeReason ?? .chatPanelHeightPan
            )
        }
        chatPanelView.onCollapseRequested = { [weak self] in
            self?.setChatPanelDetent(.peek, animated: true)
        }
        chatPanelView.onNewSessionRequested = { [weak self] in
            self?.startNewSession()
        }
        chatPanelView.onSessionSettingsRequested = { [weak self] in
            self?.presentSessionSettings()
        }
        chatPanelView.navigationBar.onAccessoryTapped = { [weak self] in
            self?.onNavigationAccessoryTapped?()
        }
        chatPanelCoordinator.onWillRevealMessages = { [weak self] in
            self?.prepareChatForPresentation()
        }
        chatPanelCoordinator.onDetentSettled = { [weak self] detent in
            self?.chatPanelDidSettle(at: detent)
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
        Task { @MainActor [weak self] in
            let session = await agent.createSession(title: "对话")
            guard let self, self.agent === agent else { return }
            self.switchSession(to: session.id)
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
        // inputBar 的可变展开宽只驱动容器横向平移。宿主底部预留高度只抬高 peek 档（紧凑框对齐抬高后的
        // 输入栏）；面板仍铺到屏幕底部，展开时底部延伸、输入栏同步回到安全区位置。
        chatPanelCoordinator.updateLayout(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            inputBarHeight: inputBarExpandedFrame.height,
            hostReservedBottomHeight: effectiveHostReservedBottomHeight
        )
        // 宿主要求了底部避让（超过 1 像素）时，输入栏下方让出的那段不挡宿主的点击和滑动。
        let pixel = 1 / max(1, view.traitCollection.displayScale)
        chatPanelView.passesTouchesBelowViewport = effectiveHostReservedBottomHeight > pixel

        let shiftedBounds = view.bounds.offsetBy(dx: 0, dy: -keyboardLift)
        let layout = AppAgentChatPanelContainerLayout(
            bounds: shiftedBounds,
            inputBarFrame: inputBarFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )
        // 横向完全收起后重新展开；用实际显隐边界，不能把每帧 resize 当成重新进入。
        if sessionContainer.alpha <= 0.01, sessionContainer.isVisuallyHidden,
           layout.contentAlpha > 0.01 {
            prepareChatForPresentation()
        }
        chatPanelContainer.apply(layout, animation: animation)
        // 收起成小球时面板和工作区一起淡出；面板的位置、宽度和键盘位移仍只作用在面板容器上。
        sessionContainer.applyContentAlpha(layout.contentAlpha, animation: animation)

        // 决策卡片要停在 inputBar 上方：面板 viewport 会一直延伸到 inputBar 底下那一段。
        let panelBottomInView = chatPanelContainer.frame.maxY
        chatPanelView.decisionCardBottomInset = max(0, panelBottomInView - inputBarFrame.minY + 8)
    }

    /// 工作区容器挂进会话容器，位于对话面板之下。由 `AppAgentWorkspace` 在要显示工作区时调用。
    func installWorkspaceContainer(_ container: UIViewController) {
        loadViewIfNeeded()
        addChild(container)
        sessionContainer.installWorkspace(container.view)
        container.didMove(toParent: self)
    }

    /// inputBar 展开态相对无键盘静止位置（含此刻让出的宿主预留高度）实际上移的距离；其他输入框触发键盘时结果为 0。
    private func chatPanelKeyboardLift(for inputBarExpandedFrame: CGRect) -> CGFloat {
        let restingInputBarBottom = view.bounds.maxY - max(0, view.safeAreaInsets.bottom)
            - hostReservedBottomLift
        return max(0, restingInputBarBottom - inputBarExpandedFrame.maxY)
    }

    /// 按会话保存的档位摆面板。输入框收成小球时面板看不见，只记下档位，展开时就在这一档。
    func applySessionChatPanel(_ panel: SessionChatPanel, animated: Bool) {
        let detent: AppAgentChatPanelDetent
        switch panel {
        case .collapsed:
            detent = .peek
        case .half:
            detent = .half
        case .full:
            detent = .full
        }
        guard chatPanelCoordinator.currentDetent != detent else {
            return
        }
        setChatPanelDetent(detent, animated: animated && isViewLoaded && !inputBar.isCollapsed)
    }

    /// 用户把面板拖停在某一档（或新消息自动展开）后写回当前会话。
    func chatPanelDidSettle(at detent: AppAgentChatPanelDetent) {
        let panel: SessionChatPanel
        switch detent {
        case .peek:
            panel = .collapsed
        case .half:
            panel = .half
        case .full:
            panel = .full
        }
        currentSession?.setChatPanel(panel)
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
    /// 输入栏里待发送的图片 / 文件随这一条一起发出（打字发送与语音转文字都走这里）。
    func dispatchOutgoingMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = inputBar.attachments
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            return
        }
        if usesFixedDebugReply {
            sendFixedDebugReply(to: trimmed, attachments: attachments)
        } else {
            sendMessage(text: trimmed, attachments: attachments)
        }
    }

    /// 发送后收尾：清空草稿与附件并收起键盘（两条发送通路共用，别各写一份）。
    func finishInputBarAfterSend() {
        inputBar.clearText()
        inputBar.removeAllAttachments()
        inputBar.textView.resignFirstResponder()
    }

    private func sendFixedDebugReply(to text: String, attachments: [AIAgentMessage.Attachment]) {
        finishInputBarAfterSend()

        let userMessage = ChatMessage(role: .user, text: text, attachments: attachments)
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
