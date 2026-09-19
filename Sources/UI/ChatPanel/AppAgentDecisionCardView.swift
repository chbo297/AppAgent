//
//  AppAgentDecisionCardView.swift
//  AppAgent
//
//  「等用户拍板」的通用卡片：私网授权、工具授权、方案选择/澄清共用这一个控件。
//  它属于 AppAgent 自己的 UI，宿主 app 不需要实现任何东西——层级上就在对话面板内，
//  不遮挡宿主界面，也不影响别的 session。
//

#if canImport(UIKit)
import UIKit

final class AppAgentDecisionCardView: UIView {

    /// 用户点了某个选项。`nil` = 卡片被取消（比如面板销毁）。
    var onSelect: ((DecisionOutcome) -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let buttonStack = UIStackView()
    private var request: DecisionRequest?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.textColor = .label

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.numberOfLines = 0
        messageLabel.textColor = .secondaryLabel

        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        buttonStack.distribution = .fillEqually

        addSubview(titleLabel)
        addSubview(messageLabel)
        addSubview(buttonStack)
    }

    // MARK: - Content

    func configure(with request: DecisionRequest) {
        self.request = request
        titleLabel.text = request.title
        messageLabel.text = request.message

        buttonStack.arrangedSubviews.forEach {
            buttonStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for option in request.options {
            buttonStack.addArrangedSubview(makeButton(for: option))
        }
        setNeedsLayout()
    }

    private func makeButton(for option: DecisionOption) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(option.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: option.style == .primary ? .semibold : .regular)
        button.layer.cornerRadius = 10
        switch option.style {
        case .primary:
            button.backgroundColor = .systemBlue
            button.setTitleColor(.white, for: .normal)
        case .normal:
            button.backgroundColor = UIColor.tertiarySystemBackground
            button.setTitleColor(.label, for: .normal)
        case .destructive:
            button.backgroundColor = UIColor.tertiarySystemBackground
            button.setTitleColor(.systemRed, for: .normal)
        }
        button.accessibilityIdentifier = "appagent.decision.\(option.id)"
        button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
        return button
    }

    @objc private func handleTap(_ sender: UIButton) {
        guard let request,
              let index = buttonStack.arrangedSubviews.firstIndex(of: sender),
              index < request.options.count else { return }
        onSelect?(Self.outcome(for: request, optionIndex: index))
    }

    /// 选项 → 结果。放成 static 纯函数，方便单测锁住「点第几个 = 什么语义」。
    static func outcome(for request: DecisionRequest, optionIndex: Int) -> DecisionOutcome {
        let option = request.options[optionIndex]
        switch request {
        case .privateNetworkAccess, .toolAuthorization:
            switch option.id {
            case "allow_once": return .allowOnce
            case "allow_session": return .allowForSession
            default: return .deny
            }
        case .clarification(_, let choices):
            guard optionIndex < choices.count else { return .answer(nil) }
            return .answer(choices[optionIndex])
        }
    }

    // MARK: - Layout

    private static let padding: CGFloat = 14
    private static let buttonHeight: CGFloat = 38
    private static let gap: CGFloat = 8

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - Self.padding * 2
        var y = Self.padding

        let titleHeight = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: Self.padding, y: y, width: width, height: titleHeight)
        y += titleHeight + Self.gap / 2

        let messageHeight = messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        messageLabel.frame = CGRect(x: Self.padding, y: y, width: width, height: messageHeight)
        y += messageHeight + Self.gap

        let count = CGFloat(buttonStack.arrangedSubviews.count)
        let stackHeight = count * Self.buttonHeight + max(0, count - 1) * Self.gap
        buttonStack.frame = CGRect(x: Self.padding, y: y, width: width, height: stackHeight)
    }

    /// 卡片在给定宽度下需要多高。面板布局用它决定卡片 frame。
    func height(fittingWidth width: CGFloat) -> CGFloat {
        let contentWidth = width - Self.padding * 2
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
        let messageHeight = messageLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
        let count = CGFloat(buttonStack.arrangedSubviews.count)
        let stackHeight = count * Self.buttonHeight + max(0, count - 1) * Self.gap
        return Self.padding * 2 + titleHeight + Self.gap / 2 + messageHeight + Self.gap + stackHeight
    }

#if DEBUG
    /// 调试用：按 option id 模拟点击（走的是和真人点击同一条 target/action）。
    func debugTapOption(id: String) {
        buttonStack.arrangedSubviews
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "appagent.decision.\(id)" }?
            .sendActions(for: .touchUpInside)
    }
#endif
}
#endif
