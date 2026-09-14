//
//  AppAgentGeometry.swift
//  AppAgentUI
//

#if canImport(UIKit)
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

extension CGPoint {
    /// 两点近似相等（容差 0.5pt），用于避免亚像素抖动触发无意义的布局。
    func isApproximatelyEqual(to other: CGPoint) -> Bool {
        abs(x - other.x) <= 0.5
            && abs(y - other.y) <= 0.5
    }

    /// 两点欧氏距离。
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension CGSize {
    func isApproximatelyEqual(to other: CGSize) -> Bool {
        abs(width - other.width) <= 0.5
            && abs(height - other.height) <= 0.5
    }
}

extension CGRect {
    func isApproximatelyEqual(to other: CGRect) -> Bool {
        abs(minX - other.minX) <= 0.5
            && abs(minY - other.minY) <= 0.5
            && abs(width - other.width) <= 0.5
            && abs(height - other.height) <= 0.5
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension UIEdgeInsets {
    func isApproximatelyEqual(to other: UIEdgeInsets) -> Bool {
        abs(top - other.top) <= 0.5
            && abs(left - other.left) <= 0.5
            && abs(bottom - other.bottom) <= 0.5
            && abs(right - other.right) <= 0.5
    }
}

#endif
