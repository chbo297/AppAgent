//
//  AppAgentWindow.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// A full-screen passthrough window. Only subviews that handle touches
/// receive interaction; taps on empty areas pass through to the window below.
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

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // If the hit view is the window itself or its root view controller's view,
        // return nil so touches pass through to the underlying window.
        if hit === self || hit === rootViewController?.view {
            return nil
        }
        return hit
    }
}

#endif
