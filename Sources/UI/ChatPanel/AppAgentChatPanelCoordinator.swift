//
//  AppAgentChatPanelCoordinator.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BODragScroll
import BOUIKit
import UIKit

/// ChatPanel 与 BODragScroll 之间的唯一适配层。
///
/// 该对象拥有拖拽容器和固定尺寸面板，负责尺寸提供、detent、内部列表捕获、程序化移动以及
/// displayHeight 驱动的列表可见区同步。业务消息和 inputBar/键盘策略仍由 AppAgentViewController 管理。
@MainActor
final class AppAgentChatPanelCoordinator: NSObject {

    /// 铺满 AppAgentViewController、并由 BODragScroll 自己管理可见 panel 命中的拖拽容器。
    let dragScrollView = BODragScrollView(frame: .zero)

    /// 由 BODragScroll 固定尺寸承载的业务内容视图。
    let panelView = AppAgentChatPanelView()

    /// 当前 displayHeight 映射出的业务档位，用于尺寸变化时保持语义位置。
    private var displayDetent: AppAgentChatPanelDetent = .half

    private var geometry: AppAgentChatPanelGeometry?
    private var pendingLayoutDetent: AppAgentChatPanelDetent?
    private var wasFullyCollapsed = false
    private var automaticRevealID: UUID?

    /// 真正收至 peek 后再次展开才开始新的浏览；half/full 切换与逐帧布局不触发。
    var onWillRevealMessages: (() -> Void)?

    override init() {
        super.init()

        panelView.listView.scrollTrace.panelContext = { [weak self] in
            guard let self else { return "released" }
            let drag = self.dragScrollView
            return "displayHeight=\(drag.displayHeight) y=\(drag.contentOffset.y)"
                + " pan=\(drag.panGestureRecognizer.state.rawValue)"
                + " translationY=\(drag.panGestureRecognizer.translation(in: drag).y)"
                + " dragging=\(drag.isDragging) decel=\(drag.isDecelerating)"
                + " panelFrame=\(self.panelView.frame)"
        }
        dragScrollView.backgroundColor = .clear
        // 内容区背景的阴影会超出 panel bounds，因此 DragScroll 不裁掉它。
        dragScrollView.clipsToBounds = false
        dragScrollView.behaviorProvider = self
        dragScrollView.eventDelegate = self

        // 拖动面板不联动收键盘（BODragScrollView 也是 UIScrollView，默认 .none，这里显式声明意图）。
        dragScrollView.keyboardDismissMode = .none

        var configuration = dragScrollView.configuration
        // 内部优先：手指落在消息列表里就由列表自己滚，面板不参与联动；面板只由拖拽条、顶部栏
        // 和程序化移动驱动。列表的 contentOffset 因此永远归宿主，不存在组合轴投影。
        configuration.handoff.mode = .innerFirst
        // 卡片本身不做橡皮筋：上下越界都交给内部列表自己回弹。
        configuration.bounce.allowsPanelTopBounce = false
        configuration.bounce.allowsPanelBottomBounce = false
        configuration.bounce.preferredTopOwner = .innerScrollView
        configuration.bounce.preferredBottomOwner = .innerScrollView
        dragScrollView.configuration = configuration
    }

    /// 根据 ViewController 最新环境更新 host、固定面板尺寸和 detent。
    ///
    /// 键盘不参与：键盘只让宿主把整个 ChatPanel 容器上移，面板几何与展示高度全程不变。
    ///
    /// **不在这里写 `dragScrollView.frame`**：画布 frame 的唯一 writer 是
    /// `AppAgentChatPanelContainerView`（目标值见 `AppAgentChatPanelContainerLayout.dragScrollFrame`）。
    /// 调用方 `applyChatPanelContainerLayout` 在本方法之后紧接着提交容器布局，尺寸由那一次写入给出。
    func updateLayout(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets
    ) {
        guard let newGeometry = AppAgentChatPanelGeometry(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        ) else { return }

        guard geometry != newGeometry else {
            applyDisplayHeightState(dragScrollView.displayHeight)
            return
        }

        let isFirstGeometry = geometry == nil
        geometry = newGeometry
        updateLatestReplyInitialHeight(for: newGeometry)
        if isFirstGeometry {
            // 首次布局前若业务已经调用 move(to:)，保留该请求；否则默认停在 half。
            pendingLayoutDetent = pendingLayoutDetent ?? displayDetent
        }
        // 后续旋转/分屏不写 pending detent；provider 保留 BODragScroll 提供的实时高度，
        // 避免把进行中的拖拽或动画量化到最近档位。
        dragScrollView.minimumDisplayHeight = newGeometry.peekHeight
        dragScrollView.detentHeights = newGeometry.detentHeights

        if dragScrollView.panelView == nil {
            // provider、configuration 和 detent 必须先就绪，最后赋 panelView 才能得到正确首次布局。
            dragScrollView.panelView = panelView
        } else {
            dragScrollView.invalidatePanelLayout()
        }

        dragScrollView.setNeedsLayout()
        dragScrollView.layoutIfNeeded()
        applyDisplayHeightState(dragScrollView.displayHeight)
    }

    /// 由业务主动移动到指定档位；运动细节和中途打断全部交给 BODragScroll。
    func move(
        to detent: AppAgentChatPanelDetent,
        animated: Bool,
        preservingReplyHeight: Bool = false,
        source: String = #function
    ) {
        // 新消息自动展开不是重新浏览；标记跨越滚动动画，直到第一帧真正离开 peek。
        let revealID = preservingReplyHeight && detent != .peek ? UUID() : nil
        automaticRevealID = revealID
        panelView.listView.scrollTrace.record("outer.move", on: dragScrollView, source: source, force: true,
                                             details: "detent=\(detent) animated=\(animated) pending=\(geometry == nil)")
        guard let geometry else {
            displayDetent = detent
            pendingLayoutDetent = detent
            return
        }

        dragScrollView.scroll(
            toDisplayHeight: geometry.height(for: detent),
            animated: animated
        ) { [weak self] _ in
            // 首帧前取消 / 中断也要结束本次豁免，不能影响之后的用户重开。
            // 新请求可能同步中断旧请求，旧 completion 只能清理自己的标记。
            guard let self, let revealID, self.automaticRevealID == revealID else { return }
            self.automaticRevealID = nil
        }
    }

    /// 当前 displayHeight 是否处在 peek 附近，供新消息到达时决定是否自动展开。
    var isAtPeekDetent: Bool {
        guard let geometry else { return displayDetent == .peek }
        guard dragScrollView.displayHeight > 0 else { return displayDetent == .peek }
        return geometry.nearestDetent(
            to: dragScrollView.displayHeight,
            preferredDetent: displayDetent
        ) == .peek
    }

    /// 所有面板派生 UI 都只消费 displayHeight；不等待 movement completion 或 idle 回调。
    private func applyDisplayHeightState(
        _ displayHeight: CGFloat,
        syncMode: AppAgentChatMessageListView.VisibleAreaSyncMode = .normal,
        source: String = #function
    ) {
        guard let geometry, displayHeight > 0 else { return }

        let isFullyCollapsed = displayHeight <= geometry.peekHeight + 0.5
        let isRevealing = wasFullyCollapsed && !isFullyCollapsed
        wasFullyCollapsed = isFullyCollapsed
        if isRevealing {
            let preservesHeight = automaticRevealID != nil && !dragScrollView.isDragging
            automaticRevealID = nil
            if !preservesHeight { onWillRevealMessages?() }
        }
        if !isFullyCollapsed { automaticRevealID = nil }

        let trace = panelView.listView.scrollTrace
        let listScrollView = panelView.listView.participantScrollView
        trace.record(
            "display.begin",
            on: listScrollView,
            source: source,
            force: syncMode == .tracking,
            details: "displayHeight=\(displayHeight) syncMode=\(syncMode.label)"
        )
        trace.observe("panel.presentation", on: listScrollView, source: source,
                      force: syncMode == .tracking,
                      details: "displayHeight=\(displayHeight)") {
            updatePanelPresentation(at: displayHeight)
        }

        let clampedDisplayHeight = geometry.clampedDisplayHeight(displayHeight)
        displayDetent = geometry.nearestDetent(
            to: clampedDisplayHeight,
            preferredDetent: displayDetent
        )
        let fixedTopAreaHeight = AppAgentChatPanelGeometry.dragHandleAreaHeight
            + AppAgentChatPanelMetrics.navigationBarHeight
        // 列表视口跟随实时展示高度；但下限保持 half 档的可视高度，继续收向 peek 时只做视觉裁切，
        // 不再压缩列表视口（否则 peek 附近视口只剩几十 pt，滚动指标会被反复重算）。
        let viewportReferenceDisplayHeight = max(clampedDisplayHeight, geometry.halfHeight)
        let visibleListHeight = max(0, viewportReferenceDisplayHeight - fixedTopAreaHeight)
        // 内部优先下列表从不进联动，contentOffset 的写权始终在宿主：视口高度变化只做「原来贴底的
        // 继续贴底」，不对内容做额外 offset 校正。
        if panelView.listView.updateVisibleArea(
            visibleHeight: visibleListHeight,
            // 固定值：只随安全区/bar 高度变化的几何量，键盘和面板高度都不参与。
            bottomInset: geometry.listBottomInset,
            syncMode: syncMode
        ) {
            trace.observe("metrics.list", on: listScrollView, source: source,
                          force: syncMode == .tracking) {
                trace.observe("metrics.outer", on: dragScrollView, source: source,
                              force: syncMode == .tracking) {
                    dragScrollView.reloadScrollMetrics()
                }
            }
        }
    }

    /// 新一轮回复的留白基准固定按 half 计算，而不是随着用户把面板拖到 full
    /// 又重新分配；这样首条消息在 displayHeight 首次发布前到达时也不会落回 400pt。
    private func updateLatestReplyInitialHeight(
        for geometry: AppAgentChatPanelGeometry
    ) {
        let fixedTopAreaHeight = AppAgentChatPanelGeometry.dragHandleAreaHeight
            + AppAgentChatPanelMetrics.navigationBarHeight
        panelView.listView.updateLatestReplyInitialHeight(
            halfScreenVisibleHeight: max(0, geometry.halfHeight - fixedTopAreaHeight),
            bottomInset: geometry.listBottomInset
        )
    }

    /// 【竖向收起接线点】把 BODragScroll 的实时展示高度交给 panel 内部，只更新背景和 viewport 的裁切几何。
    private func updatePanelPresentation(at displayHeight: CGFloat) {
        guard let geometry, displayHeight > 0 else { return }
        panelView.updateDisplayHeight(
            displayHeight,
            minimumDisplayHeight: geometry.peekHeight,
            compactTransitionStartDisplayHeight: geometry.halfHeight
        )
    }
}

// MARK: - BODragScrollBehaviorProvider

extension AppAgentChatPanelCoordinator: BODragScrollBehaviorProvider {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        sizeFor panelView: UIView,
        firstLayout: Bool,
        proposedDisplayHeight: inout CGFloat
    ) -> CGSize? {
        guard panelView === self.panelView, let geometry else { return nil }

        if let pendingLayoutDetent {
            proposedDisplayHeight = geometry.height(for: pendingLayoutDetent)
            self.pendingLayoutDetent = nil
        } else if firstLayout {
            proposedDisplayHeight = geometry.halfHeight
        } else {
            proposedDisplayHeight = geometry.clampedDisplayHeight(proposedDisplayHeight)
        }
        return geometry.panelSize
    }
}

// MARK: - BODragScrollEventDelegate

extension AppAgentChatPanelCoordinator: BODragScrollEventDelegate {
    func dragScrollView(
        _ dragScrollView: BODragScrollView,
        didChangeDisplayHeight displayHeight: CGFloat
    ) {
        // 【竖向收起每帧入口】手势拖动、减速或程序化移动改变展示高度时，BODragScroll 都从这里回调。
        applyDisplayHeightState(displayHeight, syncMode: .tracking)
    }
}

#endif
