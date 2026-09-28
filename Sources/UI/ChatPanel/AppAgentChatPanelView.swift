//
//  AppAgentChatPanelView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 对话流面板的透明根容器。
///
/// 根容器按 `AppAgentChatPanelGeometry.dragHandleAreaHeight` 分成拖拽手柄区和内容区域。内容区域背景负责样式与阴影，viewport
/// 负责裁切，实际聊天内容始终按照完整内容区域布局，不依赖 viewport 的临时尺寸；只有 `listView` 内部的 tableView
/// 会把自身视口高度对齐到当前展示高度（见 `AppAgentChatMessageListView.updateVisibleArea`）。
///
/// **裁切与圆角一律用 `clipsToBounds` + `layer.cornerRadius` + `maskedCorners` 表达，不用 shape mask。**
/// 实测踩过：`layer.mask` 不吃 UIKit 动画块的隐式动画（`animationKeys()` 恒为空），而它又是唯一的裁切者，
/// 于是键盘动画里可见边界第一帧就跳到终态、内容再慢慢滑上来，看起来就是「先落后键盘、再跳一下」；
/// 想显式给 mask 补 CAAnimation 的话，`path` 那条又会在半屏高度制造「重绘半截闪白」。
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

    /// 内容展示窗口；所有实际内容都添加到这里，由它自己的 bounds + 圆角裁切出最终可见范围。
    let viewportView = UIView()

    private let backgroundView = AppAgentChatPanelBackgroundView()
    private let grabberView = UIView()

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

    /// 提交面板内部的一次纯几何变化。
    ///
    /// **写入一律直接提交，跟随调用方所处的动画上下文**：键盘动画块里调 → 和面板 frame、容器位移
    /// 同一条时间曲线插值；手势跟手帧没有动画上下文 → 立即生效。这里不剥动画（`performWithoutAnimation`
    /// 会让裁切窗口瞬跳到终态，内容再慢慢滑上来），也不给任何 layer 手工补 CAAnimation。
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

        // 【竖向收起形状应用点】背景和 viewport 共用同一组圆角，保证边缘完全重合。
        // A/B 过渡区间四角同半径；高于 A 点是「上圆角、下直角」。
        applyCornerRadius(top: layout.topCornerRadius, bottom: layout.bottomCornerRadius, to: viewportView)
        backgroundView.applyCornerRadius(top: layout.topCornerRadius, bottom: layout.bottomCornerRadius)
    }

    /// 上下圆角只有「四角同半径」与「只上两角」两种形态，正好能用 `maskedCorners` 表达。
    private func applyCornerRadius(top: CGFloat, bottom: CGFloat, to view: UIView) {
        view.layer.cornerRadius = top
        view.layer.maskedCorners = bottom > 0.5
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
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
        viewportView.clipsToBounds = true
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

        applyAppearance()
    }

    private func applyAppearance() {
        grabberView.backgroundColor = AppAgentAppearance.placeholderText
        backgroundView.applyAppearance(for: traitCollection)
    }
}

/// ChatPanel 内容区域的背景层，统一管理填充色、圆角和阴影。
///
/// 填充直接用 `layer.backgroundColor` + `cornerRadius`（不再用 CAShapeLayer 画路径），阴影也不设
/// `shadowPath`：让 UIKit 从 layer 形状自己推。这样背景的形状变化和 frame 变化走同一条隐式动画，
/// 不会出现「frame 在动、填充路径已经瞬跳到终态」导致的半截闪白。
private final class AppAgentChatPanelBackgroundView: UIView, AppAgentRuntimeOwned {

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func applyCornerRadius(top: CGFloat, bottom: CGFloat) {
        layer.cornerRadius = top
        layer.maskedCorners = bottom > 0.5
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    func applyAppearance(for traitCollection: UITraitCollection) {
        backgroundColor = AppAgentAppearance.inputBarBackground
            .resolvedColor(with: traitCollection)
        layer.shadowColor = AppAgentAppearance.inputBarShadow
            .resolvedColor(with: traitCollection)
            .cgColor
        layer.shadowOpacity = AppAgentAppearance.inputBarShadowOpacity(for: traitCollection)
    }

    private func setup() {
        clipsToBounds = false
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -4)
    }
}

#endif
