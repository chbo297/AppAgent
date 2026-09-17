//
//  AppAgentChatMessageListView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 对话流面板的聊天内容区：渲染 [ChatMessage]，复用 ChatMessageCell 气泡样式。
/// 只负责保存展示快照与滚动，不决定消息来源；追加/流式更新由宿主调用。
final class AppAgentChatMessageListView: UIView {

    private(set) var messages: [ChatMessage] = []

    private let tableView = UITableView()
    private var appliedBottomInset: CGFloat = 0
    private var pendingScrollToBottomAnimated: Bool?

    /// 交给 BODragScroll 捕获和协调的唯一内部纵向滚动视图。
    var participantScrollView: UIScrollView { tableView }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds
        guard let animated = pendingScrollToBottomAnimated,
              bounds.width > 0,
              bounds.height > 0 else { return }
        pendingScrollToBottomAnimated = nil
        tableView.layoutIfNeeded()
        scrollToBottom(animated: animated)
    }

    // MARK: - 数据操作

    func setMessages(_ messages: [ChatMessage]) {
        self.messages = messages
        tableView.reloadData()
        if messages.isEmpty {
            pendingScrollToBottomAnimated = nil
            return
        }
        scrollToBottom(animated: false)
    }

    func append(_ message: ChatMessage, followLatest: Bool? = nil) {
        append(contentsOf: [message], followLatest: followLatest)
    }

    /// 一次追加多条消息并只刷新、滚动一次，适合“用户消息 + 流式占位”成对插入。
    func append(contentsOf newMessages: [ChatMessage], followLatest: Bool? = nil) {
        guard !newMessages.isEmpty else { return }
        let shouldFollowLatestMessage = followLatest ?? isNearBottom
        messages.append(contentsOf: newMessages)
        tableView.reloadData()
        if shouldFollowLatestMessage {
            scrollToBottom(animated: true)
        }
    }

    /// 流式更新最后一条消息（文本与状态），用于模拟/真实的模型逐字输出。
    func updateLastMessage(text: String, status: ChatMessage.Status) {
        guard !messages.isEmpty else { return }
        let wasFollowingLatestMessage = isNearBottom
        messages[messages.count - 1].text = text
        messages[messages.count - 1].status = status
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.reloadRows(at: [indexPath], with: .none)
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false)
        }
    }

    /// 更新最后一条消息的「思考 / 执行过程」时间线并按需切换展开态。
    func updateLastActivity(_ timeline: AppAgentActivityTimeline, expanded: Bool? = nil) {
        guard !messages.isEmpty else { return }
        let wasFollowingLatestMessage = isNearBottom
        messages[messages.count - 1].activity = timeline
        if let expanded = expanded {
            messages[messages.count - 1].isActivityExpanded = expanded
        }
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.reloadRows(at: [indexPath], with: .none)
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false)
        }
    }

    /// 折叠 / 展开某条消息的过程区（点击折叠行触发）。
    func toggleActivityExpanded(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].isActivityExpanded.toggle()
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
    }

    // MARK: - 内部

    private func setup() {
        backgroundColor = .clear
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        // 滑动消息列表不联动收键盘（系统能力 keyboardDismissMode），键盘只由输入栏手势与点击控制。
        tableView.keyboardDismissMode = .none
        // 内部列表自身不做顶部/底部橡皮筋：到边界即把位移交给外层面板（bounce 归外层卡片）。
        tableView.bounces = false
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.automaticallyAdjustsScrollIndicatorInsets = false
        tableView.backgroundColor = .clear
        tableView.register(ChatMessageCell.self, forCellReuseIdentifier: ChatMessageCell.reuseIdentifier)
        addSubview(tableView)
        applyInsets()
    }

    /// 随面板 displayHeight 更新列表的真实可见区域。
    ///
    /// BODragScroll 的 panelView 始终保持 full 尺寸，低档位只展示顶部一段；因此需要把未展示的
    /// panel 高度并入 tableView.bottomInset，`scrollToBottom` 才会停在屏幕当前可见的底边上方。
    @discardableResult
    func updateViewport(
        panelHeight: CGFloat,
        displayHeight: CGFloat,
        bottomAvoidingInset: CGFloat
    ) -> Bool {
        let hiddenPanelHeight = max(0, panelHeight - displayHeight)
        let targetBottomInset = max(0, bottomAvoidingInset) + hiddenPanelHeight
        guard abs(targetBottomInset - appliedBottomInset) > 0.5 else { return false }

        let wasFollowingLatestMessage = isNearBottom
        appliedBottomInset = targetBottomInset
        applyInsets()
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false)
        }
        return true
    }

    /// 将最新消息移动到当前有效可见区域底部。
    func scrollToBottom(animated: Bool) {
        guard !messages.isEmpty else { return }
        guard bounds.width > 0,
              bounds.height > 0,
              tableView.bounds.width > 0,
              tableView.bounds.height > 0 else {
            pendingScrollToBottomAnimated = animated
            return
        }
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
    }

    private var isNearBottom: Bool {
        guard !messages.isEmpty else { return true }
        let minimumOffsetY = -tableView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            tableView.contentSize.height
                + tableView.adjustedContentInset.bottom
                - tableView.bounds.height
        )
        return tableView.contentOffset.y >= maximumOffsetY - 24
    }

    private func applyInsets() {
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: appliedBottomInset, right: 0)
        tableView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: appliedBottomInset, right: 0)
    }
}

// MARK: - UITableViewDataSource

extension AppAgentChatMessageListView: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatMessageCell.reuseIdentifier,
            for: indexPath
        ) as! ChatMessageCell
        let message = messages[indexPath.row]
        cell.configure(with: message)
        cell.onToggleActivity = { [weak self] in
            self?.toggleActivityExpanded(messageID: message.id)
        }
        return cell
    }
}

#endif
