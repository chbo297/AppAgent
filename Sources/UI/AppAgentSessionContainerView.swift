//
//  AppAgentSessionContainerView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

/// 会话内容的容器：铺满对话界面，放在输入栏之下，里面从下到上是工作区容器和对话面板容器。
///
/// 对话面板和工作区都属于当前会话。输入栏收成小球时整个容器按收起进度一起淡出，并退出命中和无障碍树；
/// 展开时一起回来。容器内两者各自显隐：面板有自己的三档，工作区按会话数据显示或隐藏。
/// 面板跟随输入栏的宽度和键盘位移由 `AppAgentChatPanelContainerView` 自己处理，这里只管收起。
final class AppAgentSessionContainerView: UIView {
    private var alphaAnimator: UIViewPropertyAnimator?
    private weak var workspaceView: UIView?
    private weak var chatPanelView: UIView?

    /// model alpha 在动画开始时就变成终值；只有屏幕上确实消失才算结束连续阅读。
    var isVisuallyHidden: Bool {
        if let presentation = layer.presentation() {
            return presentation.opacity <= 0.01
        }
        // 尚未提交首帧时 presentation 可能为空，不能把正在淡出的目标值当成已隐藏。
        return alphaAnimator == nil && alpha <= 0.01
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 放入对话面板容器，位于工作区之上。
    func installChatPanel(_ view: UIView) {
        chatPanelView = view
        if view.superview !== self {
            addSubview(view)
        }
    }

    /// 放入工作区容器的视图，位于对话面板之下，铺满本容器。
    func installWorkspace(_ view: UIView) {
        workspaceView = view
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let chatPanelView, chatPanelView.superview === self {
            insertSubview(view, belowSubview: chatPanelView)
        } else {
            insertSubview(view, at: 0)
        }
    }

    /// 按输入栏收起进度设置会话内容的透明度；完全收起时同时退出命中和无障碍树，重新展开时在动画开始前立即恢复。
    func applyContentAlpha(_ targetAlpha: CGFloat, animation: AppAgentInputBarFrameAnimation) {
        let isVisible = targetAlpha > 0.01
        isUserInteractionEnabled = isVisible
        accessibilityElementsHidden = !isVisible

        // animator 启动后 model 值已经是目标值；相同目标无需停止并重启动画。
        guard abs(alpha - targetAlpha) > 0.001 else {
            return
        }
        // 新手势或新动画必须先接管 presentation 状态，避免视图跳回旧 model 值。
        stopAlphaAnimationAtCurrentState()
        guard abs(alpha - targetAlpha) > 0.001 else {
            return
        }
        guard animation.isAnimated else {
            // 手势 changed 阶段走这里：直接应用已经过 ease-out 函数计算的 alpha，保证完全跟手。
            alpha = targetAlpha
            return
        }

        let duration: TimeInterval
        switch animation {
        case .immediate:
            duration = 0
        case .standard:
            duration = 0.24
        case .boundaryRebound:
            duration = 0.30
        }

        // 抬手后的展开/收起落位也使用 easeOut，并可从 presentation 状态无缝接管。
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) { [weak self] in
            self?.alpha = targetAlpha
        }
        let identifier = ObjectIdentifier(animator)
        alphaAnimator = animator
        animator.addCompletion { [weak self] _ in
            guard let self,
                  let currentAnimator = self.alphaAnimator,
                  ObjectIdentifier(currentAnimator) == identifier else {
                return
            }
            self.alphaAnimator = nil
        }
        animator.startAnimation()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false
        isAccessibilityElement = false
        // 命中落在容器自身（透出宿主内容的空白区域）时穿透到下层，命中子视图时照常响应。
        bo_skipsSelfInHitTest = true
    }

    private func stopAlphaAnimationAtCurrentState() {
        let presentationAlpha = layer.presentation().map { presentation in
            CGFloat(presentation.opacity)
        }
        if let alphaAnimator {
            self.alphaAnimator = nil
            alphaAnimator.stopAnimation(true)
        }
        layer.removeAllAnimations()
        if let presentationAlpha {
            alpha = presentationAlpha
        }
    }
}

#endif
