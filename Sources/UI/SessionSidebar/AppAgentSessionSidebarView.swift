//
//  AppAgentSessionSidebarView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 覆盖 AppAgentViewController 的 Session 侧栏容器，管理半宽布局、背景点击和可中断进出场动画。
final class AppAgentSessionSidebarView: UIView {
    var onDismissRequested: (() -> Void)?
    var onSelectItem: ((AppAgentSessionSidebarItem) -> Void)?
    var onRenameItem: ((AppAgentSessionSidebarItem) -> Void)?
    var onDeleteItem: ((AppAgentSessionSidebarItem) -> Void)?
    var onSettingsTapped: (() -> Void)?
    var onDebugTapped: (() -> Void)?

    private(set) var isPresented = false
    let sessionListView = AppAgentSessionListView()

    private static let widthRatio: CGFloat = 0.5
    private static let presentationDuration: TimeInterval = 0.24
    private static let dismissalDuration: TimeInterval = 0.20

    private let backdropControl = UIControl()
    private var visibilityAnimator: UIViewPropertyAnimator?

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

        backdropControl.frame = bounds
        let width = max(0, bounds.width * Self.widthRatio)
        sessionListView.frame = CGRect(
            x: isPresented ? 0 : -width,
            y: 0,
            width: width,
            height: bounds.height
        )
        updateShadowPath()
    }

    func setItems(_ items: [AppAgentSessionSidebarItem]) {
        sessionListView.setItems(items)
    }

    func setPresented(_ presented: Bool, animated: Bool) {
        guard presented != isPresented else { return }

        if presented {
            isHidden = false
            accessibilityViewIsModal = true
        }
        layoutIfNeeded()
        stopVisibilityAnimationAtCurrentState()
        isPresented = presented

        let width = max(0, bounds.width * Self.widthRatio)
        let applyFinalState = { [weak self] in
            guard let self else { return }
            self.backdropControl.alpha = presented ? 1 : 0
            self.sessionListView.frame = CGRect(
                x: presented ? 0 : -width,
                y: 0,
                width: width,
                height: self.bounds.height
            )
        }

        guard animated else {
            applyFinalState()
            finishVisibilityChange(presented: presented)
            return
        }

        let duration = presented ? Self.presentationDuration : Self.dismissalDuration
        let curve: UIView.AnimationCurve = presented ? .easeOut : .easeIn
        let animator = UIViewPropertyAnimator(duration: duration, curve: curve, animations: applyFinalState)
        let identifier = ObjectIdentifier(animator)
        visibilityAnimator = animator
        animator.addCompletion { [weak self] position in
            guard let self,
                  let currentAnimator = self.visibilityAnimator,
                  ObjectIdentifier(currentAnimator) == identifier else { return }
            self.visibilityAnimator = nil
            guard position == .end else { return }
            self.finishVisibilityChange(presented: presented)
        }
        animator.startAnimation()
    }

    private func setup() {
        backgroundColor = .clear
        isHidden = true
        accessibilityViewIsModal = false

        backdropControl.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        backdropControl.alpha = 0
        backdropControl.accessibilityLabel = "关闭会话列表"
        backdropControl.addTarget(self, action: #selector(didTapBackdrop), for: .touchUpInside)
        addSubview(backdropControl)

        sessionListView.layer.shadowColor = UIColor.black.cgColor
        sessionListView.layer.shadowOpacity = 0.18
        sessionListView.layer.shadowRadius = 14
        sessionListView.layer.shadowOffset = CGSize(width: 4, height: 0)
        sessionListView.onSelectItem = { [weak self] item in
            self?.onSelectItem?(item)
        }
        sessionListView.onRenameItem = { [weak self] item in
            self?.onRenameItem?(item)
        }
        sessionListView.onDeleteItem = { [weak self] item in
            self?.onDeleteItem?(item)
        }
        sessionListView.onSettingsTapped = { [weak self] in
            self?.onSettingsTapped?()
        }
        sessionListView.onDebugTapped = { [weak self] in
            self?.onDebugTapped?()
        }
        addSubview(sessionListView)
    }

    private func stopVisibilityAnimationAtCurrentState() {
        let presentationFrame = sessionListView.layer.presentation()?.frame
        let presentationBackdropAlpha = backdropControl.layer.presentation().map { CGFloat($0.opacity) }

        if let visibilityAnimator {
            self.visibilityAnimator = nil
            visibilityAnimator.stopAnimation(true)
        }
        sessionListView.layer.removeAllAnimations()
        backdropControl.layer.removeAllAnimations()

        if let presentationFrame {
            sessionListView.frame = presentationFrame
        }
        if let presentationBackdropAlpha {
            backdropControl.alpha = presentationBackdropAlpha
        }
    }

    private func finishVisibilityChange(presented: Bool) {
        accessibilityViewIsModal = presented
        if !presented {
            isHidden = true
        }
    }

    private func updateShadowPath() {
        let path = UIBezierPath(rect: sessionListView.bounds).cgPath
        sessionListView.layer.shadowPath = path
    }

    @objc private func didTapBackdrop() {
        onDismissRequested?()
    }
}

#endif
