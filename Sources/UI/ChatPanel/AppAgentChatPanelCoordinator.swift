//
//  AppAgentChatPanelCoordinator.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BODragScroll
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
    private var bottomAvoidingInset: CGFloat = 0

    override init() {
        super.init()

        dragScrollView.backgroundColor = .clear
        // 内容区背景的阴影会超出 panel bounds，因此 DragScroll 不裁掉它。
        dragScrollView.clipsToBounds = false
        dragScrollView.behaviorProvider = self
        dragScrollView.eventDelegate = self

        // 拖动面板不联动收键盘（BODragScrollView 也是 UIScrollView，默认 .none，这里显式声明意图）。
        dragScrollView.keyboardDismissMode = .none

        var configuration = dragScrollView.configuration
        // 面板位移与内部 offset 合并成一条组合滚动轴；内部滚动区间从手指按下的位置起算。
        configuration.handoff.mode = .coordinated
        configuration.handoff.innerScrollPlacement = .fromTouchedPosition
        // 顶部橡皮筋归外层卡片；底部不让 panel 继续外拉，交给内部列表自己回弹。
        configuration.bounce.allowsPanelTopBounce = true
        configuration.bounce.allowsPanelBottomBounce = false
        configuration.bounce.preferredTopOwner = .panel
        configuration.bounce.preferredBottomOwner = .innerScrollView
        dragScrollView.configuration = configuration
    }

    /// 根据 ViewController 最新环境更新 host、固定面板尺寸和 detent。
    func updateLayout(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        inputBarExpandedFrame: CGRect,
        bottomAvoidingInset: CGFloat
    ) {
        self.bottomAvoidingInset = max(0, bottomAvoidingInset)
        dragScrollView.frame = CGRect(origin: .zero, size: bounds.size)

        guard let newGeometry = AppAgentChatPanelGeometry(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame
        ) else { return }

        guard geometry != newGeometry else {
            applyDisplayHeightState(dragScrollView.displayHeight)
            return
        }

        let isFirstGeometry = geometry == nil
        geometry = newGeometry
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

    /// 更新悬浮 inputBar、safe area 或键盘占用的底部空间。
    func updateBottomAvoidingInset(_ inset: CGFloat) {
        let normalizedInset = max(0, inset)
        guard abs(normalizedInset - bottomAvoidingInset) > 0.5 else { return }
        bottomAvoidingInset = normalizedInset
        applyDisplayHeightState(dragScrollView.displayHeight)
    }

    /// 由业务主动移动到指定档位；运动细节和中途打断全部交给 BODragScroll。
    func move(to detent: AppAgentChatPanelDetent, animated: Bool) {
        guard let geometry else {
            displayDetent = detent
            pendingLayoutDetent = detent
            return
        }

        dragScrollView.scroll(
            toDisplayHeight: geometry.height(for: detent),
            animated: animated
        )
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
    private func applyDisplayHeightState(_ displayHeight: CGFloat) {
        guard let geometry, displayHeight > 0 else { return }

        updatePanelPresentation(at: displayHeight)

        let clampedDisplayHeight = geometry.clampedDisplayHeight(displayHeight)
        displayDetent = geometry.nearestDetent(
            to: clampedDisplayHeight,
            preferredDetent: displayDetent
        )
        let fixedTopAreaHeight = AppAgentChatPanelGeometry.dragHandleAreaHeight
            + AppAgentChatPanelNavigationBar.height
        // 列表视口跟随实时展示高度；但下限保持 half 档的可视高度，继续收向 peek 时只做视觉裁切，
        // 不再压缩列表视口（否则 peek 附近视口只剩几十 pt，滚动指标会被反复重算）。
        let viewportReferenceDisplayHeight = max(clampedDisplayHeight, geometry.halfHeight)
        let visibleListHeight = max(0, viewportReferenceDisplayHeight - fixedTopAreaHeight)
        let metricsChanged = panelView.listView.updateVisibleArea(
            visibleHeight: visibleListHeight,
            bottomAvoidingInset: bottomAvoidingInset
        )
        if metricsChanged {
            dragScrollView.reloadScrollMetrics()
        }
#if DEBUG
        logJitterFrame(
            displayHeight: displayHeight,
            visibleListHeight: visibleListHeight,
            metricsChanged: metricsChanged
        )
#endif
    }

#if DEBUG
    /// 临时排查用（不要提交）：抖动定位期间每帧打印面板与内部列表的关键数字。
    /// 关掉就把 `isJitterLoggingEnabled` 置为 false。
    static var isJitterLoggingEnabled = true

    private func logJitterFrame(
        displayHeight: CGFloat,
        visibleListHeight: CGFloat,
        metricsChanged: Bool
    ) {
        guard Self.isJitterLoggingEnabled else { return }
        let inner = panelView.listView.participantScrollView
        func number(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        print(
            "[APPAGENT \(String(format: "%.3f", CACurrentMediaTime()))] displayHeightFrame"
                + " display=\(number(displayHeight))"
                + " visibleList=\(number(visibleListHeight))"
                + " metricsChanged=\(metricsChanged)"
                + " innerBounds=\(number(inner.bounds.height))"
                + " innerSize=\(number(inner.contentSize.height))"
                + " innerOff=\(number(inner.contentOffset.y))"
                + " innerInsetB=\(number(inner.adjustedContentInset.bottom))"
                + " hostOff=\(number(dragScrollView.contentOffset.y))"
                + " hostDrag=\(dragScrollView.isDragging ? 1 : 0)"
                + " hostDec=\(dragScrollView.isDecelerating ? 1 : 0)"
                + " innerDrag=\(inner.isDragging ? 1 : 0)"
                + " innerDec=\(inner.isDecelerating ? 1 : 0)"
        )
    }
#endif

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
        applyDisplayHeightState(displayHeight)
    }
}

#endif
