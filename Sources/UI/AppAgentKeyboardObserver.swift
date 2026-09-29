//
//  AppAgentKeyboardObserver.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 键盘高度观察助手：统一 keyboardWillChangeFrame 的解析与"相对某个 view 的遮挡高度"计算。
/// 各持有方（控制器 / 语音编辑态）各自实例化，解析逻辑只写这一份。
///
/// 整个类只在主线程活动：通知由 UIKit 在主线程投递，算高度要读 view 几何，回调又要驱动
/// `UIView.animate`。所以把隔离直接标在类型上，而不是留给每个调用方各自猜。
@MainActor
final class AppAgentKeyboardObserver {
    /// 键盘自己的动画参数。**曲线必须一起带出来**：只用 duration 配
    /// `UIView.animate(withDuration:)` 会落到 `.curveEaseInOut`，而系统键盘用的是私有曲线
    /// （`UIView.AnimationCurve` 常量 7），两条曲线同时长但速度分布不同 —— 表现就是 inputBar 与
    /// 键盘「一起出发、中途分开、最后又汇合」。
    struct Animation {
        let duration: TimeInterval
        let options: UIView.AnimationOptions

        /// 直接用系统给的曲线跑一段动画，调用方不必再自己拼 options。
        /// 时长取个下限：极少数转场里键盘会报 0，直接用 0 会丢掉这一段的插值。
        @MainActor
        func run(_ body: @escaping @MainActor @Sendable () -> Void) {
            UIView.animate(withDuration: max(duration, 0.01), delay: 0, options: options, animations: body)
        }
    }

    /// 键盘遮挡高度变化时回调（主线程）。height 为键盘与 referenceView 的相交高度。
    var onChange: (@MainActor (_ height: CGFloat, _ animation: Animation) -> Void)?

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
        onChange?(height, Self.animation(duration: duration, userInfo: notification.userInfo))
    }

    /// 曲线原始值是 `UIView.AnimationCurve` 的 rawValue，左移 16 位才是 `AnimationOptions`；
    /// 缺键或取不到时退回 `.curveEaseInOut`（`UIView.animate` 的默认值），行为不比以前差。
    private static func animation(
        duration: TimeInterval,
        userInfo: [AnyHashable: Any]?
    ) -> Animation {
        guard let raw = userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
            return Animation(duration: duration, options: [.curveEaseInOut, .beginFromCurrentState])
        }
        let curve = UIView.AnimationOptions(rawValue: UInt(raw) << 16)
        return Animation(duration: duration, options: [curve, .beginFromCurrentState])
    }
}

#endif
