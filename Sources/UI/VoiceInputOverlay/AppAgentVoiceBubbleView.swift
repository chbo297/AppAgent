//
//  AppAgentVoiceBubbleView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

final class AppAgentVoiceBubbleView: UIView {
    private static let tailHeight: CGFloat = 10
    private static let tailWidth: CGFloat = 14
    private static let tailCornerRadius: CGFloat = 2
    static let appearanceAnimationDuration: CFTimeInterval = 0.25
    private static let pathAnimationKey = "appagent.voiceBubble.path"
    private static let fillColorAnimationKey = "appagent.voiceBubble.fillColor"

    override class var layerClass: AnyClass {
        CAShapeLayer.self
    }

    /// 内容容器：frame 始终跟随 bodyFrame，并与气泡 path 形变使用同一节奏的动画移动。
    /// 气泡内的文字/波形等子视图应加到这里，保证形变/位移时与气泡完全同步。
    let contentView = UIView()

    private var bubbleFillColor: UIColor = .clear
    private var bubbleCornerRadius: CGFloat = 16
    private var bubbleTailXRatio: CGFloat = 0.5
    private var bubbleBodyFrame: CGRect = .zero

    private var shapeLayer: CAShapeLayer {
        layer as! CAShapeLayer
    }

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
        applyShape(animated: false, fromPath: nil, fromFillColor: nil, animatesPath: false, animatesFillColor: false)
    }

    /// 气泡的位置和大小完全由 bodyFrame（自身坐标系内的目标区域）经 path 表达，
    /// 状态切换时位置/宽高/圆角/尾巴合并成一次连续的 path 形变动画，不再跳 frame。
    func setAppearance(
        fillColor: UIColor,
        cornerRadius: CGFloat,
        tailXRatio: CGFloat,
        bodyFrame: CGRect,
        animated: Bool
    ) {
        let normalizedTailXRatio = AppAgentGeometry.clamp(tailXRatio, 0, 1)
        let nextCornerRadius = max(0, cornerRadius)
        let didChangeFillColor = !bubbleFillColor.isEqual(fillColor)
        let didChangePath = abs(bubbleCornerRadius - nextCornerRadius) > 0.25
            || abs(bubbleTailXRatio - normalizedTailXRatio) > 0.001
            || !bubbleBodyFrame.isApproximatelyEqual(to: bodyFrame)
        guard didChangeFillColor || didChangePath else { return }

        let fromPath = currentVisiblePath()
        let fromFillColor = currentVisibleFillColor()
        bubbleFillColor = fillColor
        bubbleCornerRadius = nextCornerRadius
        bubbleTailXRatio = normalizedTailXRatio
        bubbleBodyFrame = bodyFrame
        applyShape(
            animated: animated,
            fromPath: fromPath,
            fromFillColor: fromFillColor,
            animatesPath: didChangePath,
            animatesFillColor: didChangeFillColor
        )
    }

    private func setup() {
        isOpaque = false
        backgroundColor = .clear
        shapeLayer.contentsScale = UIScreen.main.scale
        shapeLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull()
        ]
        contentView.backgroundColor = .clear
        // 内容随容器裁剪：文字先于气泡形变刷新时，超出部分被裁掉，
        // 随容器 bounds 动画（与 path 同节奏）逐渐显露，避免文字"露"在气泡外。
        contentView.clipsToBounds = true
        addSubview(contentView)
        applyShape(animated: false, fromPath: nil, fromFillColor: nil, animatesPath: false, animatesFillColor: false)
    }

    private func applyShape(
        animated: Bool,
        fromPath: CGPath?,
        fromFillColor: CGColor?,
        animatesPath: Bool,
        animatesFillColor: Bool
    ) {
        guard bubbleBodyFrame.width > 0, bubbleBodyFrame.height > 0 else { return }
        let path = bubblePath(in: bubbleBodyFrame).cgPath
        let fillColor = bubbleFillColor.cgColor
        let contentLayer = contentView.layer
        let fromContentPosition = contentLayer.presentation()?.position ?? contentLayer.position
        let fromContentBounds = contentLayer.presentation()?.bounds ?? contentLayer.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = path
        shapeLayer.fillColor = fillColor
        contentView.frame = bubbleBodyFrame
        CATransaction.commit()

        guard animated else { return }

        if animatesPath, let fromPath {
            shapeLayer.add(
                Self.makeAppearanceAnimation(keyPath: "path", from: fromPath, to: path),
                forKey: Self.pathAnimationKey
            )

            // 内容容器与气泡形变同节奏移动，保证气泡内文字/波形与气泡本体同步。
            contentLayer.add(
                Self.makeAppearanceAnimation(
                    keyPath: "position",
                    from: NSValue(cgPoint: fromContentPosition),
                    to: NSValue(cgPoint: contentLayer.position)
                ),
                forKey: "appagent.voiceBubble.contentPosition"
            )
            contentLayer.add(
                Self.makeAppearanceAnimation(
                    keyPath: "bounds",
                    from: NSValue(cgRect: fromContentBounds),
                    to: NSValue(cgRect: contentLayer.bounds)
                ),
                forKey: "appagent.voiceBubble.contentBounds"
            )
        }

        if animatesFillColor, let fromFillColor {
            shapeLayer.add(
                Self.makeAppearanceAnimation(keyPath: "fillColor", from: fromFillColor, to: fillColor),
                forKey: Self.fillColorAnimationKey
            )
        }
    }

    /// 统一的形变动画工厂：气泡、内容容器、波形共用同一时长与曲线，保证整体节奏一致。
    static func makeAppearanceAnimation(keyPath: String, from fromValue: Any?, to toValue: Any?) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = fromValue
        animation.toValue = toValue
        animation.duration = appearanceAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private func currentVisiblePath() -> CGPath? {
        shapeLayer.presentation()?.path ?? shapeLayer.path
    }

    private func currentVisibleFillColor() -> CGColor? {
        shapeLayer.presentation()?.fillColor ?? shapeLayer.fillColor
    }

    private func bubblePath(in rect: CGRect) -> UIBezierPath {
        // 绘制思路：气泡主体和底部小三角使用一条连续贝塞尔路径。
        // 这样三角的两条边直接接在主体底边上，不再由两个独立 path 叠加，避免抗锯齿露出缝隙。
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(0, rect.height - Self.tailHeight)
        )
        let radius = min(bubbleCornerRadius, body.width / 2, body.height / 2)

        // 手指状态：尾巴只表达当前松手行为指向哪里；rect 可能带非零 origin，全部按绝对坐标计算。
        let tailCenterX = AppAgentGeometry.clamp(
            rect.minX + rect.width * bubbleTailXRatio,
            rect.minX + radius + Self.tailWidth / 2,
            rect.maxX - radius - Self.tailWidth / 2
        )
        let tailLeftX = tailCenterX - Self.tailWidth / 2
        let tailRightX = tailCenterX + Self.tailWidth / 2
        let tailTip = CGPoint(x: tailCenterX, y: rect.maxY)
        let tailCornerRadius = min(Self.tailCornerRadius, Self.tailHeight / 2, Self.tailWidth / 4)

        let path = UIBezierPath()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.minY + radius),
            controlPoint: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - radius, y: body.maxY),
            controlPoint: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: tailRightX, y: body.maxY))
        path.addLine(to: CGPoint(x: tailTip.x + tailCornerRadius, y: tailTip.y - tailCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: tailTip.x - tailCornerRadius, y: tailTip.y - tailCornerRadius),
            controlPoint: tailTip
        )
        path.addLine(to: CGPoint(x: tailLeftX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.maxY - radius),
            controlPoint: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + radius, y: body.minY),
            controlPoint: CGPoint(x: body.minX, y: body.minY)
        )
        path.close()
        return path
    }

}

#endif
