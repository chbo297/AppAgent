//
//  AppAgentVoiceArcMetrics.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 语音输入浮层里 bottom 圆弧与取消/编辑按钮圆环共用的几何定义。
enum AppAgentVoiceArcMetrics {
    /// 一条左右对称、顶部拱起的圆弧几何信息。
    struct SymmetricTopArc {
        let center: CGPoint
        let radius: CGFloat
        let startAngle: CGFloat
        let endAngle: CGFloat
    }

    /// bottom 顶部最高点到左右两侧圆弧端点的 Y 轴距离。
    static let bottomArcSideYOffset: CGFloat = 40

    /// bottom 顶部参考圆弧到取消/编辑按钮底部圆弧之间的径向间距。
    static let actionLowerArcSpacingFromBottomArc: CGFloat = 20

    /// 取消/编辑按钮圆环上下两条边之间的径向距离，也就是按钮圆环厚度。
    static let actionRingThickness: CGFloat = 68

    /// 取消按钮右侧、编辑按钮左侧相对中心线预留的绘制间距。
    static let actionCenterGap: CGFloat = 17

    /// 取消/编辑按钮相对 bottom 顶部最高点需要向上预留的高度。
    static var actionTopExpansionFromBottomApex: CGFloat {
        actionLowerArcSpacingFromBottomArc + actionRingThickness
    }

    /// 取消/编辑按钮相对 bottom 顶部最高点需要覆盖到两侧圆弧端点的高度。
    static var actionZoneHeight: CGFloat {
        actionTopExpansionFromBottomApex + bottomArcSideYOffset
    }

    /// 按给定左右端点和顶部最高点计算圆弧；左右端点的 y 会比 apexY 低 bottomArcSideYOffset。
    static func symmetricTopArc(minX: CGFloat, maxX: CGFloat, apexY: CGFloat) -> SymmetricTopArc {
        let halfChord = max(0.5, (maxX - minX) / 2)
        let sideYOffset = bottomArcSideYOffset
        let radius = ((halfChord * halfChord) + (sideYOffset * sideYOffset)) / (2 * sideYOffset)
        let center = CGPoint(x: (minX + maxX) / 2, y: apexY + radius)
        let startPoint = CGPoint(x: minX, y: apexY + sideYOffset)
        let endPoint = CGPoint(x: maxX, y: apexY + sideYOffset)

        return SymmetricTopArc(
            center: center,
            radius: radius,
            startAngle: atan2(startPoint.y - center.y, startPoint.x - center.x),
            endAngle: atan2(endPoint.y - center.y, endPoint.x - center.x)
        )
    }
}

#endif
