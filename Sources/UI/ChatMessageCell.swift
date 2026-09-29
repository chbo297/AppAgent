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

    /// 用户滚过过程明细后回调。阅读位置**存在列表侧**（按 `ChatRowIdentity`），
    /// cell 只做透传：cell 会被复用，存在这里等于存在「谁碰巧复用了这一格」上。
    var onActivityDetailPositionChanged: ((AppAgentActivityDetailPosition) -> Void)?

    private let rootStack = UIStackView()
    private let activityView = AppAgentActivityView()
    private let bubbleRow = UIView()
    private let bubbleView = UIView()
    /// 正文用非滚动 UITextView 承载，换取系统原生的长按选择 / 拷贝 / 全选菜单。
    let messageTextView = UITextView()
    /// 流式输出中贴在正文末尾的闪烁竖杠：让用户看出「还在吐字，没结束」。
    let streamingCaretView = UIView()
    private var isStreamingCaretVisible = false
    private static let caretBlinkKey = "appagent.streamingCaret.blink"
    private static let caretWidth: CGFloat = 2

    private struct TextRenderInput: Equatable {
        let source: String
        let role: ChatMessage.Role
        let font: UIFont
        let color: UIColor
        let linkColor: UIColor
    }
    private var renderedTextInput: TextRenderInput?
    private var displayedMessageID: UUID?
    private var appliedRole: ChatMessage.Role?

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var userWidthConstraint: NSLayoutConstraint!
    private var textLeadingConstraint: NSLayoutConstraint!
    private var textTrailingConstraint: NSLayoutConstraint!

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
        // 行高缩小时子视图可能尚未完成本轮布局，按当前 cell 边界裁切，避免文字越到下一行。
        clipsToBounds = true
        contentView.clipsToBounds = true

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

        // 光标挂在正文 textView 里，按文末插入点的 rect 手动定位（见 positionStreamingCaret）。
        // 不进正文字符串：那样每个 delta 都要重解析 markdown，还会让行高抖动。
        streamingCaretView.isUserInteractionEnabled = false
        streamingCaretView.layer.cornerRadius = Self.caretWidth / 2
        streamingCaretView.isHidden = true
        messageTextView.addSubview(streamingCaretView)

        activityView.onToggle = { [weak self] in self?.onToggleActivity?() }
        activityView.onDetailPositionChanged = { [weak self] position in
            self?.onActivityDetailPositionChanged?(position)
        }

        rootStack.axis = .vertical
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(activityView)
        rootStack.addArrangedSubview(bubbleRow)
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            // 最新回复按当前面板的初始留白基准只增不减，cell 可能比内容高一截。
            // 用 equal 的话多出来的空间会把气泡拉高；用 <= 则内容顶对齐、余量留在下方。
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -4),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            bubbleView.topAnchor.constraint(equalTo: bubbleRow.topAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: bubbleRow.bottomAnchor),

            messageTextView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            messageTextView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8)
        ])

        // 低优先级的 equal：测量（`systemLayoutSizeFitting`）时它决定内容高度；
        // 实际布局里 cell 被给了更大的高度时它被打破，交给上面的 <= 约束。
        let stackBottomHug = rootStack.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -4
        )
        stackBottomHug.priority = .fittingSizeLevel
        stackBottomHug.isActive = true

        leadingConstraint = bubbleView.leadingAnchor.constraint(equalTo: bubbleRow.leadingAnchor, constant: 12)
        trailingConstraint = bubbleView.trailingAnchor.constraint(equalTo: bubbleRow.trailingAnchor, constant: -12)
        userWidthConstraint = bubbleView.widthAnchor.constraint(
            lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78
        )
        textLeadingConstraint = messageTextView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor)
        textTrailingConstraint = messageTextView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor)
        NSLayoutConstraint.activate([textLeadingConstraint, textTrailingConstraint])
    }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // 复用前清掉上一条消息残留的选中态，避免选中高亮跟着 cell 漂移。
        messageTextView.selectedRange = NSRange(location: 0, length: 0)
        displayedMessageID = nil
        renderedTextInput = nil
        onToggleActivity = nil
        onActivityDetailPositionChanged = nil
        hideStreamingCaret()
    }

    /// - Parameter activityDetailPosition: 过程明细的阅读位置，由列表按行身份给出；
    ///   `nil` 表示没有记录（新行，或模板 cell 只是在测高度）。
    public func configure(
        with message: ChatMessage,
        activityDetailPosition: AppAgentActivityDetailPosition? = nil
    ) {
        let baseFont = UIFont.systemFont(ofSize: 15)
        if displayedMessageID != message.id {
            messageTextView.selectedRange = NSRange(location: 0, length: 0)
            displayedMessageID = message.id
        }

        // 用户保留窄气泡；assistant 横向铺满，正文与过程区统一留 14pt 边距。
        // 同一条回复折叠/逐字更新时，不反复拆装完全相同的约束。
        let roleChanged = appliedRole != message.role
        if roleChanged {
            leadingConstraint.isActive = false
            trailingConstraint.isActive = false
            userWidthConstraint.isActive = false
        }

        var textColor = AppAgentAppearance.primaryText
        switch message.role {
        case .user:
            if roleChanged {
                trailingConstraint.constant = -12
                trailingConstraint.isActive = true
                userWidthConstraint.isActive = true
                textLeadingConstraint.constant = 12
                textTrailingConstraint.constant = -12
            }
            bubbleView.backgroundColor = AppAgentAppearance.userBubbleBackground
            textColor = .white
            // 深色气泡上用白色选择手柄/放大镜，否则几乎看不见。
            messageTextView.tintColor = .white
        case .assistant:
            if roleChanged {
                leadingConstraint.constant = 14
                trailingConstraint.constant = -14
                leadingConstraint.isActive = true
                trailingConstraint.isActive = true
                textLeadingConstraint.constant = 0
                textTrailingConstraint.constant = 0
            }
            bubbleView.backgroundColor = .clear
            messageTextView.tintColor = nil
        }
        appliedRole = message.role

        if message.status == .error {
            if message.role == .user {
                bubbleView.backgroundColor = AppAgentAppearance.errorBackground
            }
            textColor = AppAgentAppearance.errorText
            messageTextView.tintColor = nil
        }

        applyText(message, baseFont: baseFont, color: textColor)

        // 还在吐字的 agent 回复：正文末尾挂一个闪烁光标。没有正文时由过程区的
        // 「思考中…」表示进行中，这里不重复提示。
        if message.role == .assistant, message.status == .streaming, !message.text.isEmpty {
            showStreamingCaret(color: textColor)
        } else {
            hideStreamingCaret()
        }

        // 成功完成轮在「总是显示思考过程」关闭时抑制过程入口；报错/异常回合不受影响。
        if message.role == .assistant,
           let activity = message.activity,
           activity.shouldDisplayActivity,
           !message.suppressResolvedActivity {
            activityView.isHidden = false
            activityView.configure(
                with: activity,
                expanded: message.isActivityExpanded,
                detailPosition: activityDetailPosition
            )
        } else {
            activityView.isHidden = true
        }

        // 流式且还没有正文时，气泡先不占位，避免出现空的 "..." 泡。
        let hideEmptyStreamingBubble = message.status == .streaming
            && message.text.isEmpty
            && !activityView.isHidden
        bubbleRow.isHidden = hideEmptyStreamingBubble
    }

    /// agent 的回复按 markdown 渲染；用户自己的话保持原样，不做任何解释。
    private func applyText(_ message: ChatMessage, baseFont: UIFont, color: UIColor) {
        let source = message.text.isEmpty ? "..." : message.text
        let input = TextRenderInput(
            source: source, role: message.role, font: baseFont, color: color,
            linkColor: messageTextView.tintColor ?? AppAgentAppearance.primaryText
        )
        // 只变过程区/展开态时，保留 textStorage 和选区，避免无效 Markdown 解析与文本重绘。
        guard renderedTextInput != input else { return }
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
            .foregroundColor: input.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        renderedTextInput = input
    }

    // MARK: - 流式光标

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard isStreamingCaretVisible else { return }
        // 切后台 / 移出窗口会把动画从 layer 上摘掉，回来时补一次。
        startCaretBlinkIfNeeded()
        positionStreamingCaret()
    }

    private func showStreamingCaret(color: UIColor) {
        streamingCaretView.backgroundColor = color
        streamingCaretView.isHidden = false
        isStreamingCaretVisible = true
        startCaretBlinkIfNeeded()
        // 正文刚变过，位置要等这轮文本布局完成后再算。
        setNeedsLayout()
    }

    private func hideStreamingCaret() {
        isStreamingCaretVisible = false
        streamingCaretView.isHidden = true
        // 离屏 / 已结束的 cell 不留着动画空转。
        streamingCaretView.layer.removeAnimation(forKey: Self.caretBlinkKey)
    }

    private func startCaretBlinkIfNeeded() {
        guard streamingCaretView.layer.animation(forKey: Self.caretBlinkKey) == nil else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.55
        blink.autoreverses = true
        blink.repeatCount = .greatestFiniteMagnitude
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        streamingCaretView.layer.add(blink, forKey: Self.caretBlinkKey)
    }

    /// 位置直接问 UITextInput 要「文末插入点」的矩形：自己按行高算的话，
    /// 换行、markdown 派生字号、末尾空白都会让光标偏到别处。
    private func positionStreamingCaret() {
        let caret = messageTextView.caretRect(for: messageTextView.endOfDocument)
        guard caret.minX.isFinite, caret.minY.isFinite, caret.height.isFinite, caret.height > 0 else {
            // 文本还没排版好（宽度为 0 等）：这一轮先不画，下次布局再来。
            streamingCaretView.isHidden = true
            return
        }
        streamingCaretView.isHidden = false
        streamingCaretView.frame = CGRect(
            x: caret.minX + 1,
            y: caret.minY + 1,
            width: Self.caretWidth,
            height: max(caret.height - 2, 1)
        )
    }
}

#endif
