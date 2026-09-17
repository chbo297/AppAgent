//
//  AppAgentWindow.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

/// A full-screen passthrough window. Only subviews that handle touches
/// receive interaction; taps on empty areas pass through to the window below.
///
/// 穿透由 BOUIKit 的 `bo_skipsSelfInHitTest` 实现：window 与 rootViewController.view
/// 命中自己时都返回 nil，触摸落到下层窗口；命中任意子视图时照常响应。
public class AppAgentWindow: UIWindow {

    /// Convenience initializer that wires up an overlay window:
    /// installs `rootViewController`, applies overlay defaults
    /// (clear background, `windowLevel = .normal + 1`) and makes the window
    /// visible without stealing key status from the host window.
    public convenience init(windowScene: UIWindowScene, rootViewController: UIViewController) {
        self.init(windowScene: windowScene)
        self.rootViewController = rootViewController
        self.backgroundColor = .clear
        self.windowLevel = .normal + 1
        self.isHidden = false
    }

    public override var rootViewController: UIViewController? {
        didSet {
            // window 自身与根视图都不接触摸，只让业务子视图响应。
            bo_skipsSelfInHitTest = true
            rootViewController?.view.bo_skipsSelfInHitTest = true
        }
    }
}

#endif
