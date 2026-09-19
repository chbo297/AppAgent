//
//  ChatMessageCell.swift
//  AppAgentUI
//
//  一条消息：assistant 消息在气泡上方多一块可折叠的「思考 / 执行过程」区，
//  气泡本身只放最终结果（对齐 Codex CLI / ChatGPT app 的呈现方式）。
//

#if canImport(UIKit)
import UIKit

public final class ChatMessageCell: UITableViewCell {
    public static let reuseIdentifier = "ChatMessageCell"

    /// 点击过程区折叠行时回调（由列表转发给 ViewController）。
    var onToggleActivity: (() -> Void)?

    private let rootStack = UIStackView()
    private let activityView = AppAgentActivityView()
    private let bubbleRow = UIView()
    private let bubbleView = UIView()
    /// 正文用非滚动 UITextView 承载，换取系统原生的长按选择 / 拷贝 / 全选菜单。
    let messageTextView = UITextView()

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override public init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCell() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bubbleView.layer.cornerRadius = 12
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleRow.addSubview(bubbleView)

        messageTextView.isEditable = false
        messageTextView.isSelectable = true
        // 关键：关掉滚动，UITextView 才能参与 self-sizing，也才不会被 BODragScroll
        // 当成内部可滚动 participant 抢走面板手势。
        messageTextView.isScrollEnabled = false
        messageTextView.backgroundColor = .clear
        messageTextView.textContainerInset = .zero
        messageTextView.textContainer.lineFragmentPadding = 0
        messageTextView.font = .systemFont(ofSize: 15)
        messageTextView.dataDetectorTypes = []
        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(messageTextView)

        activityView.onToggle = { [weak self] in self?.onToggleActivity?() }

        rootStack.axis = .vertical
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(activityView)
        rootStack.addArrangedSubview(bubbleRow)
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            bubbleView.topAnchor.constraint(equalTo: bubbleRow.topAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: bubbleRow.bottomAnchor),
            bubbleView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),

            messageTextView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageTextView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            messageTextView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageTextView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12)
        ])

        leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: bubbleRow.leadingAnchor, constant: 12)
        trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: bubbleRow.trailingAnchor, constant: -12)
    }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // 复用前清掉上一条消息残留的选中态，避免选中高亮跟着 cell 漂移。
        messageTextView.selectedRange = NSRange(location: 0, length: 0)
    }

    public func configure(with message: ChatMessage) {
        let baseFont = UIFont.systemFont(ofSize: 15)

        // Deactivate both, then activate the correct one
        leadingConstraint.isActive = false
        trailingConstraint.isActive = false

        var textColor = AppAgentAppearance.primaryText
        switch message.role {
        case .user:
            trailingConstraint.isActive = true
            bubbleView.backgroundColor = AppAgentAppearance.userBubbleBackground
            textColor = .white
            // 深色气泡上用白色选择手柄/放大镜，否则几乎看不见。
            messageTextView.tintColor = .white
        case .assistant:
            leadingConstraint.isActive = true
            bubbleView.backgroundColor = AppAgentAppearance.assistantBubbleBackground
            messageTextView.tintColor = nil
        }

        if message.status == .error {
            bubbleView.backgroundColor = AppAgentAppearance.errorBackground
            textColor = AppAgentAppearance.errorText
            messageTextView.tintColor = nil
        }

        applyText(message, baseFont: baseFont, color: textColor)

        // 过程区：只有 assistant 且确实有过程时才显示。
        // role 判定不能省：过程区挂到用户气泡上是明显的错（注释曾经说了但代码没做）。
        if message.role == .assistant, let activity = message.activity, !activity.isEmpty {
            activityView.isHidden = false
            activityView.configure(with: activity, expanded: message.isActivityExpanded)
        } else {
            activityView.isHidden = true
        }

        // 流式且还没有正文时，气泡先不占位，避免出现空的 "..." 泡。
        let hideEmptyStreamingBubble = message.status == .streaming
            && message.text.isEmpty
            && !(message.activity?.isEmpty ?? true)
        bubbleRow.isHidden = hideEmptyStreamingBubble
    }

    /// agent 的回复按 markdown 渲染；用户自己的话保持原样，不做任何解释。
    private func applyText(_ message: ChatMessage, baseFont: UIFont, color: UIColor) {
        let source = message.text.isEmpty ? "..." : message.text
        switch message.role {
        case .user:
            messageTextView.attributedText = NSAttributedString(string: source, attributes: [
                .font: baseFont,
                .foregroundColor: color
            ])
        case .assistant:
            messageTextView.attributedText = AppAgentMarkdown.attributed(
                source, baseFont: baseFont, color: color
            )
        }
        messageTextView.linkTextAttributes = [
            .foregroundColor: messageTextView.tintColor ?? AppAgentAppearance.primaryText,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }
}

#endif
