//
//  AppAgentViewController+InputBarLayout.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Input Bar Layout（接线层）
//
// frame 的纯计算与落位策略在 AppAgentInputBarFramePolicy，持久化在 AppAgentInputBarLayoutStoring；
// 这里只保留状态（拖拽标志、宽度停留计时、已存偏好）与视图应用。

/// 一次展开态 resize 手势的阻尼坐标映射状态。
/// 视觉 frame 可以越过左边界少量拉伸，raw frame 始终保留手指未经阻尼的真实宽度变化。
struct AppAgentExpandedInputBarResizeTracking {
    let displayedAnchorFrame: CGRect
    let rawAnchorFrame: CGRect
    var latestRawFrame: CGRect

    init(displayedAnchorFrame: CGRect, rawAnchorFrame: CGRect) {
        self.displayedAnchorFrame = displayedAnchorFrame
        self.rawAnchorFrame = rawAnchorFrame
        latestRawFrame = rawAnchorFrame
    }

    /// 将 inputBar 基于视觉锚点提出的 resize frame，转换为同一手势下连续的阻尼前 frame。
    mutating func rawFrame(for displayedProposal: CGRect) -> CGRect {
        let rightEdge = rawAnchorFrame.maxX
            + displayedProposal.maxX
            - displayedAnchorFrame.maxX
        let width = max(
            AppAgentInputBar.collapsedMinWidth,
            rawAnchorFrame.width
                + displayedProposal.width
                - displayedAnchorFrame.width
        )
        latestRawFrame = CGRect(
            x: rightEdge - width,
            y: displayedProposal.minY,
            width: width,
            height: AppAgentInputBar.barHeight
        )
        return latestRawFrame
    }
}

/// 一次收起态 move 手势的阻尼坐标映射状态。
/// `displayedAnchorFrame` 对应手势起点的屏幕位置，`rawAnchorFrame` 对应同一点在阻尼前的逻辑位置。
struct AppAgentCollapsedInputBarMoveTracking {
    let displayedAnchorFrame: CGRect
    let rawAnchorFrame: CGRect
    var latestRawFrame: CGRect

    init(displayedAnchorFrame: CGRect, rawAnchorFrame: CGRect) {
        self.displayedAnchorFrame = displayedAnchorFrame
        self.rawAnchorFrame = rawAnchorFrame
        latestRawFrame = rawAnchorFrame
    }

    /// 将 inputBar 基于视觉锚点提出的 frame，转换为同一手势下连续的阻尼前逻辑 frame。
    mutating func rawFrame(for displayedProposal: CGRect) -> CGRect {
        latestRawFrame = rawAnchorFrame.offsetBy(
            dx: displayedProposal.minX - displayedAnchorFrame.minX,
            dy: displayedProposal.minY - displayedAnchorFrame.minY
        )
        return latestRawFrame
    }
}

extension AppAgentViewController {

    /// 当前布局决策的环境快照。
    var inputBarLayoutContext: AppAgentInputBarFramePolicy.Context {
        AppAgentInputBarFramePolicy.Context(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            keyboardHeight: effectiveKeyboardHeight,
            storedExpandedWidth: storedExpandedInputBarWidth,
            storedCollapsedPlacement: storedCollapsedInputBarPlacement
        )
    }

    var inputBarContainerAvailableFrame: CGRect {
        AppAgentInputBarFramePolicy.availableFrame(in: inputBarLayoutContext, avoidingKeyboard: false)
    }

    func isWideInputBarLayout() -> Bool {
        AppAgentInputBarFramePolicy.isWideLayout(inputBarLayoutContext)
    }

    // MARK: 布局分发

    /// 每次布局变化（首次上屏、旋转、键盘、拖拽中容器重排）都从这里统一算出 inputBar 该待在哪。
    /// 优先级从上到下：首帧 → 正在拖拽（跟手，不能被策略值拽回去）→ 静止时按收起/展开取偏好位置。
    func layoutInputBar(reason: AppAgentInputBarFrameChangeReason) {
        // 容器还没有有效尺寸（view 尚未布局完），算出来的 frame 没有意义，直接跳过等下一次。
        guard inputBarContainerAvailableFrame.width > 0, inputBarContainerAvailableFrame.height > 0 else {
            return
        }

        // context = 这一刻的环境快照：bounds、safeArea、键盘高度、已持久化的宽度/贴边位置。
        let context = inputBarLayoutContext
        let targetFrame: CGRect
        if !hasLaidOutInputBar {
            // 第一次布局：没有任何历史状态，一律以展开态首帧落位（之后置位，不再走这支）。
            targetFrame = AppAgentInputBarFramePolicy.preferredExpandedFrame(context)
            hasLaidOutInputBar = true
        } else if isDraggingExpandedInputBar {
            // 展开态正在被左右拖拽改宽度：用「最近一次手指原始位置」重算约束后的 frame，
            // 而不是回到偏好位置，否则拖拽中途来一次布局就会把手里的 bar 弹回去。
            targetFrame = currentConstrainedExpandedInputBarFrame(context: context)
        } else if isDraggingCollapsedInputBar {
            // 收起态（小圆胶囊）正在被拖着移动：同理用最近一次原始位置重算橡皮筋效果，
            // 保证越界回弹的阻尼不会被重复施加。
            targetFrame = currentRubberBandedCollapsedInputBarFrame(context: context)
        } else if inputBar.isCollapsed {
            // 静止 + 收起态：回到策略算出的收起位置（含上次保存的贴边落点）。
            targetFrame = AppAgentInputBarFramePolicy.preferredCollapsedFrame(context)
        } else {
            // 静止 + 展开态：回到策略算出的展开位置（含上次保存的宽度、避让键盘）。
            targetFrame = AppAgentInputBarFramePolicy.preferredExpandedFrame(context)
        }
        // 布局分发不做动画：动画只属于「抬手落位」那条路径（expand/collapse/松手结算）。
        applyInputBarFrame(targetFrame, animation: .immediate, reason: reason)
    }

    func applyInputBarFrame(
        _ targetFrame: CGRect,
        animation: AppAgentInputBarFrameAnimation,
        reason: AppAgentInputBarFrameChangeReason
    ) {
        let oldFrame = inputBar.frame
        let didChange = didInputBarFrameChange(from: oldFrame, to: targetFrame)
        if didChange {
            inputBar.setInputBarFrame(targetFrame, animation: animation)
        }
        // inputBar 手势 changed 使用 `.immediate`，ChatPanel frame 与 alpha 会随每个 frame 直接更新；
        // 抬手落位使用动画类型，由 ChatPanelContainerView 分别处理 frame 动画和 easeOut alpha 动画。
        applyChatPanelContainerLayout(
            inputBarFrame: inputBar.frame,
            inputBarExpandedFrame: AppAgentInputBarFramePolicy.preferredExpandedFrame(inputBarLayoutContext),
            animation: animation
        )
        guard didChange else { return }
        notifyInputBarFrameChangeIfNeeded(
            oldFrame: oldFrame,
            newFrame: inputBar.frame,
            animated: animation.isAnimated,
            reason: reason
        )
    }

    func notifyInputBarFrameChangeIfNeeded(
        oldFrame: CGRect,
        newFrame: CGRect,
        animated: Bool,
        reason: AppAgentInputBarFrameChangeReason
    ) {
        guard didInputBarFrameChange(from: oldFrame, to: newFrame) else { return }
        let context = AppAgentInputBarFrameChangeContext(
            reason: reason,
            oldFrame: oldFrame,
            newFrame: newFrame,
            animated: animated
        )
        onInputBarFrameChange?(context)
        inputBarFrameDidChange(context)
    }

    func didInputBarFrameChange(from oldFrame: CGRect, to newFrame: CGRect) -> Bool {
        !oldFrame.isApproximatelyEqual(to: newFrame)
    }

    func expandInputBar(animated: Bool) {
        expandInputBar(animation: animated ? .standard : .immediate)
    }

    func expandInputBar(animation: AppAgentInputBarFrameAnimation) {
        isDraggingExpandedInputBar = false
        isDraggingCollapsedInputBar = false
        resetExpandedResizeInteractionTracking()
        resetCollapsedMoveTracking()
        resetExpandedResizeWidthHoldTracking()
        applyInputBarFrame(
            AppAgentInputBarFramePolicy.preferredExpandedFrame(inputBarLayoutContext),
            animation: animation,
            reason: .expand
        )
    }

    func collapseInputBar(animated: Bool) {
        isDraggingExpandedInputBar = false
        isDraggingCollapsedInputBar = false
        resetExpandedResizeInteractionTracking()
        resetCollapsedMoveTracking()
        resetExpandedResizeWidthHoldTracking()
        applyInputBarFrame(
            AppAgentInputBarFramePolicy.preferredCollapsedFrame(inputBarLayoutContext),
            animation: animated ? .standard : .immediate,
            reason: .collapse
        )
    }

    // MARK: 拖拽约束（inputBar delegate 拖拽期间调用）

    func constrainedExpandedInputBarFrame(_ proposedFrame: CGRect) -> CGRect {
        let context = inputBarLayoutContext
        guard !Self.allowsExpandedResizeWidthCustomization else {
            return AppAgentInputBarFramePolicy.constrainedExpandedResizeFrame(
                proposedFrame,
                allowsWidthCustomization: true,
                context: context
            )
        }

        var tracking = expandedResizeTracking ?? AppAgentExpandedInputBarResizeTracking(
            displayedAnchorFrame: inputBar.frame,
            rawAnchorFrame: AppAgentInputBarFramePolicy.rawExpandedResizeFrame(
                from: inputBar.frame,
                context: context
            )
        )
        let rawFrame = tracking.rawFrame(for: proposedFrame)
        expandedResizeTracking = tracking
        return AppAgentInputBarFramePolicy.constrainedExpandedResizeFrame(
            rawFrame,
            allowsWidthCustomization: false,
            context: context
        )
    }

    /// 拖拽期间发生容器布局时，继续用最近一次 raw frame 计算展开态橡皮筋，避免重复施加阻尼。
    func currentConstrainedExpandedInputBarFrame(
        context: AppAgentInputBarFramePolicy.Context
    ) -> CGRect {
        guard !Self.allowsExpandedResizeWidthCustomization,
              let rawFrame = expandedResizeTracking?.latestRawFrame else {
            return AppAgentInputBarFramePolicy.constrainedExpandedResizeFrame(
                inputBar.frame,
                allowsWidthCustomization: Self.allowsExpandedResizeWidthCustomization,
                context: context
            )
        }
        return AppAgentInputBarFramePolicy.constrainedExpandedResizeFrame(
            rawFrame,
            allowsWidthCustomization: false,
            context: context
        )
    }

    func resetExpandedResizeInteractionTracking() {
        expandedResizeTracking = nil
        expandedResizeWouldCollapseAtZeroVelocity = nil
    }

    func constrainedCollapsedInputBarFrame(_ proposedFrame: CGRect) -> CGRect {
        AppAgentInputBarFramePolicy.constrainedCollapsedFrame(proposedFrame, context: inputBarLayoutContext)
    }

    func rubberBandedCollapsedInputBarFrame(_ proposedFrame: CGRect) -> CGRect {
        let context = inputBarLayoutContext
        var tracking = collapsedMoveTracking ?? AppAgentCollapsedInputBarMoveTracking(
            displayedAnchorFrame: inputBar.frame,
            rawAnchorFrame: AppAgentInputBarFramePolicy.rawCollapsedMoveFrame(
                from: inputBar.frame,
                context: context
            )
        )
        let rawFrame = tracking.rawFrame(for: proposedFrame)
        collapsedMoveTracking = tracking
        return AppAgentInputBarFramePolicy.rubberBandedCollapsedMoveFrame(
            rawFrame,
            context: context
        )
    }

    /// 拖拽期间发生容器布局时，继续用最近一次逻辑 frame 计算橡皮筋效果，避免对视觉 frame 重复施加阻尼。
    func currentRubberBandedCollapsedInputBarFrame(
        context: AppAgentInputBarFramePolicy.Context
    ) -> CGRect {
        guard let rawFrame = collapsedMoveTracking?.latestRawFrame else {
            return inputBar.frame
        }
        return AppAgentInputBarFramePolicy.rubberBandedCollapsedMoveFrame(
            rawFrame,
            context: context
        )
    }

    func resetCollapsedMoveTracking() {
        collapsedMoveTracking = nil
    }

    // MARK: 展开 resize 状态分界反馈

    /// 第一次收到 resize frame 提案时，以拖拽前 frame 建立零速抬手结果并预热触觉反馈。
    func beginExpandedResizeDecisionTrackingIfNeeded(initialFrame: CGRect) {
        guard expandedResizeWouldCollapseAtZeroVelocity == nil else { return }
        expandedResizeWouldCollapseAtZeroVelocity = wouldCollapseExpandedResizeAtZeroVelocity(
            frame: initialFrame
        )
        expandedResizeDecisionHapticGenerator.prepare()
    }

    /// frame 跟手更新后重新计算零速抬手结果；只有展开/收起结果发生翻转时才震动一次。
    func updateExpandedResizeDecisionHapticIfNeeded(frame: CGRect) {
        guard let previousResult = expandedResizeWouldCollapseAtZeroVelocity else { return }
        let nextResult = wouldCollapseExpandedResizeAtZeroVelocity(frame: frame)
        guard nextResult != previousResult else { return }

        expandedResizeWouldCollapseAtZeroVelocity = nextResult
        expandedResizeDecisionHapticGenerator.prepare()
        expandedResizeDecisionHapticGenerator.impactOccurred(intensity: 1)
        expandedResizeDecisionHapticGenerator.prepare()
    }

    /// 与真正松手结算共用同一策略，仅把速度固定为零，避免触觉阈值与最终状态阈值不一致。
    func wouldCollapseExpandedResizeAtZeroVelocity(frame: CGRect) -> Bool {
        let context = inputBarLayoutContext
        let strictFrame = AppAgentInputBarFramePolicy.strictlyConstrainedExpandedResizeFrame(
            frame,
            allowsWidthCustomization: Self.allowsExpandedResizeWidthCustomization,
            context: context
        )
        return AppAgentInputBarFramePolicy.shouldCollapseExpanded(
            velocityX: 0,
            frame: strictFrame,
            context: context
        )
    }

    /// 创建 resize 分界反馈发生器；新系统绑定当前 view，旧系统使用兼容初始化方式。
    func makeExpandedResizeDecisionHapticGenerator() -> UIImpactFeedbackGenerator {
        if #available(iOS 17.5, *) {
            return UIImpactFeedbackGenerator(style: .light, view: view)
        }
        return UIImpactFeedbackGenerator(style: .light)
    }

    // MARK: 松手结算

    func finishExpandedInputBarResize(velocity: CGPoint, frame: CGRect) {
        let context = inputBarLayoutContext
        let wasOverdragged = !Self.allowsExpandedResizeWidthCustomization
            && AppAgentInputBarFramePolicy.isExpandedResizeOverdragged(frame, context: context)
        let currentFrame = AppAgentInputBarFramePolicy.strictlyConstrainedExpandedResizeFrame(
            frame,
            allowsWidthCustomization: Self.allowsExpandedResizeWidthCustomization,
            context: context
        )
        let speed = abs(velocity.x)

        if currentFrame.width < AppAgentInputBar.minimumExpandedWidth {
            collapseInputBar(animated: true)
            return
        }

        if Self.allowsExpandedResizeWidthCustomization,
           speed <= AppAgentInputBarFramePolicy.slowVelocityThreshold,
           didHoldExpandedResizeWidth(width: currentFrame.width),
           let storedWidth = AppAgentInputBarFramePolicy.storableExpandedWidth(currentFrame.width, context: context) {
            persistExpandedInputBarWidth(storedWidth)
            expandInputBar(animated: true)
            return
        }

        if AppAgentInputBarFramePolicy.shouldCollapseExpanded(velocityX: velocity.x, frame: currentFrame, context: context) {
            collapseInputBar(animated: true)
        } else {
            expandInputBar(animation: wasOverdragged ? .boundaryRebound : .standard)
        }
    }

    func finishCollapsedInputBarMove(_ context: AppAgentInputBarFramePanEndContext) {
        let layoutContext = inputBarLayoutContext
        let currentFrame = AppAgentInputBarFramePolicy.constrainedCollapsedFrame(
            context.frame,
            context: layoutContext
        )
        let wasOutsideLegalRange = !context.frame.isApproximatelyEqual(to: currentFrame)
        let targetFrame = context.didHoldNearFinalPosition
            ? currentFrame
            : AppAgentInputBarFramePolicy.collapsedSnapFrame(
                velocity: context.velocity,
                frame: currentFrame,
                context: layoutContext
            )
        let animation: AppAgentInputBarFrameAnimation
        if wasOutsideLegalRange {
            animation = .boundaryRebound
        } else {
            animation = context.didHoldNearFinalPosition ? .immediate : .standard
        }
        persistCollapsedInputBarPlacement(for: targetFrame)
        isDraggingExpandedInputBar = false
        isDraggingCollapsedInputBar = false
        resetCollapsedMoveTracking()
        applyInputBarFrame(
            targetFrame,
            animation: animation,
            reason: .collapsedMoveResolution
        )
    }

    // MARK: 展开宽度停留跟踪（时间状态在 VC）

    func updateExpandedResizeWidthHoldTracking(width: CGFloat) {
        guard Self.allowsExpandedResizeWidthCustomization else { return }

        guard isWideInputBarLayout(),
              width >= AppAgentInputBar.minimumExpandedWidth else {
            resetExpandedResizeWidthHoldTracking()
            return
        }

        guard let stableWidth = expandedResizeStableWidth,
              abs(width - stableWidth) <= Self.expandedResizeWidthStabilityThreshold else {
            expandedResizeStableWidth = width
            expandedResizeStableStartTime = Date.timeIntervalSinceReferenceDate
            return
        }
    }

    func didHoldExpandedResizeWidth(width: CGFloat) -> Bool {
        guard Self.allowsExpandedResizeWidthCustomization,
              isWideInputBarLayout(),
              width >= AppAgentInputBar.minimumExpandedWidth,
              let stableWidth = expandedResizeStableWidth,
              let startTime = expandedResizeStableStartTime,
              abs(width - stableWidth) <= Self.expandedResizeWidthStabilityThreshold else {
            return false
        }

        return Date.timeIntervalSinceReferenceDate - startTime >= Self.expandedResizeHoldDuration
    }

    func resetExpandedResizeWidthHoldTracking() {
        expandedResizeStableWidth = nil
        expandedResizeStableStartTime = nil
    }

    // MARK: 持久化

    func loadPersistedInputBarLayout() {
        storedExpandedInputBarWidth = inputBarLayoutStore.loadExpandedWidth()
        storedCollapsedInputBarPlacement = inputBarLayoutStore.loadCollapsedPlacement()
    }

    func persistExpandedInputBarWidth(_ width: CGFloat) {
        guard let storedWidth = AppAgentInputBarFramePolicy.storableExpandedWidth(width, context: inputBarLayoutContext) else {
            return
        }
        storedExpandedInputBarWidth = storedWidth
        inputBarLayoutStore.saveExpandedWidth(storedWidth)
    }

    func persistCollapsedInputBarPlacement(for frame: CGRect) {
        let context = inputBarLayoutContext
        let constrainedFrame = AppAgentInputBarFramePolicy.constrainedCollapsedFrame(frame, context: context)
        let placement = AppAgentInputBarFramePolicy.collapsedPlacement(for: constrainedFrame, context: context)
        storedCollapsedInputBarPlacement = placement
        inputBarLayoutStore.saveCollapsedPlacement(placement)
    }
}

#endif
