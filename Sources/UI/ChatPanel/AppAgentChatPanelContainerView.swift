//
//  AppAgentChatPanelContainerView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

/// ChatPanel 外层容器的一次纯布局结果。
///
/// 外层容器跟随 inputBar 的横向位置、宽度以及键盘避让位移，不再参与 ChatPanel 的裁切；
/// `dragScrollView` 始终保留展开态画布，避免 resize 跟手期间重建 BODragScroll 几何。
/// 收起进度对应的透明度（`contentAlpha`）交给会话容器 `AppAgentSessionContainerView`，面板和工作区一起淡出。
struct AppAgentChatPanelContainerLayout: Equatable {
    /// ChatPanel 容器相对 inputBar 左右各扩出的距离。
    static let horizontalOutset = AppAgentInputBarFramePolicy.horizontalInset

    /// inputBar 收起时会话内容淡出的 ease-out 系数；具体强度统一由此处配置。
    static let alphaEaseOutCoefficient: CGFloat = 4

    let containerFrame: CGRect
    let dragScrollFrame: CGRect

    /// inputBar 从展开到收起时，会话内容（面板 + 工作区）按 ease-out 曲线由完全显示过渡到透明。
    let contentAlpha: CGFloat

    init(
        bounds: CGRect,
        inputBarFrame: CGRect,
        inputBarExpandedFrame: CGRect
    ) {
        guard bounds.width > 0,
              bounds.height > 0,
              inputBarFrame.width > 0,
              inputBarFrame.height > 0,
              inputBarExpandedFrame.width > 0,
              inputBarExpandedFrame.height > 0 else {
            containerFrame = .zero
            // 容器是画布 frame 的唯一 writer，所以「inputBar 几何还没就绪」这一小段也得由它
            // 给出画布尺寸 —— BODragScroll 需要一个尺寸正确的画布来建立自身几何。此时
            // containerFrame 为零、contentAlpha 为 0，面板并不可见；bounds 本身无效时自然退化为零。
            dragScrollFrame = CGRect(origin: .zero, size: bounds.size)
            contentAlpha = 0
            return
        }

        // 【inputBar 横向收起 alpha 计算入口】按当前宽度计算从展开端到收起端的归一化进度。
        let collapseProgress = Self.collapseProgress(
            inputBarWidth: inputBarFrame.width,
            expandedInputBarWidth: inputBarExpandedFrame.width
        )
        let expandedContainerFrame = Self.containerFrame(
            bounds: bounds,
            inputBarFrame: inputBarExpandedFrame
        )
        containerFrame = Self.containerFrame(
            bounds: bounds,
            inputBarFrame: inputBarFrame
        )

        // 画布保持控制器原始尺寸，横向根据展开态 container 的原点反向偏移；纵向保持在容器本地原点，
        // 因而容器被键盘整体顶起时会带着完整 ChatPanel 同步上移。
        //
        // **这里是 `dragScrollView.frame` 的唯一来源。** 画布是 `BODragScrollView`（UIScrollView），
        // 给它写 frame 会顺带重算并夹取 `contentOffset`，而展示高度正由外层 offset 承载。曾经
        // coordinator 也写一次（`origin: .zero`），两个目标值只在「iPhone 竖屏 + 满宽 inputBar」
        // 时恰好相等；横屏（左安全区）/ iPad 居中 / 用户拖窄过 inputBar 时相差 47~200pt，于是
        // 容器侧判等永远失败 —— 每次布局都停掉在飞的动画并多夹一次 offset。别再加第二个 writer。
        dragScrollFrame = CGRect(
            x: bounds.minX - expandedContainerFrame.minX,
            y: bounds.minY - expandedContainerFrame.minY,
            width: bounds.width,
            height: bounds.height
        )

        // 跟手阶段没有 UIView 动画；每一帧使用可调 ease-out 映射，起始淡出较快、接近透明时逐渐减速。
        contentAlpha = 1 - AppAgentGeometry.easeOut(
            collapseProgress,
            coefficient: Self.alphaEaseOutCoefficient
        )
    }

    private static func collapseProgress(
        inputBarWidth: CGFloat,
        expandedInputBarWidth: CGFloat
    ) -> CGFloat {
        let collapsedWidth = AppAgentInputBarMetrics.collapsedMinWidth
        let travel = expandedInputBarWidth - collapsedWidth
        guard travel > 0.5 else {
            return inputBarWidth <= collapsedWidth + 0.5 ? 1 : 0
        }

        let expandedProgress = AppAgentGeometry.clamp(
            (inputBarWidth - collapsedWidth) / travel,
            0,
            1
        )
        return 1 - expandedProgress
    }

    private static func containerFrame(
        bounds: CGRect,
        inputBarFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: inputBarFrame.minX - horizontalOutset,
            y: bounds.minY,
            width: inputBarFrame.width + horizontalOutset * 2,
            height: bounds.height
        )
    }

}

/// `BODragScrollView` 的透明外层容器，只负责跟随 inputBar 改变位置和宽度、随键盘整体上移。
final class AppAgentChatPanelContainerView: UIView {
    private weak var contentView: UIView?
    private var layoutAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func installContentView(_ view: UIView) {
        contentView = view
        if view.superview !== self {
            addSubview(view)
        }
    }

    /// 事件透明容器：命中落在容器自身（透出宿主 app 内容的空白区域）时穿透到下层，
    /// 命中任意子视图（ChatPanel 内容、可交互控件）时保留子视图的事件响应。
    /// 由 BOUIKit 的 `bo_skipsSelfInHitTest` 提供，见 setup()。
    func installHitTestPassthrough() {
        bo_skipsSelfInHitTest = true
    }

    func apply(_ layout: AppAgentChatPanelContainerLayout, animation: AppAgentInputBarFrameAnimation) {
        let contentTargetFrame = layout.dragScrollFrame
        let targetFrameChanged = !frame.isApproximatelyEqual(to: layout.containerFrame)
            || !(contentView?.frame.isApproximatelyEqual(to: contentTargetFrame) ?? true)

        // animator 启动后 model 值已经是目标值；相同目标无需停止并重启动画。
        guard targetFrameChanged else {
            return
        }

        // 新手势或新动画必须先接管 presentation 状态，避免视图跳回旧 model 值。
        stopAnimationsAtCurrentState()

        let frameChanged = !frame.isApproximatelyEqual(to: layout.containerFrame)
            || !(contentView?.frame.isApproximatelyEqual(to: contentTargetFrame) ?? true)

        if frameChanged {
            let applyFrames = { [weak self] in
                guard let self else { return }
                self.frame = layout.containerFrame
                // **必须判等再写**：contentView 是 BODragScrollView（UIScrollView）。给 scrollView 写
                // frame 会顺带重算并夹取 `contentOffset`，而这次夹取是一次直接的 model 写入，会把刚
                // 起飞的 `bounds.origin` 隐式动画抹掉。实测踩过：键盘抬起时 coordinator 先让展示高度
                // （= 外层 offset）进入动画，紧接这里写一次**值没变**的 frame，offset 动画当场消失、
                // 瞬跳到终态，于是「面板先变矮、容器再慢慢上移」。
                self.contentView?.bo_setFrame(contentTargetFrame)
            }
            if let animator = animation.makeAnimator(animations: applyFrames) {
                startLayoutAnimation(animator)
            } else {
                applyFrames()
            }
        }
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false
        isAccessibilityElement = false
        installHitTestPassthrough()
    }

    private func startLayoutAnimation(_ animator: UIViewPropertyAnimator) {
        let identifier = ObjectIdentifier(animator)
        layoutAnimator = animator
        animator.addCompletion { [weak self] _ in
            guard let self,
                  let currentAnimator = self.layoutAnimator,
                  ObjectIdentifier(currentAnimator) == identifier else { return }
            self.layoutAnimator = nil
        }
        animator.startAnimation()
    }

    private func stopAnimationsAtCurrentState() {
        let containerPresentationFrame = layer.presentation()?.frame
        let contentPresentationFrame = contentView?.layer.presentation()?.frame

        if let layoutAnimator {
            self.layoutAnimator = nil
            layoutAnimator.stopAnimation(true)
        }

        layer.removeAllAnimations()
        contentView?.layer.removeAllAnimations()

        if let containerPresentationFrame {
            frame = containerPresentationFrame
        }
        if let contentPresentationFrame {
            contentView?.frame = contentPresentationFrame
        }
    }
}

#endif
