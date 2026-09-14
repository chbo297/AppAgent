//
//  AppAgentVoiceWaveformView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

final class AppAgentVoiceWaveformView: UIView {
    private static let heightRatios: [CGFloat] = [
        0.24, 0.32, 0.42, 0.55, 0.72, 0.88,
        0.64, 0.50, 0.36, 0.46, 0.62, 0.78,
        0.70, 0.56, 0.42, 0.35, 0.48, 0.60
    ]
    private static let pathAnimationKey = "appagent.voiceWaveform.path"
    private static let fillColorAnimationKey = "appagent.voiceWaveform.fillColor"

    override class var layerClass: AnyClass {
        CAShapeLayer.self
    }

    private var appliedBarColor: UIColor = .black
    private var appliedSize: CGSize = .zero

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
        // 布局路径直接到位（首次布局/旋转）；状态切换的过渡由 setAppearance(animated:) 驱动。
        guard !bounds.size.isApproximatelyEqual(to: appliedSize) else { return }
        appliedSize = bounds.size
        applyShape(fromPath: nil, fromFillColor: nil, animatesPath: false, animatesFillColor: false)
    }

    func setAppearance(barColor: UIColor, animated: Bool) {
        let didChangeColor = !appliedBarColor.isEqual(barColor)
        let didChangeSize = !bounds.size.isApproximatelyEqual(to: appliedSize)
        guard didChangeColor || didChangeSize else { return }

        let fromPath = shapeLayer.presentation()?.path ?? shapeLayer.path
        let fromFillColor = shapeLayer.presentation()?.fillColor ?? shapeLayer.fillColor
        appliedBarColor = barColor
        appliedSize = bounds.size
        applyShape(
            fromPath: fromPath,
            fromFillColor: fromFillColor,
            animatesPath: animated && didChangeSize,
            animatesFillColor: animated && didChangeColor
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
    }

    private func applyShape(
        fromPath: CGPath?,
        fromFillColor: CGColor?,
        animatesPath: Bool,
        animatesFillColor: Bool
    ) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = waveformPath(in: bounds).cgPath
        let fillColor = appliedBarColor.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = path
        shapeLayer.fillColor = fillColor
        CATransaction.commit()

        if animatesPath, let fromPath {
            shapeLayer.add(
                AppAgentVoiceBubbleView.makeAppearanceAnimation(keyPath: "path", from: fromPath, to: path),
                forKey: Self.pathAnimationKey
            )
        }

        if animatesFillColor, let fromFillColor {
            shapeLayer.add(
                AppAgentVoiceBubbleView.makeAppearanceAnimation(keyPath: "fillColor", from: fromFillColor, to: fillColor),
                forKey: Self.fillColorAnimationKey
            )
        }
    }

    private func waveformPath(in rect: CGRect) -> UIBezierPath {
        // 绘制思路：用一组固定比例的圆角竖条模拟语音波形，全部竖条合并进一条路径，
        // 这样尺寸切换时 path 可以整体做 CABasicAnimation 过渡。
        // 条宽与间距按 rect 宽度等比缩放（间距 : 条宽 = 1.25，与 78pt 宽度下 2.5/2 的原始观感一致），
        // 这样迷你尺寸（如取消态 32pt 宽）下竖条也不会溢出。
        let count = CGFloat(Self.heightRatios.count)
        let spacingRatio: CGFloat = 1.25
        let barWidth = max(0.5, rect.width / (count + (count - 1) * spacingRatio))
        let spacing = barWidth * spacingRatio
        let maxHeight = rect.height
        let path = UIBezierPath()

        // 逐根计算 x/y/height，让每根竖条在 Y 轴居中。
        // 使用圆角矩形并把圆角设为 barWidth / 2，让每根条两端都是圆头。
        for (index, ratio) in Self.heightRatios.enumerated() {
            let height = max(2, maxHeight * ratio)
            let x = CGFloat(index) * (barWidth + spacing)
            let y = (rect.height - height) / 2
            let barRect = CGRect(x: x, y: y, width: barWidth, height: height)
            path.append(UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2))
        }
        return path
    }
}

#endif
