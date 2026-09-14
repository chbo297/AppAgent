//
//  AppAgentVoiceBottomPanelView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

final class AppAgentVoiceBottomPanelView: UIView {
    private static let topHitExpansion: CGFloat = 8
    private static let selectionAnimationDuration: TimeInterval = 0.12
    private static let normalVerticalOffset: CGFloat = 10
    private static let selectedFillColor = UIColor(red: 0.84, green: 0.85, blue: 0.84, alpha: 1)
    private static let selectedGradientEndColor = UIColor(red: 0.46, green: 0.47, blue: 0.46, alpha: 1)
    private static let normalFillColor = UIColor(red: 0.30, green: 0.30, blue: 0.29, alpha: 1)
    private static let selectedPromptColor = UIColor.black.withAlphaComponent(0.82)
    private static let normalPromptColor = UIColor.white.withAlphaComponent(0.82)
    private static let selectedPromptText = "松开 发送"
    private static let normalPromptText = "语音"

    private let selectedBackgroundView = AppAgentVoiceBottomPanelSelectionBackgroundView(
        startColor: AppAgentVoiceBottomPanelView.selectedFillColor,
        endColor: AppAgentVoiceBottomPanelView.selectedGradientEndColor
    )
    private let normalPromptLabel = UILabel()
    private let selectedPromptLabel = UILabel()
    private var isPanelSelected = false
    private var cachedPanelBounds: CGRect = .null
    private var cachedPanelPath: UIBezierPath?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setSelected(_ selected: Bool) {
        guard isPanelSelected != selected else { return }
        isPanelSelected = selected
        updateAppearance(animated: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if cachedPanelBounds != bounds {
            invalidatePanelPathCache()
        }
        let promptFrame = CGRect(
            x: 0,
            y: 4,
            width: bounds.width,
            height: 36
        )
        selectedBackgroundView.frame = bounds
        normalPromptLabel.frame = promptFrame
        selectedPromptLabel.frame = promptFrame
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        Self.normalFillColor.setFill()
        cachedPanelPath(for: bounds).fill()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let panelPath = cachedPanelPath(for: bounds)
        if panelPath.contains(point) {
            return true
        }

        // 手指判定：允许手指在底部面板弧线上方 8pt 内也算进入发送区域；
        // 这里保留原始路径判断，再额外判断上扩区域，避免把面板底部 8pt 误排除。
        let topExpandedPoint = CGPoint(x: point.x, y: point.y + Self.topHitExpansion)
        return panelPath.contains(topExpandedPoint)
    }

    private func setup() {
        backgroundColor = .clear
        contentMode = .redraw
        setupPromptLabel(normalPromptLabel, text: Self.normalPromptText, textColor: Self.normalPromptColor)
        setupPromptLabel(selectedPromptLabel, text: Self.selectedPromptText, textColor: Self.selectedPromptColor)
        addSubview(normalPromptLabel)
        addSubview(selectedBackgroundView)
        addSubview(selectedPromptLabel)
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let updates = {
            self.transform = self.isPanelSelected
                ? .identity
                : CGAffineTransform(translationX: 0, y: Self.normalVerticalOffset)
            self.selectedBackgroundView.alpha = self.isPanelSelected ? 1 : 0
            self.selectedPromptLabel.alpha = self.isPanelSelected ? 1 : 0
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

    private func setupPromptLabel(_ label: UILabel, text: String, textColor: UIColor) {
        label.text = text
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = textColor
    }

    private func invalidatePanelPathCache() {
        cachedPanelBounds = .null
        cachedPanelPath = nil
        setNeedsDisplay()
    }

    private func cachedPanelPath(for rect: CGRect) -> UIBezierPath {
        if cachedPanelBounds == rect, let cachedPanelPath {
            return cachedPanelPath
        }

        // draw(_:) 首次绘制或尺寸变化后生成路径并缓存；
        // point(inside:with:) 高频命中测试直接复用这条路径，避免拖拽过程中重复构造贝塞尔曲线。
        let path = AppAgentVoiceBottomPanelPathFactory.makePanelPath(in: rect)
        cachedPanelBounds = rect
        cachedPanelPath = path
        return path
    }
}

private final class AppAgentVoiceBottomPanelSelectionBackgroundView: UIView {
    private let startColor: UIColor
    private let endColor: UIColor
    private var cachedPanelBounds: CGRect = .null
    private var cachedPanelPath: UIBezierPath?

    init(startColor: UIColor, endColor: UIColor) {
        self.startColor = startColor
        self.endColor = endColor
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.startColor = .clear
        self.endColor = .clear
        super.init(coder: coder)
        setup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if cachedPanelBounds != bounds {
            invalidatePanelPathCache()
        }
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        drawSelectionGradient(in: bounds)
    }

    private func setup() {
        alpha = 0
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    private func invalidatePanelPathCache() {
        cachedPanelBounds = .null
        cachedPanelPath = nil
        setNeedsDisplay()
    }

    private func cachedPanelPath(for rect: CGRect) -> UIBezierPath {
        if cachedPanelBounds == rect, let cachedPanelPath {
            return cachedPanelPath
        }

        let path = AppAgentVoiceBottomPanelPathFactory.makePanelPath(in: rect)
        cachedPanelBounds = rect
        cachedPanelPath = path
        return path
    }

    private func drawSelectionGradient(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let path = cachedPanelPath(for: rect)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [startColor.cgColor, endColor.cgColor] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, 1]
        ) else {
            startColor.setFill()
            path.fill()
            return
        }

        // 绘制思路：先裁剪到 bottom 的贝塞尔形状，保证渐变不会溢出面板边缘。
        // 线性渐变从底部的选中浅色向上方暗灰色过渡；
        // 终点放在距离底部 4 倍 bottom 高度的位置，让面板可见区域里的渐变变化更柔和。
        context.saveGState()
        path.addClip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 4),
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}

private enum AppAgentVoiceBottomPanelPathFactory {
    static func makePanelPath(in rect: CGRect) -> UIBezierPath {
        // 绘制思路：底部面板是一个从屏幕底部向上露出的不透明区域。
        // 顶部弧线用三点确定一个圆：左侧点、右侧点、中间最高点。
        // 中间最高点贴住 bounds.minY，左右两侧点比最高点低 AppAgentVoiceArcMetrics.bottomArcSideYOffset。
        // 未选中态不改贝塞尔曲线本身，而是用 transform 将整个面板向下移动 10pt。
        let arc = AppAgentVoiceArcMetrics.symmetricTopArc(
            minX: rect.minX,
            maxX: rect.maxX,
            apexY: rect.minY
        )

        // 路径顺序：左下角 -> 左侧弧线起点 -> 圆弧到右侧起点 -> 右下角 -> 闭合。
        // draw(_:) 和 point(inside:with:) 共用缓存路径，保证“显示出来的区域”和“发送判定区域”一致。
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(
            x: rect.minX,
            y: rect.minY + AppAgentVoiceArcMetrics.bottomArcSideYOffset
        ))
        path.addArc(
            withCenter: arc.center,
            radius: arc.radius,
            startAngle: arc.startAngle,
            endAngle: arc.endAngle,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }
}

#endif
