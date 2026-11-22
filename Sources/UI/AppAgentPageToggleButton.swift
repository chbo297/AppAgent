//
//  AppAgentPageToggleButton.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 展开 / 收起宿主配套页面的按钮。对话面板顶栏和宿主页面左上角用同一个控件，两处长得一样。
///
/// 图形是一个小窗口：上半格代表配套页面。展开时上格占大半并着强调色，收起时折成顶端一条细线，
/// 细线仍是强调色，提示「这里还有页面可以打开」。状态切换时上格高度带弹簧动画，读屏模式与
/// 「减弱动态效果」下直接切换。
public final class AppAgentPageToggleButton: UIControl {

    public enum Style {
        /// 放在对话面板顶栏里，与旁边的圆形按钮同底色。
        case bar
        /// 浮在页面或地图之上，用毛玻璃底保证在任何背景上都看得清。
        case floating
    }

    /// 读屏名称，例如「工作区页面」；状态与动作由控件拼成「已展开，轻点收起」。
    public var accessibilityName: String = "页面" {
        didSet {
            updateAccessibility()
        }
    }

    public private(set) var isExpanded = false

    public static let visualSize: CGFloat = 36

    private let style: Style
    private let backgroundView: UIView
    private let frameView = UIView()
    private let paneView = UIView()

    private static let glyphSize = CGSize(width: 18, height: 15)
    private static let glyphInset: CGFloat = 2.6
    private static let collapsedPaneHeight: CGFloat = 2.2

    public init(style: Style) {
        self.style = style
        switch style {
        case .bar:
            backgroundView = UIView()
        case .floating:
            backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        }
        super.init(frame: CGRect(x: 0, y: 0, width: Self.visualSize, height: Self.visualSize))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// 切换展开状态。animated 为 true 时上格高度带弹簧动画。
    public func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else {
            return
        }
        isExpanded = expanded
        updateAccessibility()
        let changes = {
            self.applyColors()
            self.layoutGlyph()
        }
        if animated, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.72,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: changes)
        } else {
            changes()
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: Self.visualSize, height: Self.visualSize)
    }

    public override var isHighlighted: Bool {
        didSet {
            // 按下时整体缩一点。两个子视图都用 bounds + center 排版，所以 transform 不会打乱布局。
            let transform: CGAffineTransform = isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.backgroundView.transform = transform
                self.frameView.transform = transform
            }
        }
    }

    /// 视觉 36pt，点按区域放大到 44pt。
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = min(0, (bounds.width - 44) / 2)
        let dy = min(0, (bounds.height - 44) / 2)
        return bounds.insetBy(dx: dx, dy: dy).contains(point)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        backgroundView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        backgroundView.center = center
        backgroundView.layer.cornerRadius = side / 2
        frameView.bounds = CGRect(origin: .zero, size: Self.glyphSize)
        frameView.center = center
        layoutGlyph()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func setup() {
        backgroundView.isUserInteractionEnabled = false
        backgroundView.clipsToBounds = true
        addSubview(backgroundView)

        frameView.isUserInteractionEnabled = false
        frameView.layer.cornerRadius = 3.5
        frameView.layer.borderWidth = 1.6
        frameView.layer.cornerCurve = .continuous
        addSubview(frameView)

        paneView.isUserInteractionEnabled = false
        paneView.layer.cornerRadius = 1.4
        paneView.layer.cornerCurve = .continuous
        frameView.addSubview(paneView)

        isAccessibilityElement = true
        accessibilityTraits = .button
        applyColors()
        updateAccessibility()
    }

    private func layoutGlyph() {
        let inset = Self.glyphInset
        let innerWidth = Self.glyphSize.width - inset * 2
        let innerHeight = Self.glyphSize.height - inset * 2
        let height = isExpanded ? (innerHeight * 0.58).rounded() : Self.collapsedPaneHeight
        paneView.frame = CGRect(x: inset, y: inset, width: innerWidth, height: height)
    }

    private func applyColors() {
        let accent = AppAgentAppearance.accent
        switch style {
        case .bar:
            backgroundView.backgroundColor = isExpanded
                ? accent.withAlphaComponent(0.14)
                : AppAgentAppearance.voicePressedBackground
        case .floating:
            backgroundView.layer.borderWidth = 1 / max(UIScreen.main.scale, 1)
            backgroundView.layer.borderColor = AppAgentAppearance.inputBarBorder.resolvedColor(with: traitCollection).cgColor
        }
        let stroke = isExpanded ? accent : AppAgentAppearance.icon
        frameView.layer.borderColor = stroke.resolvedColor(with: traitCollection).cgColor
        paneView.backgroundColor = accent
    }

    private func updateAccessibility() {
        accessibilityLabel = accessibilityName
        accessibilityValue = isExpanded ? "已展开" : "已收起"
        accessibilityHint = isExpanded ? "轻点收起" : "轻点展开"
    }
}

#endif
