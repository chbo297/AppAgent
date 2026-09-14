//
//  AppAgentMenuButton.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// Circular menu button used by `AppAgentInputBar`.
public final class AppAgentMenuButton: UIButton {

    public static let iconSide: CGFloat = 24
    private let borderWidth: CGFloat = 4

    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        accessibilityLabel = "Menu"
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: Self.iconSide, height: Self.iconSide)
    }

    public override var isEnabled: Bool {
        didSet { setNeedsDisplay() }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        let side = min(Self.iconSide, min(bounds.width, bounds.height))
        let origin = CGPoint(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2
        )
        let circleBounds = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let half = borderWidth / 2
        let circleRect = circleBounds.insetBy(dx: half, dy: half)
        let path = UIBezierPath(ovalIn: circleRect)
        let alpha: CGFloat = isEnabled ? 1 : 0.35
        AppAgentAppearance.menuFill.withAlphaComponent(alpha).setFill()
        path.fill()
        AppAgentAppearance.menuStroke.withAlphaComponent(alpha).setStroke()
        path.lineWidth = borderWidth
        path.stroke()
    }
}

#endif
