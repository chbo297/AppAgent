//
//  AppAgentVoiceActionZoneView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

final class AppAgentVoiceActionZoneView: UIView {
    private static let selectionAnimationDuration: TimeInterval = 0.2
    private static let selectedScale: CGFloat = 1.1
    private static let hintLabelOffsetFromOuterArc: CGFloat = 18

    enum Side {
        case left
        case right
    }

    private struct LabelLayout {
        let center: CGPoint
        let rotationAngle: CGFloat
    }

    private struct ActionArcGeometry {
        let center: CGPoint
        let radius: CGFloat
        let strokeWidth: CGFloat
        let startAngle: CGFloat
        let endAngle: CGFloat
    }

    private struct ActionLayout {
        let path: UIBezierPath
        let titleLabelLayout: LabelLayout
        let hintLabelLayout: LabelLayout
    }

    var fillColor: UIColor = .clear {
        didSet {
            guard !fillColor.isEqual(oldValue) else { return }
            setNeedsDisplay()
        }
    }

    private let side: Side
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private var cachedActionBounds: CGRect = .null
    private var cachedActionLayout: ActionLayout?
    private var isActionSelected = false

    init(side: Side, title: String, selectedHint: String) {
        self.side = side
        super.init(frame: .zero)
        setup(title: title, selectedHint: selectedHint)
    }

    required init?(coder: NSCoder) {
        side = .left
        super.init(coder: coder)
        setup(title: "", selectedHint: "")
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()

        // 绘制思路：取消和编辑按钮共用一套左侧弧形路径。
        // 右侧按钮不单独写一套坐标，而是把当前绘图上下文水平镜像，保证两侧形状对称。
        if side == .right {
            context.translateBy(x: bounds.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }

        // 按钮视觉是一个闭合填充区域：中心线是一条与 bottom 顶部同心的圆弧，
        // 再按圆环厚度扩成带圆头的闭合 path。这样上下边平行，内侧端天然是半圆。
        fillColor.setFill()
        cachedActionLayout(for: bounds).path.fill()
        context.restoreGState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if cachedActionBounds != bounds {
            invalidateActionPathCache()
        }
        layoutLabels()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let testPoint: CGPoint
        switch side {
        case .left:
            testPoint = point
        case .right:
            testPoint = CGPoint(x: bounds.width - point.x, y: point.y)
        }
        return cachedActionLayout(for: bounds).path.contains(testPoint)
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard isActionSelected != selected else { return }
        isActionSelected = selected

        let updates = {
            self.transform = selected
                ? CGAffineTransform(scaleX: Self.selectedScale, y: Self.selectedScale)
                : .identity
            self.hintLabel.alpha = selected ? 1 : 0
        }

        guard animated else {
            updates()
            return
        }

        UIView.animate(
            withDuration: Self.selectionAnimationDuration,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
            animations: updates
        )
    }

    func setTitleColor(_ color: UIColor) {
        titleLabel.textColor = color
    }

    private func setup(title: String, selectedHint: String) {
        isOpaque = false
        clipsToBounds = false
        contentMode = .redraw

        titleLabel.text = title
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        addSubview(titleLabel)

        hintLabel.text = selectedHint
        hintLabel.textAlignment = .center
        hintLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.70)
        hintLabel.alpha = 0
        addSubview(hintLabel)
    }

    private func layoutLabels() {
        titleLabel.transform = .identity
        hintLabel.transform = .identity
        let layout = cachedActionLayout(for: bounds)
        let widthRatio: CGFloat = side == .left ? 0.68 : 0.72
        let maxWidth: CGFloat = side == .left ? 180 : 260
        titleLabel.bounds = CGRect(
            x: 0,
            y: 0,
            width: min(maxWidth, bounds.width * widthRatio),
            height: 40
        )
        titleLabel.center = layout.titleLabelLayout.center
        titleLabel.transform = CGAffineTransform(rotationAngle: layout.titleLabelLayout.rotationAngle)

        let hintMaxWidth: CGFloat = side == .left ? 180 : 260
        hintLabel.bounds = CGRect(
            x: 0,
            y: 0,
            width: min(hintMaxWidth, max(0, bounds.width * 0.9)),
            height: 28
        )
        hintLabel.center = layout.hintLabelLayout.center
        hintLabel.transform = CGAffineTransform(rotationAngle: layout.hintLabelLayout.rotationAngle)
    }

    private func invalidateActionPathCache() {
        cachedActionBounds = .null
        cachedActionLayout = nil
        setNeedsDisplay()
    }

    private func cachedActionLayout(for rect: CGRect) -> ActionLayout {
        if cachedActionBounds == rect, let cachedActionLayout {
            return cachedActionLayout
        }

        // draw(_:)、point(inside:with:) 和 titleLabel 布局复用同一份几何计算；
        // 手势移动时只做 contains 判断，不重复计算圆心、半径、stroking path 和文字位置。
        let geometry = actionArcGeometry(in: rect)
        let path = makeActionPath(in: rect, geometry: geometry)
        let labelLayouts = makeLabelLayouts(in: rect, geometry: geometry, path: path)
        let layout = ActionLayout(
            path: path,
            titleLabelLayout: labelLayouts.title,
            hintLabelLayout: labelLayouts.hint
        )
        cachedActionBounds = rect
        cachedActionLayout = layout
        return layout
    }

    private func makeActionPath(in rect: CGRect, geometry: ActionArcGeometry) -> UIBezierPath {
        // 第一步：只画按钮圆环的中心线。
        // 中心线半径 = bottom 顶部圆弧半径 + 20pt 间距 + 半个圆环厚度。
        let centerlinePath = UIBezierPath()
        centerlinePath.addArc(
            withCenter: geometry.center,
            radius: geometry.radius,
            startAngle: geometry.startAngle,
            endAngle: geometry.endAngle,
            clockwise: true
        )

        // 第二步：把中心线按统一圆环厚度扩成闭合填充路径。
        // lineCap 使用 round，让取消按钮右侧、编辑按钮左侧形成半圆端。
        let strokedPath = centerlinePath.cgPath.copy(
            strokingWithWidth: geometry.strokeWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return UIBezierPath(cgPath: strokedPath)
    }

    private func makeLabelLayouts(
        in rect: CGRect,
        geometry: ActionArcGeometry,
        path: UIBezierPath
    ) -> (title: LabelLayout, hint: LabelLayout) {
        guard rect.width > 0, rect.height > 0 else {
            let fallback = LabelLayout(
                center: CGPoint(x: rect.midX, y: rect.midY),
                rotationAngle: 0
            )
            return (fallback, fallback)
        }

        let leftLayouts = leftLabelLayouts(in: rect, geometry: geometry, path: path)
        switch side {
        case .left:
            return leftLayouts
        case .right:
            return (
                mirrorLabelLayout(leftLayouts.title, in: rect),
                mirrorLabelLayout(leftLayouts.hint, in: rect)
            )
        }
    }

    private func actionArcGeometry(in rect: CGRect) -> ActionArcGeometry {
        let strokeWidth = min(AppAgentVoiceArcMetrics.actionRingThickness, rect.height)
        let bottomArcApexY = rect.minY + AppAgentVoiceArcMetrics.actionTopExpansionFromBottomApex
        let virtualFullWidth = (rect.width + AppAgentVoiceArcMetrics.actionCenterGap) * 2
        let bottomArc = AppAgentVoiceArcMetrics.symmetricTopArc(
            minX: rect.minX,
            maxX: rect.minX + virtualFullWidth,
            apexY: bottomArcApexY
        )
        let strokeRadius = bottomArc.radius
            + AppAgentVoiceArcMetrics.actionLowerArcSpacingFromBottomArc
            + strokeWidth / 2
        let endAngle = Self.endAngleKeepingRoundedCapInside(
            arcCenterX: bottomArc.center.x,
            rightEdgeX: rect.maxX,
            radius: strokeRadius,
            capRadius: strokeWidth / 2
        )

        return ActionArcGeometry(
            center: bottomArc.center,
            radius: strokeRadius,
            strokeWidth: strokeWidth,
            startAngle: bottomArc.startAngle,
            endAngle: endAngle
        )
    }

    private func leftLabelLayouts(
        in rect: CGRect,
        geometry: ActionArcGeometry,
        path: UIBezierPath
    ) -> (title: LabelLayout, hint: LabelLayout) {
        // 文字视觉居中不能直接使用 frame.midX：按钮右侧有圆头和中间留白，
        // 实际绘制出来的可见区域会比 frame 更窄，所以先取 path 和当前 bounds 的交集。
        let visiblePathBounds = path.bounds.intersection(rect)
        let referenceBounds: CGRect
        if visiblePathBounds.isNull || visiblePathBounds.width <= 0 || visiblePathBounds.height <= 0 {
            referenceBounds = rect
        } else {
            referenceBounds = visiblePathBounds
        }

        let capRadius = geometry.strokeWidth / 2
        let labelInset = min(capRadius, rect.width / 2)
        let targetX = AppAgentGeometry.clamp(referenceBounds.midX, rect.minX + labelInset, rect.maxX - labelInset)
        let dx = AppAgentGeometry.clamp(targetX - geometry.center.x, -geometry.radius, geometry.radius)
        let y = geometry.center.y - sqrt(max(0, geometry.radius * geometry.radius - dx * dx))
        let angle = atan2(y - geometry.center.y, dx)

        // 文字中心放在按钮中心圆弧上，旋转角取该点圆弧切线方向。
        let titleLayout = LabelLayout(
            center: CGPoint(x: geometry.center.x + dx, y: y),
            rotationAngle: angle + CGFloat.pi / 2
        )

        // 松手提示放在按钮上弧外侧：沿同一条半径向外移动，旋转角继续使用切线方向，
        // 因此提示文字会和按钮内部文字保持平行；label 本身允许超出按钮 bounds 显示。
        let hintRadius = geometry.radius
            + geometry.strokeWidth / 2
            + Self.hintLabelOffsetFromOuterArc
        let hintLayout = LabelLayout(
            center: CGPoint(
                x: geometry.center.x + cos(angle) * hintRadius,
                y: geometry.center.y + sin(angle) * hintRadius
            ),
            rotationAngle: titleLayout.rotationAngle
        )

        return (titleLayout, hintLayout)
    }

    private func mirrorLabelLayout(_ layout: LabelLayout, in rect: CGRect) -> LabelLayout {
        LabelLayout(
            center: CGPoint(x: rect.width - layout.center.x, y: layout.center.y),
            rotationAngle: -layout.rotationAngle
        )
    }

    private static func endAngleKeepingRoundedCapInside(
        arcCenterX: CGFloat,
        rightEdgeX: CGFloat,
        radius: CGFloat,
        capRadius: CGFloat
    ) -> CGFloat {
        // 圆头半径等于线宽一半；线心提前半个线宽，圆头最右侧刚好贴住 frame 右边。
        let targetDX = max(-radius, min(0, rightEdgeX - capRadius - arcCenterX))
        let targetDY = -sqrt(max(0, radius * radius - targetDX * targetDX))
        return atan2(targetDY, targetDX)
    }
}

#endif
