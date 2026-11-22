//
//  AppAgentDecisionCardView.swift
//  AppAgent
//
//  「等用户拍板」的通用卡片：私网授权、工具授权、权限、方案选择/澄清共用这一个控件。
//  它属于 AppAgent 自己的 UI，宿主 app 不需要实现任何东西——层级上就在对话面板内，
//  不遮挡宿主界面，也不影响别的 session。
//
//  两种形态，都没有倒计时，用户不答就一直等：
//  - 授权类：只能在有效选项里选。
//  - 提问类（clarification）：最后一项是「自己输入」，可以主动跳过。
//  点选项只是选中，点「确定 / 提交」才生效，防误触。
//

#if canImport(UIKit)
import UIKit

final class AppAgentDecisionCardView: UIView, UITextViewDelegate {

    /// 用户提交了结果（或点了跳过）。
    var onSelect: ((DecisionOutcome) -> Void)?
    /// 卡片自然高度变了（展开长选项、出现输入框），面板据此重新布局。
    var onContentHeightChange: (() -> Void)?

    private let scrollView = UIScrollView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private var rows: [AppAgentDecisionOptionRow] = []
    private let customTextView = UITextView()
    private let customPlaceholder = UILabel()
    private let skipButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    private var request: DecisionRequest?
    private var selectedIndex: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    /// 卡片收起时（提交或面板销毁）把键盘收掉。
    override var isHidden: Bool {
        didSet {
            if isHidden {
                endEditing(true)
            }
        }
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

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.addSubview(titleLabel)
        scrollView.addSubview(messageLabel)
        addSubview(scrollView)

        customTextView.font = .systemFont(ofSize: 14)
        customTextView.textColor = .label
        customTextView.backgroundColor = UIColor.tertiarySystemBackground
        customTextView.layer.cornerRadius = 10
        customTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        customTextView.delegate = self
        customTextView.isHidden = true
        customTextView.accessibilityIdentifier = "appagent.decision.custom_input"
        customPlaceholder.text = "输入你的回答"
        customPlaceholder.font = .systemFont(ofSize: 14)
        customPlaceholder.textColor = .placeholderText
        customPlaceholder.isUserInteractionEnabled = false
        customTextView.addSubview(customPlaceholder)
        scrollView.addSubview(customTextView)

        setupFooter()
    }
    private func setupFooter() {
        skipButton.setTitle("跳过", for: .normal)
        skipButton.setTitleColor(.secondaryLabel, for: .normal)
        skipButton.titleLabel?.font = .systemFont(ofSize: 14)
        skipButton.accessibilityIdentifier = "appagent.decision.skip"
        skipButton.addTarget(self, action: #selector(handleSkip), for: .touchUpInside)
        addSubview(skipButton)

        confirmButton.backgroundColor = .systemBlue
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        confirmButton.layer.cornerRadius = 10
        confirmButton.accessibilityIdentifier = "appagent.decision.confirm"
        confirmButton.addTarget(self, action: #selector(handleConfirm), for: .touchUpInside)
        addSubview(confirmButton)
    }

    // MARK: - Content

    func configure(with request: DecisionRequest) {
        self.request = request
        titleLabel.text = request.title
        messageLabel.text = request.message

        for row in rows {
            row.removeFromSuperview()
        }
        rows = []
        for (index, option) in request.options.enumerated() {
            let row = AppAgentDecisionOptionRow(option: option)
            row.tag = index
            row.addTarget(self, action: #selector(handleRowTap(_:)), for: .touchUpInside)
            row.onToggleExpand = { [weak self] in
                self?.contentHeightChanged()
            }
            scrollView.addSubview(row)
            rows.append(row)
        }

        selectedIndex = nil
        customTextView.text = ""
        customPlaceholder.isHidden = false
        customTextView.isHidden = true
        skipButton.isHidden = !request.isSkippable
        confirmButton.setTitle(request.isSkippable ? "提交" : "确定", for: .normal)
        // 开放式提问只有「自己输入」一项：直接选中露出输入框，但不抢键盘。
        if rows.count == 1, rows[0].option.id == DecisionOption.customAnswerID {
            select(index: 0, focus: false)
        }
        updateConfirmState()
        scrollView.contentOffset = .zero
        setNeedsLayout()
    }
    // MARK: - Selection

    @objc private func handleRowTap(_ sender: AppAgentDecisionOptionRow) {
        select(index: sender.tag, focus: true)
    }

    private func select(index: Int, focus: Bool) {
        guard rows.indices.contains(index) else {
            return
        }
        selectedIndex = index
        for row in rows {
            row.isSelected = row.tag == index
        }
        let isCustom = rows[index].option.id == DecisionOption.customAnswerID
        let inputVisibilityChanged = customTextView.isHidden == isCustom
        customTextView.isHidden = !isCustom
        if !isCustom {
            customTextView.resignFirstResponder()
        }
        updateConfirmState()
        if inputVisibilityChanged {
            contentHeightChanged()
        }
        if isCustom, focus {
            customTextView.becomeFirstResponder()
        }
    }

    /// 当前选择能提交成什么；`nil` = 还不能提交（没选，或选了「自己输入」但没写字）。
    private func currentOutcome() -> DecisionOutcome? {
        guard let request, let selectedIndex, request.options.indices.contains(selectedIndex) else {
            return nil
        }
        let outcome = Self.outcome(for: request, optionIndex: selectedIndex, customText: customTextView.text)
        if request.options[selectedIndex].id == DecisionOption.customAnswerID, outcome == .answer(nil) {
            return nil
        }
        return outcome
    }

    private func updateConfirmState() {
        let enabled = currentOutcome() != nil
        confirmButton.isEnabled = enabled
        confirmButton.alpha = enabled ? 1 : 0.4
    }

    @objc private func handleConfirm() {
        guard let outcome = currentOutcome() else {
            return
        }
        finish(outcome)
    }

    @objc private func handleSkip() {
        finish(.answer(nil))
    }

    private func finish(_ outcome: DecisionOutcome) {
        endEditing(true)
        onSelect?(outcome)
    }

    /// 选项 → 结果。放成 static 纯函数，方便单测锁住「选第几个 = 什么语义」。
    /// `customText` 只在选中「自己输入」时有意义，空白视为没回答。
    nonisolated static func outcome(for request: DecisionRequest,
                                    optionIndex: Int,
                                    customText: String? = nil) -> DecisionOutcome {
        guard request.options.indices.contains(optionIndex) else {
            return .deny
        }
        let option = request.options[optionIndex]
        switch request {
        case .privateNetworkAccess, .toolAuthorization, .appAgentInspection, .permission:
            switch option.id {
            case "allow_once":
                return .allowOnce
            case "allow_session":
                return .allowForSession
            case "allow_always":
                return .allowAlways
            default:
                return .deny
            }
        case .clarification(_, let choices):
            if optionIndex < choices.count {
                return .answer(choices[optionIndex])
            }
            let text = customText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .answer(text.isEmpty ? nil : text)
        }
    }
    // MARK: - Custom input

    func textViewDidBeginEditing(_ textView: UITextView) {
        layoutIfNeeded()
        scrollView.scrollRectToVisible(textView.frame, animated: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        customPlaceholder.isHidden = !textView.text.isEmpty
        updateConfirmState()
    }

    private func contentHeightChanged() {
        setNeedsLayout()
        onContentHeightChange?()
    }
    // MARK: - Layout

    private static let padding: CGFloat = 14
    private static let gap: CGFloat = 8
    private static let customInputHeight: CGFloat = 72
    private static let footerHeight: CGFloat = 34

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - Self.padding * 2
        guard width > 0 else {
            return
        }
        // 底栏固定在卡片底部；正文与选项放滚动区，卡片被面板限高时还能滚到。
        let contentHeight = layoutContent(width: width, apply: true)
        let footerY = bounds.height - Self.padding - Self.footerHeight
        scrollView.frame = CGRect(x: Self.padding,
                                  y: Self.padding,
                                  width: width,
                                  height: max(0, footerY - Self.gap - Self.padding))
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        // 占位文字对齐 UITextView 的首行：左侧 = textContainerInset 6 + lineFragmentPadding 5。
        customPlaceholder.frame = CGRect(x: 11, y: 8, width: max(0, width - 22), height: 18)
        layoutFooter(y: footerY, width: width)
    }

    /// 摆放滚动区内容，返回内容总高；`apply == false` 时只测量。
    @discardableResult
    private func layoutContent(width: CGFloat, apply: Bool) -> CGFloat {
        let fitting = CGSize(width: width, height: .greatestFiniteMagnitude)
        var y: CGFloat = 0

        let titleHeight = titleLabel.sizeThatFits(fitting).height
        if apply {
            titleLabel.frame = CGRect(x: 0, y: y, width: width, height: titleHeight)
        }
        y += titleHeight + Self.gap / 2

        let messageHeight = messageLabel.sizeThatFits(fitting).height
        if apply {
            messageLabel.frame = CGRect(x: 0, y: y, width: width, height: messageHeight)
        }
        y += messageHeight + Self.gap

        for row in rows {
            let rowHeight = row.preferredHeight(width: width)
            if apply {
                row.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
            }
            y += rowHeight + Self.gap
            // 输入框紧跟在「自己输入」那一行下面。
            if row.option.id == DecisionOption.customAnswerID, !customTextView.isHidden {
                if apply {
                    customTextView.frame = CGRect(x: 0, y: y, width: width, height: Self.customInputHeight)
                }
                y += Self.customInputHeight + Self.gap
            }
        }
        return max(0, y - Self.gap)
    }

    private func layoutFooter(y: CGFloat, width: CGFloat) {
        let confirmWidth = max(72, confirmButton.sizeThatFits(.zero).width + 24)
        confirmButton.frame = CGRect(x: Self.padding + width - confirmWidth,
                                     y: y,
                                     width: confirmWidth,
                                     height: Self.footerHeight)
        let trailing = confirmButton.frame.minX - Self.gap
        if !skipButton.isHidden {
            let skipWidth = skipButton.sizeThatFits(.zero).width + 16
            skipButton.frame = CGRect(x: trailing - skipWidth, y: y, width: skipWidth, height: Self.footerHeight)
        }
    }

    /// 卡片在给定宽度下需要多高。面板布局用它决定卡片 frame（超出可用高度时由面板截断、卡片内滚动）。
    func height(fittingWidth width: CGFloat) -> CGFloat {
        let contentHeight = layoutContent(width: width - Self.padding * 2, apply: false)
        return Self.padding * 2 + contentHeight + Self.gap + Self.footerHeight
    }

#if DEBUG
    /// 调试用：按 option id 选中并提交（走的是和真人点击同一条 target/action）。
    func debugTapOption(id: String) {
        let row = rows.first { candidate in
            candidate.option.id == id
        }
        row?.sendActions(for: .touchUpInside)
        confirmButton.sendActions(for: .touchUpInside)
    }
#endif
}
#endif
