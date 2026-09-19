//
//  AppAgentChatPanelGeometry.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 对话流面板可以稳定停靠的三个业务档位。
enum AppAgentChatPanelDetent: CaseIterable {
    /// 只在 inputBar 上方露出拖拽提示区域。
    case peek

    /// 默认展示约半屏内容。
    case half

    /// 展开时允许拖拽手柄区进入顶部安全区，内容区域仍从安全区下沿开始。
    case full
}

/// 一次 ChatPanel 布局所需的不可变几何结果，不包含任何手势或动画决策。
struct AppAgentChatPanelGeometry: Equatable {

    /// 面板相对 inputBar 的横向扩展量，来源于 inputBar 布局策略的 `horizontalInset`。
    static let horizontalOutset = AppAgentInputBarFramePolicy.horizontalInset

    /// 面板顶部两个圆角的半径。
    static let topCornerRadius: CGFloat = 20

    /// 顶部拖拽手柄区的固定高度；peek 时只在 inputBar 上方露出这一段。
    static let dragHandleAreaHeight: CGFloat = 28

    /// BODragScroll 持有的固定最大面板尺寸。
    let panelSize: CGSize

    /// peek 档对应的实际展示高度。
    let peekHeight: CGFloat

    /// half 档对应的实际展示高度。
    let halfHeight: CGFloat

    /// ChatPanel 的最大展示高度：拖拽手柄区可占用顶部安全区，内容区域不越过安全区下沿。
    let maximumDisplayHeight: CGFloat

    /// 内部消息列表的底部 inset：展开态 inputBar 白色背景顶部到屏幕底部的高度。
    ///
    /// 只由安全区和 bar 高度决定，因此在整个生命周期内固定：键盘弹出时 inputBar 与 ChatPanel 容器
    /// 会一起上移，列表不需要再改 inset；面板拖动过程中列表滚动指标也因此不会被反复重算。
    let listBottomInset: CGFloat

    /// 根据控制器、安全区和 inputBar 展开宽度生成合法几何；无有效空间时返回 nil。
    init?(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        inputBarExpandedFrame: CGRect
    ) {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let topReservedHeight = max(0, safeAreaInsets.top - Self.dragHandleAreaHeight)
        let maximumDisplayHeight = max(0, bounds.height - topReservedHeight)
        guard maximumDisplayHeight > 0 else { return nil }

        let preferredWidth = inputBarExpandedFrame.width > 0
            ? inputBarExpandedFrame.width + Self.horizontalOutset * 2
            : bounds.width
        let panelWidth = min(bounds.width, max(0, preferredWidth))
        guard panelWidth > 0 else { return nil }

        let listBottomInset = min(
            maximumDisplayHeight,
            max(0, safeAreaInsets.bottom + AppAgentInputBar.barHeight)
        )
        let peekHeight = min(
            maximumDisplayHeight,
            max(0, listBottomInset + Self.dragHandleAreaHeight)
        )
        let halfHeight = min(
            maximumDisplayHeight,
            max(peekHeight, maximumDisplayHeight * 0.5)
        )

        panelSize = CGSize(width: panelWidth, height: maximumDisplayHeight)
        self.peekHeight = peekHeight
        self.halfHeight = halfHeight
        self.maximumDisplayHeight = maximumDisplayHeight
        self.listBottomInset = listBottomInset
    }

    /// 交给 BODragScroll 的已排序、去重档位，避免紧凑窗口中多个业务档位重合。
    var detentHeights: [CGFloat] {
        [peekHeight, halfHeight, maximumDisplayHeight].reduce(into: []) { result, height in
            guard height > 0 else { return }
            if let last = result.last, abs(last - height) <= 0.5 { return }
            result.append(height)
        }
    }

    /// 返回业务档位在当前几何中的展示高度。
    func height(for detent: AppAgentChatPanelDetent) -> CGFloat {
        switch detent {
        case .peek:
            return peekHeight
        case .half:
            return halfHeight
        case .full:
            return maximumDisplayHeight
        }
    }

    /// 将任意展示高度映射到当前几何中距离最近的业务档位。
    ///
    /// 紧凑窗口中多个业务档位可能对应同一个物理高度；距离相同时优先保留原业务档位，
    /// 避免窗口恢复后把原来的 half/full 错误恢复成 peek。
    func nearestDetent(
        to displayHeight: CGFloat,
        preferredDetent: AppAgentChatPanelDetent? = nil
    ) -> AppAgentChatPanelDetent {
        let distances = AppAgentChatPanelDetent.allCases.map { detent in
            (detent: detent, distance: abs(height(for: detent) - displayHeight))
        }
        guard let minimumDistance = distances.map({ $0.distance }).min() else { return .half }

        if let preferredDetent,
           let preferredDistance = distances.first(where: { $0.detent == preferredDetent })?.distance,
           abs(preferredDistance - minimumDistance) <= 0.5 {
            return preferredDetent
        }
        return distances.first(where: { abs($0.distance - minimumDistance) <= 0.5 })?.detent ?? .half
    }

    /// 把布局回调保留下来的旧展示高度约束到新几何的合法范围。
    func clampedDisplayHeight(_ displayHeight: CGFloat) -> CGFloat {
        min(maximumDisplayHeight, max(peekHeight, displayHeight))
    }
}

/// ChatPanel 内部层级的一次纯布局结果。
///
/// `contentFrame` 始终以完整 `contentAreaFrame` 为坐标基准；即使 viewport 在 compact 过渡区间
/// 收起过程中变窄、变矮，实际聊天内容也不会跟着重排，只会被 viewport 的 mask 裁切。
struct AppAgentChatPanelContentLayout: Equatable {
    /// A/B 过渡曲线系数；当前配置对应线性变化。
    static let compactTransitionEaseOutCoefficient: CGFloat = 1

    /// compact 状态与 inputBar 对齐所需的左右间距。
    static let compactHorizontalInset = AppAgentInputBarFramePolicy.horizontalInset

    /// 顶部拖拽指示条的固定尺寸。
    static let grabberSize = CGSize(width: 36, height: 5)

    let dragHandleAreaFrame: CGRect
    let grabberFrame: CGRect
    let contentAreaFrame: CGRect
    let backgroundFrame: CGRect
    let viewportFrame: CGRect
    let contentFrame: CGRect
    let navigationBarFrame: CGRect
    let messageListFrame: CGRect
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let compactProgress: CGFloat

    init(
        bounds: CGRect,
        displayHeight: CGFloat,
        minimumDisplayHeight: CGFloat,
        compactTransitionStartDisplayHeight: CGFloat
    ) {
        guard bounds.width > 0, bounds.height > 0 else {
            dragHandleAreaFrame = .zero
            grabberFrame = .zero
            contentAreaFrame = .zero
            backgroundFrame = .zero
            viewportFrame = .zero
            contentFrame = .zero
            navigationBarFrame = .zero
            messageListFrame = .zero
            topCornerRadius = 0
            bottomCornerRadius = 0
            compactProgress = 0
            return
        }

        let dragHandleAreaHeight = min(Self.dragHandleAreaHeight, bounds.height)
        dragHandleAreaFrame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: dragHandleAreaHeight
        )
        grabberFrame = CGRect(
            x: (bounds.width - Self.grabberSize.width) / 2,
            y: (dragHandleAreaHeight - Self.grabberSize.height) / 2,
            width: Self.grabberSize.width,
            height: Self.grabberSize.height
        )
        contentAreaFrame = CGRect(
            x: 0,
            y: dragHandleAreaHeight,
            width: bounds.width,
            height: max(0, bounds.height - dragHandleAreaHeight)
        )

        // 【竖向收起进度计算点】展示高度从 half 档降到最小档时，进度由展开端增长到收起端；
        // `compactTransitionCurve(_:)` 是唯一的曲线入口，后续可在不修改 A/B 几何的情况下更换曲线。
        let normalizedDisplayHeight = max(0, displayHeight)
        let normalizedMinimumHeight = AppAgentGeometry.clamp(minimumDisplayHeight, 0, bounds.height)
        let transitionStart = AppAgentGeometry.clamp(
            compactTransitionStartDisplayHeight,
            normalizedMinimumHeight,
            bounds.height
        )
        let transitionSpan = transitionStart - normalizedMinimumHeight
        let linearCompactProgress: CGFloat
        if transitionSpan > 0.001 {
            linearCompactProgress = AppAgentGeometry.clamp(
                (transitionStart - normalizedDisplayHeight) / transitionSpan,
                0,
                1
            )
        } else {
            // 紧凑窗口中 half 与最小档可能重合，避免除零并确保最小态仍完整对齐 inputBar。
            linearCompactProgress = normalizedDisplayHeight <= normalizedMinimumHeight ? 1 : 0
        }
        compactProgress = Self.compactTransitionCurve(linearCompactProgress)

        // 完全展开状态：背景和 viewport 使用完整 contentArea；真实内容坐标始终以此尺寸布局。
        let fullyExpandedFrame = CGRect(origin: .zero, size: contentAreaFrame.size)

        // A 状态：刚进入 compact 过渡区间时，宽度仍为 ChatPanel 宽度，高度等于当前可见高度减去拖拽手柄区。
        // 从完整 frame 切到 A frame 的差异都位于屏幕可见区域下方，因此视觉连续且不会重排内部列表。
        let transitionStartFrame = CGRect(
            x: 0,
            y: 0,
            width: contentAreaFrame.width,
            height: min(
                contentAreaFrame.height,
                max(0, transitionStart - dragHandleAreaHeight)
            )
        )

        // B 状态：最小展示高度下，背景和 viewport 与展开态 inputBar 的背景区域对齐。
        let compactInset = min(Self.compactHorizontalInset, contentAreaFrame.width / 2)
        let compactFrame = CGRect(
            x: compactInset,
            y: 0,
            width: max(0, contentAreaFrame.width - compactInset * 2),
            height: min(AppAgentInputBar.barHeight, contentAreaFrame.height)
        )

        let isInsideCompactTransition = normalizedDisplayHeight <= transitionStart
        let sourceFrame = isInsideCompactTransition ? transitionStartFrame : fullyExpandedFrame

        // 【竖向收起几何计算点】A 到 B 之间只通过 compactProgress 插值，背景与 viewport 使用同一结果。
        let presentationFrame = Self.interpolate(
            from: sourceFrame,
            to: compactFrame,
            progress: compactProgress
        )
        backgroundFrame = presentationFrame
        viewportFrame = presentationFrame

        // viewport 缩小时通过负 origin 保持内容在 contentArea 坐标系中的原始位置和完整尺寸。
        contentFrame = CGRect(
            x: -presentationFrame.minX,
            y: -presentationFrame.minY,
            width: contentAreaFrame.width,
            height: contentAreaFrame.height
        )
        let navigationBarHeight = min(
            AppAgentChatPanelNavigationBar.height,
            contentFrame.height
        )
        navigationBarFrame = CGRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: contentFrame.width,
            height: navigationBarHeight
        )
        messageListFrame = CGRect(
            x: contentFrame.minX,
            y: navigationBarFrame.maxY,
            width: contentFrame.width,
            height: max(0, contentFrame.height - navigationBarHeight)
        )

        let maximumRadius = max(0, min(presentationFrame.width, presentationFrame.height) / 2)
        let expandedCornerRadius = AppAgentChatPanelGeometry.topCornerRadius
        let compactCornerRadius = AppAgentInputBar.expandedCornerRadius
        topCornerRadius = min(
            maximumRadius,
            Self.interpolate(
                from: expandedCornerRadius,
                to: compactCornerRadius,
                progress: compactProgress
            )
        )

        // A/B 过渡中四角使用同一半径；高于 A 点时仍保持展开面板“上圆角、下直角”的形状。
        let bottomStartRadius = isInsideCompactTransition ? expandedCornerRadius : 0
        bottomCornerRadius = min(
            maximumRadius,
            Self.interpolate(
                from: bottomStartRadius,
                to: compactCornerRadius,
                progress: compactProgress
            )
        )
    }

    private static var dragHandleAreaHeight: CGFloat {
        AppAgentChatPanelGeometry.dragHandleAreaHeight
    }

    /// A/B 跟手变化的统一曲线入口；具体曲线由 `compactTransitionEaseOutCoefficient` 配置。
    private static func compactTransitionCurve(_ linearProgress: CGFloat) -> CGFloat {
        AppAgentGeometry.easeOut(
            linearProgress,
            coefficient: compactTransitionEaseOutCoefficient
        )
    }

    private static func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * AppAgentGeometry.clamp(progress, 0, 1)
    }

    private static func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: interpolate(from: start.minX, to: end.minX, progress: progress),
            y: interpolate(from: start.minY, to: end.minY, progress: progress),
            width: interpolate(from: start.width, to: end.width, progress: progress),
            height: interpolate(from: start.height, to: end.height, progress: progress)
        )
    }
}

#endif
