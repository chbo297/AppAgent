//
//  AppAgentChatPanelNavigationBar.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// ChatPanel 内容区顶部的导航栏，提供 Session 列表入口和面板收起操作。
final class AppAgentChatPanelNavigationBar: UIView {
    static let height: CGFloat = 48

    var onSessionListRequested: (() -> Void)?
    var onCollapseRequested: (() -> Void)?
    var onNewSessionRequested: (() -> Void)?

    let sessionListButton = UIButton(type: .system)
    let collapseButton = UIButton(type: .system)
    let newSessionButton = UIButton(type: .system)

    var title: String = "对话" {
        didSet {
            guard title != oldValue else { return }
            titleLabel.text = title
        }
    }

    private static let buttonSize: CGFloat = 36
    private static let horizontalInset: CGFloat = 10

    private let titleLabel = UILabel()
    private let separatorView = UIView()

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

        let buttonSize = min(Self.buttonSize, bounds.height)
        let buttonY = (bounds.height - buttonSize) / 2
        sessionListButton.frame = CGRect(
            x: Self.horizontalInset,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        collapseButton.frame = CGRect(
            x: max(Self.horizontalInset, bounds.width - Self.horizontalInset - buttonSize),
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        newSessionButton.frame = CGRect(
            x: max(Self.horizontalInset, collapseButton.frame.minX - 6 - buttonSize),
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )

        // 让标题相对整条导航栏水平居中：左右各预留两侧内容中较宽的一侧宽度，
        // 使标题 frame 关于 bounds.midX 对称，避免因左 1 / 右 2 个按钮而偏移。
        let leftContentWidth = sessionListButton.frame.maxX
        let rightContentWidth = bounds.width - newSessionButton.frame.minX
        let titleSideInset = max(leftContentWidth, rightContentWidth) + 8
        titleLabel.frame = CGRect(
            x: titleSideInset,
            y: 0,
            width: max(0, bounds.width - titleSideInset * 2),
            height: bounds.height
        )

        let separatorHeight = 1 / max(UIScreen.main.scale, 1)
        separatorView.frame = CGRect(
            x: 12,
            y: max(0, bounds.height - separatorHeight),
            width: max(0, bounds.width - 24),
            height: separatorHeight
        )

        let cornerRadius = buttonSize / 2
        sessionListButton.layer.cornerRadius = cornerRadius
        collapseButton.layer.cornerRadius = cornerRadius
        newSessionButton.layer.cornerRadius = cornerRadius
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func setup() {
        backgroundColor = .clear

        configure(
            sessionListButton,
            symbolName: "list.bullet",
            accessibilityLabel: "会话列表",
            action: #selector(didTapSessionListButton)
        )
        addSubview(sessionListButton)

        configure(
            collapseButton,
            symbolName: "chevron.down",
            accessibilityLabel: "收起对话面板",
            action: #selector(didTapCollapseButton)
        )
        addSubview(collapseButton)

        configure(
            newSessionButton,
            symbolName: "square.and.pencil",
            accessibilityLabel: "新对话",
            action: #selector(didTapNewSessionButton)
        )
        addSubview(newSessionButton)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        separatorView.isUserInteractionEnabled = false
        addSubview(separatorView)

        applyAppearance()
    }

    private func configure(
        _ button: UIButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        button.setImage(UIImage(systemName: symbolName, withConfiguration: configuration), for: .normal)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func applyAppearance() {
        titleLabel.textColor = AppAgentAppearance.primaryText
        separatorView.backgroundColor = AppAgentAppearance.inputBarBorder
        [sessionListButton, collapseButton, newSessionButton].forEach { button in
            button.tintColor = AppAgentAppearance.icon
            button.backgroundColor = AppAgentAppearance.voicePressedBackground
        }
    }

    @objc func didTapSessionListButton() {
        onSessionListRequested?()
    }

    @objc func didTapCollapseButton() {
        onCollapseRequested?()
    }

    @objc func didTapNewSessionButton() {
        onNewSessionRequested?()
    }
}

#endif
