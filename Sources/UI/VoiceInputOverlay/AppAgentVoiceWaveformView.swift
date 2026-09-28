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
    private static let wavingAnimationKey = "appagent.voiceWaveform.waving"
    /// 波浪动画一整轮的时长：竖条高度比例整体循环平移一遍所需的秒数。
    private static let wavingDuration: TimeInterval = 1.5
    /// 音频驱动态：静音时的最小竖条比例，与说话时的最大比例。声音大小在两者之间映射。
    private static let audioIdleRatio: CGFloat = 0.08
    private static let audioMaxRatio: CGFloat = 1.0
    /// 音量→高度的对比拉伸指数（<1）：语音音量多聚在中低段，开方式抬升让竖条高低差更明显。指数越小起伏越大。
    private static let audioEmphasisExponent: CGFloat = 0.35
    /// 音量增益：拉伸后再乘一档增益并夹到上限，让偏大的音量顶到满格、放大整体摆动幅度。
    private static let audioLevelGain: CGFloat = 1.35
    /// 每来一个音量样本，竖条滑动到新高度的过渡时长（略长于采样间隔，衔接更顺滑）。
    private static let audioGlideDuration: TimeInterval = 0.12

    /// 波形的驱动方式：静态固定竖条 / 循环波浪动画（收尾态）/ 实时音量驱动（录音态）。
    /// 三者互斥，切换由 `setMode` 统一收口，避免不同来源同时写 path 打架。
    enum Mode {
        case idle
        case waving
        case audioReactive
    }

    override class var layerClass: AnyClass {
        CAShapeLayer.self
    }

    private var appliedBarColor: UIColor = .black
    private var appliedSize: CGSize = .zero
    private var mode: Mode = .idle
    /// 音频驱动态下的滚动竖条比例（新样本从右侧进入、旧样本左移出队）；其余模式为 nil。
    private var dynamicRatios: [CGFloat]?

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
        // 尺寸变了，波浪关键帧里的 path 也要按新 bounds 重算。
        if mode == .waving {
            startWavingAnimation()
        }
    }

    /// 切换波形驱动方式（幂等）。收尾态用循环波浪动画，录音态用实时音量驱动，其余静态。
    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        // 拆除上一模式的残留动画/状态。
        switch mode {
        case .waving:
            stopWavingAnimation()
        case .audioReactive:
            shapeLayer.removeAnimation(forKey: Self.pathAnimationKey)
            dynamicRatios = nil
        case .idle:
            break
        }

        mode = newMode
        switch newMode {
        case .idle:
            applyShape(fromPath: nil, fromFillColor: nil, animatesPath: false, animatesFillColor: false)
        case .waving:
            applyShape(fromPath: nil, fromFillColor: nil, animatesPath: false, animatesFillColor: false)
            startWavingAnimation()
        case .audioReactive:
            dynamicRatios = Array(repeating: Self.audioIdleRatio, count: Self.heightRatios.count)
            renderDynamicPath(animated: false)
        }
    }

    /// 录音态：把一帧实时音量（0…1）喂进来，竖条左移滚动 + 新样本入队，反映声音随时间变化。
    /// 只在音频驱动态生效；非该模式的调用直接忽略。
    func pushAudioLevel(_ level: CGFloat) {
        guard mode == .audioReactive, dynamicRatios != nil else { return }
        let clamped = min(1, max(0, level))
        // 对比拉伸 + 增益：开方抬升中低段、再乘增益并夹到上限，放大竖条高低差与整体摆动。
        let emphasized = min(1, pow(clamped, Self.audioEmphasisExponent) * Self.audioLevelGain)
        let ratio = Self.audioIdleRatio + emphasized * (Self.audioMaxRatio - Self.audioIdleRatio)
        dynamicRatios?.removeFirst()
        dynamicRatios?.append(ratio)
        renderDynamicPath(animated: true)
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
        waveformPath(in: rect, phase: 0)
    }

    private func waveformPath(in rect: CGRect, phase: Int) -> UIBezierPath {
        // 绘制思路：用一组固定比例的圆角竖条模拟语音波形，全部竖条合并进一条路径，
        // 这样尺寸切换时 path 可以整体做 CABasicAnimation 过渡。
        // 条宽与间距按 rect 宽度等比缩放（间距 : 条宽 = 1.25，与 78pt 宽度下 2.5/2 的原始观感一致），
        // 这样迷你尺寸（如取消态 32pt 宽）下竖条也不会溢出。
        // phase 是波浪动画的相位：把高度比例整体“旋转”若干格，形成竖条高低平移的行进波。
        // 录音态下 ratios 换成实时音量滚动数组（dynamicRatios），phase 恒为 0。
        let ratios = dynamicRatios ?? Self.heightRatios
        let count = CGFloat(ratios.count)
        let spacingRatio: CGFloat = 1.25
        let barWidth = max(0.5, rect.width / (count + (count - 1) * spacingRatio))
        let spacing = barWidth * spacingRatio
        let maxHeight = rect.height
        let path = UIBezierPath()

        // 逐根计算 x/y/height，让每根竖条在 Y 轴居中。
        // 使用圆角矩形并把圆角设为 barWidth / 2，让每根条两端都是圆头。
        for index in ratios.indices {
            let ratio = ratios[(index + phase) % ratios.count]
            let height = max(2, maxHeight * ratio)
            let x = CGFloat(index) * (barWidth + spacing)
            let y = (rect.height - height) / 2
            let barRect = CGRect(x: x, y: y, width: barWidth, height: height)
            path.append(UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2))
        }
        return path
    }

    /// 音频驱动态刷新 path：把当前滚动竖条画上去，并从当前呈现态短暂 glide 到新形状，
    /// 让相邻音量样本之间平滑衔接。只改 path、单层、无布局，性能开销极小。
    private func renderDynamicPath(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = waveformPath(in: bounds, phase: 0).cgPath
        let fromPath = shapeLayer.presentation()?.path ?? shapeLayer.path

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.path = path
        CATransaction.commit()

        guard animated, let fromPath else { return }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = fromPath
        animation.toValue = path
        animation.duration = Self.audioGlideDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shapeLayer.add(animation, forKey: Self.pathAnimationKey)
    }

    private func startWavingAnimation() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // 依次“旋转”高度比例得到一整轮 path 关键帧，末帧回到首帧，循环时无缝衔接。
        var values: [CGPath] = []
        values.reserveCapacity(Self.heightRatios.count + 1)
        for phase in 0...Self.heightRatios.count {
            values.append(waveformPath(in: bounds, phase: phase).cgPath)
        }

        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = values
        animation.duration = Self.wavingDuration
        animation.calculationMode = .linear
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        shapeLayer.add(animation, forKey: Self.wavingAnimationKey)
    }

    private func stopWavingAnimation() {
        shapeLayer.removeAnimation(forKey: Self.wavingAnimationKey)
    }
}

#endif
