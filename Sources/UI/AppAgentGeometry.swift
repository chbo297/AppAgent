//
//  AppAgentGeometry.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

/// UI 模块共享的几何小工具：统一 clamp 与近似相等判断，避免各视图各自实现。
enum AppAgentGeometry {
    /// 数值截断到 [lower, upper]；区间无效（upper < lower）时返回 lower。
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(upper, max(lower, value))
    }

    /// 可调强度的 ease-out；最小合法系数对应线性，系数越大则起始变化越快、接近终点时越缓。
    /// 输入和输出均归一化；无效系数回退为线性，避免产生 NaN 或反向曲线。
    static func easeOut(_ value: CGFloat, coefficient: CGFloat) -> CGFloat {
        let progress = clamp(value, 0, 1)
        let normalizedCoefficient = coefficient.isFinite ? max(1, coefficient) : 1
        let remaining = 1 - progress
        return 1 - pow(remaining, normalizedCoefficient)
    }
}

/// 输入栏几何常量：纯数值、与线程无关。
///
/// 这些数既被 `@MainActor` 的视图用（`AppAgentInputBar` 是 UIView，Swift 6 下整类都在主 actor 上），
/// 也被 `AppAgentInputBarFramePolicy` / `AppAgentChatPanelGeometry` 这种纯函数几何层用 —— 后者刻意
/// 不带隔离，好让布局推导能在单测里直接调。常量原先挂在视图类的 static 上，于是每个 nonisolated
/// 读点都被编译器点名一次（实测 40 处 warning）。数值本身没有主线程语义，归属就该在这里：
/// 一份真相，两边都读得到。
public enum AppAgentInputBarMetrics {
    /// 胶囊条默认高度。
    public static let barHeight: CGFloat = 56

    public static let innerPadding: CGFloat = 8
    public static let buttonSize: CGFloat = 40
    public static let minimumInputAreaWidth: CGFloat = 80

    /// 完全收起宽度：8 + 40 + 8。
    public static let collapsedMinWidth: CGFloat = innerPadding * 2 + buttonSize

    /// 最小展开宽度：8 + 40 + 8 + 80 + 8 + 40 + 8 + 40 + 8。
    public static let minimumExpandedWidth: CGFloat = innerPadding * 5 + buttonSize * 3 + minimumInputAreaWidth

    /// 展开态 inputBar 背景圆角；ChatPanel 收至最小高度时复用该值以保持视觉对齐。
    public static let expandedCornerRadius: CGFloat = 16
}

/// 面板几何常量：同理，纯数值不该挂在 @MainActor 的视图类上。
public enum AppAgentChatPanelMetrics {
    /// 面板导航条高度。
    public static let navigationBarHeight: CGFloat = 48
}

extension CGPoint {
    /// 两点近似相等（容差 0.5pt），用于避免亚像素抖动触发无意义的布局。
    func isApproximatelyEqual(to other: CGPoint) -> Bool {
        bo_isApproximatelyEqual(to: other)
    }

    /// 两点欧氏距离。
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension CGSize {
    func isApproximatelyEqual(to other: CGSize) -> Bool {
        bo_isApproximatelyEqual(to: other)
    }
}

extension CGRect {
    func isApproximatelyEqual(to other: CGRect) -> Bool {
        bo_isApproximatelyEqual(to: other)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension UIEdgeInsets {
    func isApproximatelyEqual(to other: UIEdgeInsets) -> Bool {
        bo_isApproximatelyEqual(to: other)
    }
}

#endif
