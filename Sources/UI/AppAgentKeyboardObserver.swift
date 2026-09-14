//
//  AppAgentKeyboardObserver.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 键盘高度观察助手：统一 keyboardWillChangeFrame 的解析与"相对某个 view 的遮挡高度"计算。
/// 各持有方（控制器 / 语音编辑态）各自实例化，解析逻辑只写这一份。
final class AppAgentKeyboardObserver {
    /// 键盘遮挡高度变化时回调（主线程）。height 为键盘与 referenceView 的相交高度。
    var onChange: ((_ height: CGFloat, _ duration: TimeInterval) -> Void)?

    private(set) var keyboardHeight: CGFloat = 0

    private weak var referenceView: UIView?

    init(referenceView: UIView) {
        self.referenceView = referenceView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func handleKeyboardWillChangeFrame(_ notification: Notification) {
        guard let referenceView = referenceView,
              let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
        else { return }

        let frameInView = referenceView.convert(endFrame, from: nil)
        let height = max(0, referenceView.bounds.intersection(frameInView).height)
        guard abs(height - keyboardHeight) > 0.5 else { return }
        keyboardHeight = height
        onChange?(height, duration)
    }
}

#endif
