//
//  AppAgentChatMessageListView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

/// 对话流面板的聊天内容区：渲染 [ChatMessage]，复用 ChatMessageCell 气泡样式。
/// 只负责保存展示快照与滚动，不决定消息来源；追加/流式更新由宿主调用。
final class AppAgentChatMessageListView: UIView {

    /// 内容与 inputBar 之间的呼吸间距：滑到最底部时最后一条消息不贴着输入栏。
    static let contentBottomSpacing: CGFloat = 20

    /// 尚未完成外层布局时使用的兜底高度。正常运行会在 coordinator 首次拿到几何后，
    /// 改为「半屏有效列表高度 - 底部保留区 - 一行用户消息」。
    static let fallbackLatestReplyInitialHeight: CGFloat = 400
    /// 用户消息至少保留最后一行可见；多行消息也只要求保留最后 44pt。
    static let latestReplyUserTailHeight: CGFloat = 44
    static let latestReplyHeightStep: CGFloat = 34
    private var latestReplyInitialHeight: CGFloat = fallbackLatestReplyInitialHeight
    private var latestReplyAllocatedHeight: CGFloat = fallbackLatestReplyInitialHeight
    private var latestReplyHasGrownBeyondInitialHeight = false
    private var latestReplyInitialHeightHasBeenResolved = false
    private var reservesLatestReplyHeight = false

    /// 可见区变化时使用的底部同步来源。
    ///
    /// `.normal` 用于消息/布局的一次性更新；`.tracking` 用于 BODragScroll
    /// 连续发布展示高度时的逐帧更新。
    enum VisibleAreaSyncMode: Equatable {
        case normal
        case tracking

        var label: String {
            switch self {
            case .normal: return "normal"
            case .tracking: return "tracking"
            }
        }
    }

    private struct BottomSyncPolicy {
        let followTolerance: CGFloat
        let writeTolerance: CGFloat
        let alignmentPassLimit: Int
    }

    /// 跟手过程只用来消除浮点噪声，不作为普通滚动的全局容差。
    private static let trackingBottomTolerance: CGFloat = 0.001

    /// 对齐到底部最多重试几趟。
    ///
    /// 行高精确之后一趟就到位；留两趟是兜底：cell 内部若有异步内容（图片、字体加载）在这一帧改了高度，
    /// 第二趟能把 offset 补上。
    private static let bottomAlignmentPassLimit = 3

    private(set) var messages: [ChatMessage] = []

    /// 用户点了某条消息的过程区折叠行之后回调，带上切换后的那条消息。
    /// 宿主（ViewController）用它把展开态同步到自己的快照与「已展开的轮次」集合里，
    /// 否则下一次整体重建就把用户点开的过程区又折回去了。
    var onActivityToggled: ((ChatMessage) -> Void)?

    private let tableView = UITableView()
    private var appliedBottomInset: CGFloat = 0
    /// reloadData 延迟到布局才更新 cell；增量更新前先提交，避免操作上一份快照的行。
    private var needsReloadLayout = false

    /// 行高自己算并缓存，不走系统估算（见 `ChatMessageHeightCache` 头部注释）。
    private let heightCache = ChatMessageHeightCache()

    /// 过程明细的阅读位置，按行身份持有。
    ///
    /// 和行高缓存同一个道理：cell 是复用的，位置存在 cell 里就会随复用漂移（滚出屏幕再滚回来
    /// 归零、或者继承上一个占用这格的行）。身份用 `ChatRowIdentity`（turnID + role），
    /// 跨重建稳定；换会话 / 清历史由 `setMessages` 一并清掉。
    private var activityDetailPositions: [ChatRowIdentity: AppAgentActivityDetailPosition] = [:]

    /// 上一次测量行高时用的宽度；宽度变了要整体重测。
    private var measuredWidth: CGFloat = 0

    /// 面板可见展示区换算到列表坐标系后的高度；tableView 始终按这个高度布局。
    private var visibleHeight: CGFloat?
    private var pendingScrollToBottomAnimated: Bool?
    private var pendingScrollTraceSource: String?
    private var pendingScrollSyncMode: VisibleAreaSyncMode?
    let scrollTrace = AppAgentChatScrollTrace()

    /// 消息列表滚动视图；过程明细的嵌套 scrollView 由 BODragScroll 按触点祖先链发现。
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
        let source = pendingScrollTraceSource ?? "unknown"
        let syncMode = pendingScrollSyncMode ?? .normal
        pendingScrollToBottomAnimated = nil
        pendingScrollTraceSource = nil
        pendingScrollSyncMode = nil
        // scrollToBottom 内部已经 layoutIfNeeded，这里不必再跑一遍。
        scrollToBottom(
            animated: animated,
            source: "pending:\(source)",
            syncMode: syncMode
        )
    }

    // MARK: - 数据操作

    /// 整体替换列表内容。
    ///
    /// `forceScrollToBottom` 只在「换了会话 / 首次装载」这类应当回到最新一条的场合传 true。
    /// 每轮结束都会重建列表，若无条件滚到底，正在翻历史的用户会被拽回底部。
    /// `preservingReplyHeight` 区分连续更新与重新浏览，与是否滚到底部无关。
    func setMessages(
        _ messages: [ChatMessage],
        forceScrollToBottom: Bool = true,
        preservingReplyHeight: Bool = true
    ) {
        let wasFollowingLatestMessage = isFollowingBottom(source: "setMessages")
        let isRunningReply = messages.last?.role == .assistant && messages.last?.status == .streaming
        if isSameLatestReply(in: messages) {
            // 乐观占位（还没拿到 turnID）转成权威记录时行身份会变，阅读位置要跟着搬过去，
            // 否则「本轮刚读到一半」会在第一次权威重建时归零。
            migrateActivityDetailPosition(to: messages)
        } else {
            resetLatestReplyHeight()
        }
        if isRunningReply {
            reservesLatestReplyHeight = true
        } else if !preservingReplyHeight {
            resetLatestReplyHeight()
        }
        self.messages = messages
        let identities = Set(messages.map(ChatRowIdentity.init))
        heightCache.retain(identities)
        // 已经不在列表里的行不再保留阅读位置：换会话 / 清历史走的就是这条路
        // （`setMessages([])` → identities 为空 → 全清）。
        activityDetailPositions = activityDetailPositions.filter { identities.contains($0.key) }
        reserveLatestReplyHeight()
        scrollTrace.observe("reloadData", on: tableView,
                            details: "rows=\(messages.count) forceFollow=\(forceScrollToBottom) follow=\(wasFollowingLatestMessage)") {
            reloadTableData()
        }
        if messages.isEmpty {
            pendingScrollToBottomAnimated = nil
            pendingScrollTraceSource = nil
            pendingScrollSyncMode = nil
            return
        }
        guard forceScrollToBottom || wasFollowingLatestMessage else { return }
        scrollToBottom(animated: false, source: "setMessages")
    }

    func append(_ message: ChatMessage, followLatest: Bool? = nil) {
        append(contentsOf: [message], followLatest: followLatest)
    }

    /// 一次追加多条消息并只刷新、滚动一次，适合“用户消息 + 流式占位”成对插入。
    func append(contentsOf newMessages: [ChatMessage], followLatest: Bool? = nil) {
        guard !newMessages.isEmpty else { return }
        let shouldFollowLatestMessage = followLatest
            ?? isFollowingBottom(source: "append")
        resetLatestReplyHeight()
        messages.append(contentsOf: newMessages)
        // append 是当次新回复（含同步完成的 mock）；加载历史走 setMessages。
        reservesLatestReplyHeight = messages.last?.role == .assistant
        reserveLatestReplyHeight()
        scrollTrace.observe("reloadData", on: tableView,
                            details: "rows=\(messages.count) override=\(String(describing: followLatest)) follow=\(shouldFollowLatestMessage)") {
            reloadTableData()
        }
        if shouldFollowLatestMessage {
            scrollToBottom(animated: true, source: "append")
        }
    }

    /// 更新新一轮最新 assistant 的默认占位高度。
    ///
    /// 半屏列表的视口虽然已经扣除了拖拽指示条和顶栏，但 tableView 仍会在底部
    /// 留出 inputBar / 安全区 / 呼吸间距。因此这些底部保留区也必须从可分配回复高度
    /// 中扣掉，才能让滚到底时用户消息至少露出最后 44pt。
    ///
    /// 首次有效几何可以替换临时 fallback；当前回复已经展示后，后续几何只允许增高，
    /// 不会破坏连续阅读中的已有分配。
    func updateLatestReplyInitialHeight(
        halfScreenVisibleHeight: CGFloat,
        bottomInset: CGFloat
    ) {
        let normalizedHeight = max(
            ChatMessageHeightCache.fallbackHeight,
            halfScreenVisibleHeight
                - max(0, bottomInset)
                - Self.contentBottomSpacing
                - Self.latestReplyUserTailHeight
        )
        let isFirstResolvedGeometry = !latestReplyInitialHeightHasBeenResolved
        latestReplyInitialHeightHasBeenResolved = true
        guard isFirstResolvedGeometry
            || abs(normalizedHeight - latestReplyInitialHeight) > 0.5 else {
            return
        }

        latestReplyInitialHeight = normalizedHeight
        // A terminal reply keeps the height assigned during this presentation.
        // Geometry changes only rebase a reply that is still streaming; the next
        // presentation can release the terminal allocation explicitly.
        if reservesLatestReplyHeight,
           messages.last?.status == .streaming,
           !messages.isEmpty {
            let nextAllocation: CGFloat
            if isFirstResolvedGeometry && !latestReplyHasGrownBeyondInitialHeight {
                // Replace the temporary fallback only when the reply has not
                // already grown during the geometry-less window.
                nextAllocation = normalizedHeight
            } else {
                // Once a reply has been presented, geometry changes can only
                // increase its reserved height.
                nextAllocation = max(latestReplyAllocatedHeight, normalizedHeight)
            }
            guard abs(nextAllocation - latestReplyAllocatedHeight) > 0.5 else {
                return
            }
            latestReplyAllocatedHeight = nextAllocation
            reloadTableData()
        }
    }

    /// 流式更新某条消息（文本与状态），用于模型逐字输出。
    ///
    /// 按 id 定位而不是「最后一行」：流式正文属于本轮的 agent 气泡，而最后一行完全
    /// 可能是用户气泡（和 `updateActivity` 用同一套定位口径）。
    func updateMessage(text: String, status: ChatMessage.Status, messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let wasFollowingLatestMessage = isFollowingBottom(source: "updateMessage")
        let previousHeight = rowHeight(at: index)
        messages[index].text = text
        messages[index].status = status
        if index == messages.count - 1, messages[index].role == .assistant, status == .streaming {
            reservesLatestReplyHeight = true
        }
        refreshRow(at: index, previousHeight: previousHeight)
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false, source: "updateMessage")
        }
    }

    /// 原位配置 cell；只有高度变化才让表格重新取高，不能用 reloadRows 替换 cell。
    /// 展开/收起时替换透明 cell 会让新旧正文在不同位置短暂同时可见。
    private func refreshRow(
        at index: Int,
        previousHeight: CGFloat,
        synchronizeLayout: Bool = false
    ) {
        guard messages.indices.contains(index) else { return }
        let indexPath = IndexPath(row: index, section: 0)
        // 内容已经写进模型了，先把尾回复的已分配高度推到位，再读这一行现在该有多高。
        reserveLatestReplyHeight()
        let newHeight = rowHeight(at: index)
        // 首次未布局，或已展示的面板暂时收至零高：不 batch，但必须让下次布局读取新内容/
        // 行高。同宽恢复视口不会触发宽度重测，不能只更新模型后直接丢掉这次刷新。
        guard tableView.bounds.width > 0, tableView.bounds.height > 0 else {
            reloadTableData()
            return
        }
        if needsReloadLayout {
            needsReloadLayout = false
            tableView.layoutIfNeeded()
        }
        // 空 batch 不增删行，前后行数必须一致。首次装载/全量替换尚未提交时走全量同步，
        // 不向 UIKit 提交一个建立在旧行数上的更新事务。
        guard tableView.numberOfSections == 1,
              tableView.numberOfRows(inSection: 0) == messages.count else {
            reloadTableData()
            if synchronizeLayout { tableView.layoutIfNeeded() }
            return
        }
        let cell = tableView.cellForRow(at: indexPath) as? ChatMessageCell
        configure(cell, at: index)
        if abs(newHeight - previousHeight) <= 0.5 {
            // 包括离屏行：同高度不用 batch，也不为拿到 cell 而主动 dequeue。
            if synchronizeLayout {
                cell?.setNeedsLayout()
                cell?.layoutIfNeeded()
            }
            return
        }
        scrollTrace.observe("rowHeight", on: tableView,
                            details: "row=\(index) heightBefore=\(previousHeight) heightAfter=\(newHeight)") {
            // heightForRowAt 使用缓存；其余行只取缓存值，不重新渲染正文。
            // 同步提交、不持有 indexPath 的异步 completion，切会话后不会回写旧行。
            tableView.performBatchUpdates(nil, completion: nil)
            if synchronizeLayout {
                tableView.layoutIfNeeded()
            }
        }
    }

    /// 配置 cell 的唯一入口：顺带把过程阅读位置注入进去、把用户滚动回写到列表。
    ///
    /// `cellForRowAt`（新出屏的行）和 `refreshRow`（原位更新现有 cell）都走这里，
    /// 两条路径不能一条带位置一条不带 —— 否则原位刷新会把刚恢复的位置又丢掉。
    private func configure(_ cell: ChatMessageCell?, at index: Int) {
        guard let cell, messages.indices.contains(index) else { return }
        let message = messages[index]
        let identity = ChatRowIdentity(message)
        cell.onActivityDetailPositionChanged = { [weak self] position in
            self?.activityDetailPositions[identity] = position
        }
        cell.configure(with: message, activityDetailPosition: activityDetailPositions[identity])
    }

    private func reloadTableData() {
        needsReloadLayout = true
        tableView.reloadData()
    }

    /// 更新指定消息的「思考 / 执行过程」时间线并按需切换展开态。
    ///
    /// 按 id 定位而不是「最后一行」：过程区只属于 assistant 气泡，而最后一行完全
    /// 可能是用户气泡（本轮还没吐出任何正文时列表末尾就是提问）。
    func updateActivity(
        _ timeline: AppAgentActivityTimeline,
        expanded: Bool? = nil,
        messageID: UUID
    ) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let wasFollowingLatestMessage = isFollowingBottom(source: "updateActivity")
        let previousHeight = rowHeight(at: index)
        let expansionChanged = expanded.map { $0 != messages[index].isActivityExpanded } ?? false
        messages[index].activity = timeline
        if let expanded = expanded {
            messages[index].isActivityExpanded = expanded
        }
        refreshRow(
            at: index,
            previousHeight: previousHeight,
            synchronizeLayout: expansionChanged
        )
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false, source: "updateActivity")
        }
    }

    /// 折叠 / 展开某条消息的过程区（点击折叠行触发）。
    func toggleActivityExpanded(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let wasFollowingLatestMessage = isFollowingBottom(source: "toggleActivity")
        let previousHeight = rowHeight(at: index)
        messages[index].isActivityExpanded.toggle()
        scrollTrace.observe("toggleActivity", on: tableView, force: true,
                            details: "row=\(index) expanded=\(messages[index].isActivityExpanded)") {
            refreshRow(at: index, previousHeight: previousHeight, synchronizeLayout: true)
        }
        onActivityToggled?(messages[index])
        if wasFollowingLatestMessage {
            scrollToBottom(animated: false, source: "toggleActivity")
        }
    }

    // MARK: - 内部

    private func setup() {
        backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        // 行高由 heightCache 精确给出，关掉系统估算：估算会让 contentSize 先是假值、
        // 随 cell 陆续测量而变大，「滚到底部」就永远在追一个动目标。
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 0
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
    /// tableView 的高度，让 scrollView 视口与展示区一直等高；`bottomInset` 是展开态 inputBar 白色背景
    /// 顶部到屏幕底部的固定高度，只在安全区/bar 高度变化时才会变，不随面板高度或键盘变化。
    ///
    /// **写入一律直接提交，跟随调用方所处的动画上下文**：键盘动画块里调 → 高度与 offset 一起插值，
    /// 和面板 frame、容器位移同一条时间曲线；手势跟手帧没有动画上下文 → 立即生效。这里不剥动画、
    /// 也不引入冻结高度 + 平移之类的中间态：实测那套会和 viewport 的裁切各走一条时间线，反而跳动。
    @discardableResult
    func updateVisibleArea(
        visibleHeight: CGFloat,
        bottomInset: CGFloat,
        syncMode: VisibleAreaSyncMode = .normal
    ) -> Bool {
        let targetVisibleHeight = max(0, visibleHeight)
        let targetBottomInset = max(0, bottomInset)
        let syncPolicy = bottomSyncPolicy(for: syncMode)
        let visibleHeightChanged = abs(
            targetVisibleHeight - (self.visibleHeight ?? -.greatestFiniteMagnitude)
        ) > 0.5
        let bottomInsetChanged = abs(targetBottomInset - appliedBottomInset) > 0.5
        guard visibleHeightChanged || bottomInsetChanged else { return false }

        // 首次分配视口时显示最新消息；其余在修改高度 / inset 前判断是否原本贴底。
        let isInitialViewportAssignment = self.visibleHeight == nil
        let shouldFollowLatestMessage = isInitialViewportAssignment
            || isFollowingBottom(policy: syncPolicy, source: "updateVisibleArea")
        let traceBefore = scrollTrace.capture(tableView)
        defer {
            scrollTrace.record(
                "viewport", on: tableView, before: traceBefore,
                force: isInitialViewportAssignment || bottomInsetChanged,
                details: "height=\(targetVisibleHeight) inset=\(targetBottomInset)"
                    + " initial=\(isInitialViewportAssignment)"
                    + " follow=\(shouldFollowLatestMessage)"
                    + " mode=\(syncMode.label)"
                    + " tolerance=\(syncPolicy.followTolerance)"
            )
        }
        self.visibleHeight = targetVisibleHeight
        appliedBottomInset = targetBottomInset
        if bottomInsetChanged {
            applyInsets()
        }
        if visibleHeightChanged {
            applyTableViewFrame()
        }
        // 视口变矮会把「贴底」的 offset 极限推高，所以必须排在高度写入之后才能算出新的落点；
        // 和高度处在同一个上下文里，动画期间两者同步插值。
        if shouldFollowLatestMessage {
            scrollToBottom(
                animated: false,
                source: "updateVisibleArea",
                syncMode: syncMode
            )
        }
        return true
    }

    /// tableView 高度跟随可见展示区高度；尚未收到展示高度时退化为整块列表区域。
    private func applyTableViewFrame() {
        let height = visibleHeight.map { min(bounds.height, $0) } ?? bounds.height
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        let widthChanged = abs(frame.width - measuredWidth) > 0.5
        var frameChanged = false
        scrollTrace.observe("listFrame", on: tableView, details: "target=\(frame)") {
            frameChanged = tableView.bo_setFrame(frame)
        }
        guard frameChanged, widthChanged else { return }
        // 宽度变了（旋转 / 分屏 / 面板宽度变化）行高要按新宽度重新测：缓存按宽度分桶，
        // 旧宽度那一份留着（转回去还能命中），这里只需要让表格重新取高。
        measuredWidth = frame.width
        guard !messages.isEmpty, frame.width > 0 else { return }
        // 变窄会让正文换行更多、内容变高：已分配高度同样只增不减，这一步以前是靠 getter 的副作用
        // 顺带完成的，现在显式调用。
        reserveLatestReplyHeight()
        scrollTrace.observe("reloadData", on: tableView, details: "widthChanged=true") {
            reloadTableData()
        }
    }

    /// 对齐到包含 adjustedContentInset 的真实底部；容差由普通/跟手同步策略决定。
    ///
    /// 走 `setContentOffset` 而不是 `scrollToRow`：后者要先定位 indexPath、内部自带一套对齐逻辑，
    /// 逐帧跟手时既多算一遍也不好控制落点；直接写 offset 的目标值只由 contentSize / inset / 视口决定。
    ///
    /// 非动画路径会反复对齐到收敛（见 `bottomAlignmentPassLimit`）；动画路径只写一次，
    /// 免得连续写 offset 把在飞的动画打断。
    ///
    /// 行高精确之后正常一趟就到位，多趟只是兜底（比如 cell 内部还有异步内容改变了高度）。
    func scrollToBottom(
        animated: Bool,
        source: String = #function,
        syncMode: VisibleAreaSyncMode = .normal
    ) {
        guard !messages.isEmpty else { return }
        let syncPolicy = bottomSyncPolicy(for: syncMode)
        let traceBefore = scrollTrace.capture(tableView)
        let awayFromBottom = traceBefore.map {
            $0.strictGap > syncPolicy.followTolerance
        } ?? false
        scrollTrace.record("bottom.request", on: tableView, source: source,
                           force: awayFromBottom || animated,
                           details: "animated=\(animated)"
                               + " followTolerance=\(syncPolicy.followTolerance)"
                               + " writeTolerance=\(syncPolicy.writeTolerance)"
                               + " mode=\(syncMode.label)"
                               + " rows=\(messages.count)")
        guard bounds.width > 0,
              bounds.height > 0,
              tableView.bounds.width > 0,
              tableView.bounds.height > 0 else {
            pendingScrollToBottomAnimated = animated
            pendingScrollTraceSource = source
            pendingScrollSyncMode = syncMode
            scrollTrace.record("bottom.deferred", on: tableView, source: source, force: true,
                               details: "animated=\(animated) listBounds=\(bounds)")
            return
        }

        let passLimit = animated ? 1 : syncPolicy.alignmentPassLimit
        for pass in 0..<passLimit {
            // contentSize 要先是最新的（reload 之后没 layout 就读会偏）；没有脏布局时这是 no-op。
            scrollTrace.observe("bottom.layout", on: tableView, source: source, force: awayFromBottom,
                                details: "pass=\(pass + 1)") {
                tableView.layoutIfNeeded()
            }
            let target = CGPoint(x: tableView.contentOffset.x, y: tableView.bo_maximumContentOffsetY)
            // 目标与当前一致就不写：写同一个 offset 会打断在飞的减速动画，逐帧路径上更是白刷布局。
            // 返回 false 表示已经到位，收敛结束。
            var offsetChanged = false
            scrollTrace.observe("bottom.write", on: tableView, source: source, force: awayFromBottom,
                                details: "pass=\(pass + 1) targetY=\(target.y) animated=\(animated) wrote=\(offsetChanged)") {
                offsetChanged = tableView.bo_setContentOffset(
                    target,
                    animated: animated,
                    tolerance: syncPolicy.writeTolerance
                )
            }
            guard offsetChanged else {
                return
            }
        }
    }

    /// 是否处在「跟随最新消息」的位置。
    ///
    /// 使用包含 adjustedContentInset 的最大 offset；内容底边进入可见区不等于列表已经到底。
    private func isFollowingBottom(source: String = #function) -> Bool {
        isFollowingBottom(
            policy: bottomSyncPolicy(for: .normal),
            source: source
        )
    }

    private func isFollowingBottom(
        policy: BottomSyncPolicy,
        source: String = #function
    ) -> Bool {
        guard !messages.isEmpty else { return true }
        let contentBottomVisible = tableView.bo_isContentBottomVisible(
            tolerance: policy.followTolerance
        )
        let result = tableView.bo_isScrolledToBottom(
            tolerance: policy.followTolerance
        )
        scrollTrace.record(
            "follow",
            on: tableView,
            source: source,
            force: contentBottomVisible != result,
            details: "follow=\(result)"
                + " contentVisible=\(contentBottomVisible)"
                + " tolerance=\(policy.followTolerance)"
        )
        return result
    }

    private func bottomSyncPolicy(for mode: VisibleAreaSyncMode) -> BottomSyncPolicy {
        switch mode {
        case .normal:
            let onePixel = onePixelTolerance
            return BottomSyncPolicy(
                followTolerance: onePixel,
                writeTolerance: onePixel,
                alignmentPassLimit: Self.bottomAlignmentPassLimit
            )
        case .tracking:
            return BottomSyncPolicy(
                followTolerance: Self.trackingBottomTolerance,
                writeTolerance: Self.trackingBottomTolerance,
                alignmentPassLimit: 1
            )
        }
    }

    /// UIKit 几何使用 point；一个物理像素必须按当前屏幕 scale 换算。
    private var onePixelTolerance: CGFloat {
        let scale = tableView.window?.screen.scale ?? tableView.traitCollection.displayScale
        return 1 / max(scale, 1)
    }

    /// 某一行当前生效的行高。**纯读**：不推进尾回复的已分配高度。
    ///
    /// 「已分配高度只增不减」是一条**显式命令**（`reserveLatestReplyHeight()`），由内容 / 宽度的
    /// 变更点各调一次；读高度的路径（`heightForRowAt`、刷新前后的取值）一概不写状态。
    /// 曾经把增长写在这个 getter 里，于是「读一次高度」和「把高度抬上去」变成同一个动作：谁先读到
    /// 谁就把增长消耗掉，`refreshRow` 的前后两次取值可能因此相等、按「高度没变」短路掉本该提交的
    /// batch，增长自己把自己取消了。
    private func rowHeight(at row: Int) -> CGFloat {
        guard row >= 0, row < messages.count else { return ChatMessageHeightCache.fallbackHeight }
        let measured = heightCache.height(for: messages[row], width: tableView.bounds.width)
        guard isLatestReservedReply(at: row) else { return measured }
        // 取 max 而不是直接返回已分配值：万一某条路径漏调一次 reserve，这一行也只会多留白，
        // 不会比内容矮 —— 矮了会被 cell 的 `clipsToBounds` 把正文裁掉。
        return max(measured, latestReplyAllocatedHeight)
    }

    /// 这一行是否就是「按已分配高度占位」的当次尾回复。
    private func isLatestReservedReply(at row: Int) -> Bool {
        guard reservesLatestReplyHeight,
              row == messages.count - 1,
              messages.indices.contains(row) else { return false }
        return messages[row].role == .assistant
    }

    /// 让尾回复的已分配高度按台阶追上当前内容高度（只增不减）。
    ///
    /// 只在内容或宽度**刚变过**之后调用：`setMessages` / `append` / `refreshRow` / 宽度重测。
    /// 调完再读行高，拿到的就是这一次该用的值。
    private func reserveLatestReplyHeight() {
        let row = messages.count - 1
        guard isLatestReservedReply(at: row) else { return }
        let measured = heightCache.height(for: messages[row], width: tableView.bounds.width)
        guard measured > latestReplyAllocatedHeight else { return }
        latestReplyHasGrownBeyondInitialHeight = true
        let steps = ceil((measured - latestReplyAllocatedHeight) / Self.latestReplyHeightStep)
        latestReplyAllocatedHeight += steps * Self.latestReplyHeightStep
    }

    /// 没有 session 的 UI 调试也可在重新展示时释放终局留白；运行中不重置。
    func beginNewPresentation() {
        guard reservesLatestReplyHeight, messages.last?.status != .streaming else { return }
        setMessages(messages, forceScrollToBottom: false, preservingReplyHeight: false)
    }

    /// 换轮 / 清空列表 / 重新浏览终局时重置；宽度变化不释放当前轮的已分配高度。
    private func resetLatestReplyHeight() {
        latestReplyAllocatedHeight = latestReplyInitialHeight
        latestReplyHasGrownBeyondInitialHeight = false
        reservesLatestReplyHeight = false
    }

    /// 把尾回复的阅读位置从旧行身份搬到新行身份（乐观占位 → 权威 turnID）。
    private func migrateActivityDetailPosition(to replacement: [ChatMessage]) {
        guard let old = messages.last, let new = replacement.last else { return }
        let oldIdentity = ChatRowIdentity(old)
        let newIdentity = ChatRowIdentity(new)
        guard oldIdentity != newIdentity,
              let position = activityDetailPositions[oldIdentity] else { return }
        activityDetailPositions[newIdentity] = position
    }

    private func isSameLatestReply(in replacement: [ChatMessage]) -> Bool {
        guard let old = messages.last, old.role == .assistant,
              let new = replacement.last, new.role == .assistant else { return false }
        if old.id == new.id { return true }
        if let turnID = old.turnID, turnID == new.turnID,
           let startedAt = old.activity?.startedAt, startedAt == new.activity?.startedAt {
            return true
        }
        // 乐观 user + assistant 尚无权威编号。只衔接同一次刚发送的提问：
        // 文本相同且新记录起点不早于占位；不猜 turnID + 1，也不复用旧历史的高度。
        guard old.turnID == nil, old.status == .streaming, new.turnID != nil,
              let oldStart = old.activity?.startedAt, let newStart = new.activity?.startedAt,
              newStart >= oldStart, messages.count >= 2, replacement.count >= 2 else { return false }
        let oldUser = messages[messages.count - 2]
        let newUser = replacement[replacement.count - 2]
        return oldUser.role == .user && oldUser.turnID == nil
            && newUser.role == .user && newUser.turnID == new.turnID
            && oldUser.text == newUser.text
    }

    private func applyInsets() {
        // 内容多出 contentBottomSpacing：inputBar 高度之上再留一段间距，避免贴底时消息紧挨输入栏。
        // 滚动指示条只覆盖 inputBar 让出的区域，不跟着这段间距一起往上抬。
        let contentBottom = appliedBottomInset + Self.contentBottomSpacing
        scrollTrace.observe("listInsets", on: tableView, force: true, details: "targetBottom=\(contentBottom)") {
            tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: contentBottom, right: 0)
            tableView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: appliedBottomInset, right: 0)
        }
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
        configure(cell, at: indexPath.row)
        cell.onToggleActivity = { [weak self] in
            self?.toggleActivityExpanded(messageID: message.id)
        }
        return cell
    }
}

// MARK: - UITableViewDelegate

extension AppAgentChatMessageListView: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrollTrace.didScroll(scrollView)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollTrace.record("drag.begin", on: scrollView, force: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        scrollTrace.record("drag.end", on: scrollView, force: true, details: "willDecelerate=\(decelerate)")
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollTrace.record("deceleration.end", on: scrollView, force: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollTrace.record("animation.end", on: scrollView, force: true)
    }

    /// 精确行高由 `heightCache` 给出（未命中时用模板 cell 测一次）；流式尾部走台阶高度。
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight(at: indexPath.row)
    }
}

/// 临时真机诊断：只读几何，不触发布局、不改 offset、不记录消息内容。
/// 与列表放在同一个编译单元，避免宿主 Xcode 工程尚未刷新新增 Swift 文件时类型不可见。
@MainActor
final class AppAgentChatScrollTrace {
    struct Snapshot {
        let offset: CGPoint
        let maximumY: CGFloat
        let contentSize: CGSize
        let bounds: CGRect
        let frame: CGRect
        let inset: UIEdgeInsets
        let adjustedInset: UIEdgeInsets
        let presentationBounds: CGRect?
        let tracking: Bool
        let dragging: Bool
        let decelerating: Bool
        let panState: Int

        var strictGap: CGFloat { maximumY - offset.y }
        var contentGap: CGFloat { contentSize.height - offset.y - bounds.height }

        @MainActor
        init(_ scrollView: UIScrollView) {
            offset = scrollView.contentOffset
            maximumY = scrollView.bo_maximumContentOffsetY
            contentSize = scrollView.contentSize
            bounds = scrollView.bounds
            frame = scrollView.frame
            inset = scrollView.contentInset
            adjustedInset = scrollView.adjustedContentInset
            presentationBounds = scrollView.layer.presentation()?.bounds
            tracking = scrollView.isTracking
            dragging = scrollView.isDragging
            decelerating = scrollView.isDecelerating
            panState = scrollView.panGestureRecognizer.state.rawValue
        }

        var description: String {
            "y=\(offset.y) maxY=\(maximumY) strictGap=\(strictGap) contentGap=\(contentGap)"
                + " size=\(contentSize) bounds=\(bounds) frame=\(frame)"
                + " insetTB=\(inset.top),\(inset.bottom) adjustedTB=\(adjustedInset.top),\(adjustedInset.bottom)"
                + " presentationBounds=\(String(describing: presentationBounds))"
                + " tracking=\(tracking) dragging=\(dragging) decel=\(decelerating) pan=\(panState)"
        }
    }

    private let instanceID = String(UUID().uuidString.prefix(8))
    private var sequence = 0
    private var lastEmission: [String: TimeInterval] = [:]
    private var lastScrollSnapshot: Snapshot?
    /// 只标记同步写入期间的回调；异步滚动回调仍如实标为 delegate，不能猜其来源。
    private var operation = "none"
    /// coordinator 以弱引用提供实时外层状态；列表主动滚底也能看到当时的 displayHeight。
    var panelContext: (() -> String)?

    var isEnabled: Bool { Logger.isEnabled && Logger.minimumLevel <= .info }

    func capture(_ scrollView: UIScrollView) -> Snapshot? {
        guard isEnabled else { return nil }
        return Snapshot(scrollView)
    }

    func record(
        _ event: String,
        on scrollView: UIScrollView,
        before: Snapshot? = nil,
        source: String = #function,
        force: Bool = false,
        details: @autoclosure () -> String = ""
    ) {
        guard let after = capture(scrollView) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - (lastEmission[event] ?? -.infinity) >= 0.2 else { return }
        lastEmission[event] = now
        sequence += 1
        Logger.info(
            "ChatScrollTrace",
            "id=\(instanceID) seq=\(sequence) t=\(now) event=\(event) source=\(source) \(details())"
                + (panelContext.map { " outer={\($0())}" } ?? "")
                + (before.map { " before={\($0.description)} dy=\(after.offset.y - $0.offset.y)" } ?? "")
                + " after={\(after.description)}"
        )
    }

    /// 围住本来就会执行的写入/布局；不额外调用任何 UIKit 写入。
    func observe(
        _ event: String,
        on scrollView: UIScrollView,
        source: String = #function,
        force: Bool = false,
        details: @autoclosure () -> String = "",
        action: () -> Void
    ) {
        guard isEnabled else {
            action()
            return
        }
        let before = capture(scrollView)
        let previousOperation = operation
        operation = "\(event):\(source)"
        action()
        operation = previousOperation
        let offsetChanged = before.map {
            abs(scrollView.contentOffset.y - $0.offset.y) > 0.0001
        } ?? false
        record(
            event,
            on: scrollView,
            before: before,
            source: source,
            force: force || offsetChanged,
            details: details()
        )
    }

    func didScroll(_ scrollView: UIScrollView) {
        guard let current = capture(scrollView) else { return }
        let previous = lastScrollSnapshot
        lastScrollSnapshot = current
        // 捕获一帧突然归零，包括没有经过 AppAgent 主动写入的 UIKit / 外部 offset 变化。
        let arrivedAtBottom = previous.map {
            $0.strictGap > 1
                && current.strictGap <= 0.5
                && abs(current.offset.y - $0.offset.y) > 1
        } ?? false
        // 大位移即使没落在底部也保留，避免「跳过去又跳回来」被整个采样窗口吞掉。
        // 快速手势也可能命中；这只是记录条件，不代表认定发生了 bug。
        let largeDelta = previous.map {
            abs(current.offset.y - $0.offset.y) >= 8
        } ?? false
        record(
            "didScroll",
            on: scrollView,
            before: previous,
            source: operation,
            force: arrivedAtBottom || largeDelta,
            details: "arrivedAtBottom=\(arrivedAtBottom) largeDelta=\(largeDelta)"
        )
    }
}

#endif
