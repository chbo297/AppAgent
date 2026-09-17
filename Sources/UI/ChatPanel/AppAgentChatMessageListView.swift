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

    /// 面板可见展示区换算到列表坐标系后的高度；tableView 始终按这个高度布局。
    private var visibleHeight: CGFloat?
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
        applyTableViewFrame()
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
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.automaticallyAdjustsScrollIndicatorInsets = false
        tableView.backgroundColor = .clear
        tableView.register(ChatMessageCell.self, forCellReuseIdentifier: ChatMessageCell.reuseIdentifier)
        addSubview(tableView)
        applyInsets()
    }

    /// 随面板 displayHeight 更新列表的真实可见区域。
    ///
    /// BODragScroll 的 panelView 始终保持 full 尺寸，低档位只展示顶部一段。这里直接把可见段高度作为
    /// tableView 的高度，让 scrollView 视口与展示区一直等高；底部 inset 只保留 inputBar/键盘占位。
    @discardableResult
    func updateVisibleArea(visibleHeight: CGFloat, bottomAvoidingInset: CGFloat) -> Bool {
        let targetVisibleHeight = max(0, visibleHeight)
        let targetBottomInset = max(0, bottomAvoidingInset)
        let visibleHeightChanged = abs(
            targetVisibleHeight - (self.visibleHeight ?? -.greatestFiniteMagnitude)
        ) > 0.5
        let bottomInsetChanged = abs(targetBottomInset - appliedBottomInset) > 0.5
        guard visibleHeightChanged || bottomInsetChanged else { return false }

        let wasFollowingLatestMessage = isNearBottom
        self.visibleHeight = targetVisibleHeight
        appliedBottomInset = targetBottomInset
        if bottomInsetChanged {
            applyInsets()
        }
        if visibleHeightChanged {
            // 每帧都要跟手，直接提交 frame，不排一次完整 layout 周期。
            UIView.performWithoutAnimation { applyTableViewFrame() }
        }
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false)
        }
        return true
    }

    /// tableView 高度跟随可见展示区高度；尚未收到展示高度时退化为整块列表区域。
    private func applyTableViewFrame() {
        let height = visibleHeight.map { min(bounds.height, $0) } ?? bounds.height
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        guard tableView.frame != frame else { return }
        tableView.frame = frame
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
