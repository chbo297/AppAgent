//
//  AppAgentChatPanelView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 对话流面板的透明根容器。
///
/// 根容器按 `AppAgentChatPanelGeometry.dragHandleAreaHeight` 分成拖拽手柄区和内容区域。内容区域背景负责样式与阴影，viewport
/// 负责 mask 裁切，实际聊天内容始终按照完整内容区域布局，不依赖 viewport 的临时尺寸；只有 `listView` 内部的 tableView
/// 会把自身视口高度对齐到当前展示高度（见 `AppAgentChatMessageListView.updateVisibleArea`）。
final class AppAgentChatPanelView: UIView {

    /// 点击内容区导航栏左侧 Session 列表按钮时触发。
    var onSessionListRequested: (() -> Void)?

    /// 点击内容区导航栏右侧收起按钮时触发。
    var onCollapseRequested: (() -> Void)?

    /// 点击内容区导航栏“新对话”按钮时触发。
    var onNewSessionRequested: (() -> Void)?

    /// 聊天内容区，消息的追加和流式更新由宿主直接操作。
    let listView = AppAgentChatMessageListView()

    /// 「等用户拍板」的卡片。只在面板内部呈现，不新建 window、不遮挡宿主界面。
    let decisionCard = AppAgentDecisionCardView()

    /// 内容区顶部导航栏，与拖拽手柄区相互独立。
    let navigationBar = AppAgentChatPanelNavigationBar()

    /// 高度由 `AppAgentChatPanelGeometry.dragHandleAreaHeight` 定义的透明拖拽手柄区。
    let dragHandleAreaView = UIView()

    /// 面板的真实内容坐标空间，不跟随 viewport 的裁切尺寸变化。
    let contentAreaView = UIView()

    /// 内容展示窗口；所有实际内容都添加到这里，并由 shape mask 控制最终可见范围。
    let viewportView = UIView()

    private let backgroundView = AppAgentChatPanelBackgroundView()
    private let grabberView = UIView()
    private let viewportMaskLayer = CAShapeLayer()

    private var currentDisplayHeight: CGFloat?
    private var minimumDisplayHeight: CGFloat?
    private var compactTransitionStartDisplayHeight: CGFloat?
    private var appliedLayout: AppAgentChatPanelContentLayout?

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
        applyContentLayoutIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    /// 【竖向收起跟手入口】BODragScroll 每次发布真实展示高度时调用。
    /// 这里保存最新高度并立即进入 `applyContentLayoutIfNeeded()`，在 compact 过渡区间更新背景与 viewport。
    func updateDisplayHeight(
        _ displayHeight: CGFloat,
        minimumDisplayHeight: CGFloat,
        compactTransitionStartDisplayHeight: CGFloat
    ) {
        let normalizedDisplayHeight = max(0, displayHeight)
        let normalizedMinimumHeight = max(0, minimumDisplayHeight)
        let normalizedTransitionStartHeight = max(
            normalizedMinimumHeight,
            compactTransitionStartDisplayHeight
        )
        let displayHeightChanged = abs(
            (currentDisplayHeight ?? -.greatestFiniteMagnitude) - normalizedDisplayHeight
        ) > 0.001
        let minimumHeightChanged = abs(
            (self.minimumDisplayHeight ?? -.greatestFiniteMagnitude) - normalizedMinimumHeight
        ) > 0.001
        let transitionStartHeightChanged = abs(
            (self.compactTransitionStartDisplayHeight ?? -.greatestFiniteMagnitude)
                - normalizedTransitionStartHeight
        ) > 0.001
        guard displayHeightChanged
            || minimumHeightChanged
            || transitionStartHeightChanged else { return }

        currentDisplayHeight = normalizedDisplayHeight
        self.minimumDisplayHeight = normalizedMinimumHeight
        self.compactTransitionStartDisplayHeight = normalizedTransitionStartHeight
        applyContentLayoutIfNeeded()
    }

    // MARK: - 内部

    /// 直接提交轻量 frame/path 变化，不触发整棵 UITableView 层级的同步 layoutIfNeeded。
    private func applyContentLayoutIfNeeded() {

        let displayHeight = currentDisplayHeight ?? bounds.height
        let minimumDisplayHeight = self.minimumDisplayHeight
            ?? min(
                bounds.height,
                AppAgentChatPanelGeometry.dragHandleAreaHeight + AppAgentInputBar.barHeight
            )
        let compactTransitionStartDisplayHeight = self.compactTransitionStartDisplayHeight
            ?? minimumDisplayHeight
        let layout = AppAgentChatPanelContentLayout(
            bounds: bounds,
            displayHeight: displayHeight,
            minimumDisplayHeight: minimumDisplayHeight,
            compactTransitionStartDisplayHeight: compactTransitionStartDisplayHeight
        )
        guard layout != appliedLayout else { return }
        appliedLayout = layout

        UIView.performWithoutAnimation {
            dragHandleAreaView.frame = layout.dragHandleAreaFrame
            grabberView.frame = layout.grabberFrame
            contentAreaView.frame = layout.contentAreaFrame

            // 【竖向收起实际应用点】这两个 frame 决定 compact 过渡区间内背景和裁切窗口如何缩到 inputBar 大小。
            // 手动调试跟手尺寸、位置时，优先查看 AppAgentChatPanelContentLayout 产出的这两个 frame。
            backgroundView.frame = layout.backgroundFrame
            viewportView.frame = layout.viewportFrame

            // 导航栏和消息列表始终按完整 contentArea 布局；viewport 变化时只裁切，不重排内容。
            navigationBar.frame = layout.navigationBarFrame
            listView.frame = layout.messageListFrame
            layoutDecisionCard()
        }

        // 【竖向收起形状应用点】背景和 viewport mask 共用同一条路径，只计算一次，保证边缘完全重合。
        // 调整跟手圆角时修改 layout 的两个 cornerRadius；调整具体路径形状时修改 AppAgentChatPanelShapePath。
        let shapePath = AppAgentChatPanelShapePath.make(
            in: viewportView.bounds,
            topCornerRadius: layout.topCornerRadius,
            bottomCornerRadius: layout.bottomCornerRadius
        ).cgPath
        backgroundView.apply(shapePath: shapePath)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportMaskLayer.frame = viewportView.bounds
        viewportMaskLayer.path = shapePath
        CATransaction.commit()
    }

    /// 决策卡片底部要额外让出的高度：面板 viewport 会延伸到 inputBar 之下，
    /// 不让这一段卡片底部的按钮会被输入栏压住（实测踩过）。由 VC 用 inputBar 几何写入。
    var decisionCardBottomInset: CGFloat = 0 {
        didSet {
            guard decisionCardBottomInset != oldValue else { return }
            layoutDecisionCard()
        }
    }

    /// 卡片贴**可见区**（viewport）底边，左右留边，底部再让开 inputBar。
    ///
    /// 注意别拿 `layout.messageListFrame` 定位：消息列表按完整 contentArea 布局、由
    /// viewport 裁切，它的底边通常在可见区外面，卡片会被裁掉看不见（踩过）。
    private func layoutDecisionCard() {
        guard !decisionCard.isHidden else { return }
        let inset: CGFloat = 12
        let bounds = viewportView.bounds
        let width = bounds.width - inset * 2
        let available = bounds.height - inset * 2 - decisionCardBottomInset
        guard width > 0, available > 0 else { return }
        let height = min(decisionCard.height(fittingWidth: width), available)
        decisionCard.frame = CGRect(x: bounds.minX + inset,
                                    y: bounds.maxY - height - inset - decisionCardBottomInset,
                                    width: width,
                                    height: height)
    }

    /// 呈现一张决策卡片。返回 false 表示现在没法呈现（还没布局过），交回决策中心兜底。
    @discardableResult
    func presentDecision(_ request: DecisionRequest,
                         onSelect: @escaping (DecisionOutcome) -> Void) -> Bool {
        guard viewportView.bounds.width > 0, viewportView.bounds.height > 0 else {
            Logger.info("AppAgentChatPanelView",
                        "decisionCardCannotPresent: viewport=\(viewportView.bounds)")
            return false
        }
        decisionCard.configure(with: request)
        decisionCard.onSelect = { [weak self] outcome in
            self?.dismissDecision()
            onSelect(outcome)
        }
        decisionCard.isHidden = false
        viewportView.bringSubviewToFront(decisionCard)
        layoutDecisionCard()
        return true
    }

    func dismissDecision() {
        decisionCard.isHidden = true
        decisionCard.onSelect = nil
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false

        dragHandleAreaView.backgroundColor = .clear
        dragHandleAreaView.isUserInteractionEnabled = false
        addSubview(dragHandleAreaView)

        grabberView.layer.cornerRadius = AppAgentChatPanelContentLayout.grabberSize.height / 2
        dragHandleAreaView.addSubview(grabberView)

        contentAreaView.backgroundColor = .clear
        contentAreaView.clipsToBounds = false
        addSubview(contentAreaView)

        backgroundView.isUserInteractionEnabled = false
        contentAreaView.addSubview(backgroundView)

        viewportView.backgroundColor = .clear
        viewportView.layer.mask = viewportMaskLayer
        contentAreaView.addSubview(viewportView)
        viewportView.addSubview(listView)
        viewportView.addSubview(navigationBar)
        decisionCard.isHidden = true
        viewportView.addSubview(decisionCard)

        navigationBar.onSessionListRequested = { [weak self] in
            self?.onSessionListRequested?()
        }
        navigationBar.onCollapseRequested = { [weak self] in
            self?.onCollapseRequested?()
        }
        navigationBar.onNewSessionRequested = { [weak self] in
            self?.onNewSessionRequested?()
        }

        viewportMaskLayer.fillColor = UIColor.black.cgColor
        applyAppearance()
    }

    private func applyAppearance() {
        grabberView.backgroundColor = AppAgentAppearance.placeholderText
        backgroundView.applyAppearance(for: traitCollection)
    }
}

/// ChatPanel 内容区域的背景层，统一管理填充色、边缘形状和阴影。
private final class AppAgentChatPanelBackgroundView: UIView {
    private let fillLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(shapePath: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        fillLayer.path = shapePath
        layer.shadowPath = shapePath
        CATransaction.commit()
    }

    func applyAppearance(for traitCollection: UITraitCollection) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.fillColor = AppAgentAppearance.inputBarBackground
            .resolvedColor(with: traitCollection)
            .cgColor
        layer.shadowColor = AppAgentAppearance.inputBarShadow
            .resolvedColor(with: traitCollection)
            .cgColor
        layer.shadowOpacity = AppAgentAppearance.inputBarShadowOpacity(for: traitCollection)
        CATransaction.commit()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.addSublayer(fillLayer)
    }
}

/// 生成上、下圆角可独立变化的面板路径，供背景层和 viewport mask 共用。
private enum AppAgentChatPanelShapePath {
    static func make(
        in bounds: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> UIBezierPath {
        guard bounds.width > 0, bounds.height > 0 else { return UIBezierPath() }

        let maximumRadius = min(bounds.width, bounds.height) / 2
        let topRadius = AppAgentGeometry.clamp(topCornerRadius, 0, maximumRadius)
        let bottomRadius = AppAgentGeometry.clamp(bottomCornerRadius, 0, maximumRadius)
        let path = UIBezierPath()

        // 从上边左侧开始，顺时针依次连接右上、右下、左下、左上四个圆角。
        path.move(to: CGPoint(x: bounds.minX + topRadius, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX - topRadius, y: bounds.minY))
        if topRadius > 0 {
            path.addArc(
                withCenter: CGPoint(x: bounds.maxX - topRadius, y: bounds.minY + topRadius),
                radius: topRadius,
                startAngle: -.pi / 2,
                endAngle: 0,
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - bottomRadius))
        if bottomRadius > 0 {
            path.addArc(
                withCenter: CGPoint(x: bounds.maxX - bottomRadius, y: bounds.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: 0,
                endAngle: .pi / 2,
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: bounds.minX + bottomRadius, y: bounds.maxY))
        if bottomRadius > 0 {
            path.addArc(
                withCenter: CGPoint(x: bounds.minX + bottomRadius, y: bounds.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .pi / 2,
                endAngle: .pi,
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + topRadius))
        if topRadius > 0 {
            path.addArc(
                withCenter: CGPoint(x: bounds.minX + topRadius, y: bounds.minY + topRadius),
                radius: topRadius,
                startAngle: .pi,
                endAngle: .pi * 1.5,
                clockwise: true
            )
        }
        path.close()
        return path
    }
}

#endif
