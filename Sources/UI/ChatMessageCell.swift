//
//  ChatMessageCell.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

public final class ChatMessageCell: UITableViewCell {
    public static let reuseIdentifier = "ChatMessageCell"

    private let bubbleView = UIView()
    private let messageLabel = UILabel()

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
        contentView.addSubview(bubbleView)

        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(messageLabel)

        // Bubble constraints
        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubbleView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
        ])

        leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        // Label inside bubble
        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
        ])
    }

    public func configure(with message: ChatMessage) {
        messageLabel.text = message.text.isEmpty ? "..." : message.text

        // Deactivate both, then activate the correct one
        leadingConstraint.isActive = false
        trailingConstraint.isActive = false

        switch message.role {
        case .user:
            trailingConstraint.isActive = true
            bubbleView.backgroundColor = AppAgentAppearance.userBubbleBackground
            messageLabel.textColor = .white
        case .assistant:
            leadingConstraint.isActive = true
            bubbleView.backgroundColor = AppAgentAppearance.assistantBubbleBackground
            messageLabel.textColor = AppAgentAppearance.primaryText
        }

        if message.status == .error {
            bubbleView.backgroundColor = AppAgentAppearance.errorBackground
            messageLabel.textColor = AppAgentAppearance.errorText
        }
    }
}

#endif
