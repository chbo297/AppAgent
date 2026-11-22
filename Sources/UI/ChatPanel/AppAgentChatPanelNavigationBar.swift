//
//  AppAgentChatPanelNavigationBar.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 宿主挂在对话面板顶栏（会话设置按钮左侧）的一个开关按钮，用来展开 / 收起宿主自己的配套页面。
///
/// 按钮用 `AppAgentPageToggleButton` 画：展开时上格占大半并着强调色，收起时折成顶端一条强调色细线，
/// 提示「这里还有页面可以打开」。宿主页面里的收起按钮用同一个控件，两处长得一样。
/// 没有可展示的页面时宿主应把 `navigationAccessory` 置 nil，按钮随之隐藏。
public struct AppAgentNavigationAccessory: Equatable, Sendable {
    public var isActive: Bool
    /// 读屏用的名称，例如「工作区」；状态与动作由 SDK 拼成「已展开，轻点收起」。
    public var accessibilityName: String

    public init(isActive: Bool, accessibilityName: String) {
        self.isActive = isActive
        self.accessibilityName = accessibilityName
    }
}

/// ChatPanel 内容区顶部的导航栏，提供 Session 列表入口、会话设置和面板收起操作。
final class AppAgentChatPanelNavigationBar: UIView {
    var onSessionListRequested: (() -> Void)?
    var onCollapseRequested: (() -> Void)?
    var onNewSessionRequested: (() -> Void)?
    var onSessionSettingsRequested: (() -> Void)?
    var onAccessoryTapped: (() -> Void)?

    let sessionListButton = UIButton(type: .system)
    let collapseButton = UIButton(type: .system)
    let newSessionButton = UIButton(type: .system)
    let sessionSettingsButton = UIButton(type: .system)
    let accessoryButton = AppAgentPageToggleButton(style: .bar)

    var accessory: AppAgentNavigationAccessory? {
        didSet {
            guard accessory != oldValue else {
                return
            }
            applyAccessory(previous: oldValue)
            setNeedsLayout()
        }
    }

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
            x: min(sessionListButton.frame.maxX + 6, max(Self.horizontalInset, collapseButton.frame.minX - buttonSize)),
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        sessionSettingsButton.frame = CGRect(
            x: max(newSessionButton.frame.maxX, collapseButton.frame.minX - 6 - buttonSize),
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        accessoryButton.frame = CGRect(
            x: max(newSessionButton.frame.maxX, sessionSettingsButton.frame.minX - 6 - buttonSize),
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        // 让标题相对整条导航栏水平居中：左右各预留两侧内容中较宽的一侧宽度，
        // 使标题 frame 关于 bounds.midX 对称。
        let leftContentWidth = newSessionButton.frame.maxX
        let rightEdge = accessoryButton.isHidden ? sessionSettingsButton.frame.minX : accessoryButton.frame.minX
        let rightContentWidth = bounds.width - rightEdge
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
        sessionSettingsButton.layer.cornerRadius = cornerRadius
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

        configure(
            sessionSettingsButton,
            symbolName: "gearshape",
            accessibilityLabel: "会话设置",
            action: #selector(didTapSessionSettingsButton)
        )
        addSubview(sessionSettingsButton)

        accessoryButton.isHidden = true
        accessoryButton.addTarget(self, action: #selector(didTapAccessoryButton), for: .touchUpInside)
        addSubview(accessoryButton)

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
        [sessionListButton, collapseButton, newSessionButton, sessionSettingsButton].forEach { button in
            button.tintColor = AppAgentAppearance.icon
            button.backgroundColor = AppAgentAppearance.voicePressedBackground
        }
    }

    private func applyAccessory(previous: AppAgentNavigationAccessory?) {
        guard let accessory else {
            accessoryButton.isHidden = true
            return
        }
        accessoryButton.isHidden = false
        accessoryButton.accessibilityName = accessory.accessibilityName
        // 刚出现时直接到位；之后的展开 / 收起由上格高度动画表达页面去了哪里。
        accessoryButton.setExpanded(accessory.isActive, animated: previous != nil)
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

    @objc func didTapSessionSettingsButton() {
        onSessionSettingsRequested?()
    }

    @objc func didTapAccessoryButton() {
        onAccessoryTapped?()
    }
}

#endif
