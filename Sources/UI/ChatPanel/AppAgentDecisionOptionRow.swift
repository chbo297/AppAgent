//
//  AppAgentDecisionOptionRow.swift
//  AppAgent
//
//  决策卡片上的一个选项：左侧单选圈，文字默认最多两行；超出两行时右侧出现
//  展开/收起箭头，用户能看到全文。点行本身只是选中，提交由卡片的按钮负责。
//

#if canImport(UIKit)
import UIKit

final class AppAgentDecisionOptionRow: UIControl {

    /// 用户点了展开/收起。卡片据此重新算高度。
    var onToggleExpand: (() -> Void)?

    let option: DecisionOption
    private(set) var isExpanded = false

    private let indicator = UIImageView()
    private let label = UILabel()
    private let expandButton = UIButton(type: .system)
    private let font = UIFont.systemFont(ofSize: 14)

    private static let collapsedLines = 2
    private static let inset: CGFloat = 10
    private static let spacing: CGFloat = 8
    private static let indicatorSize: CGFloat = 18
    private static let expandWidth: CGFloat = 28
    private static let minHeight: CGFloat = 40

    init(option: DecisionOption) {
        self.option = option
        super.init(frame: .zero)
        backgroundColor = UIColor.tertiarySystemBackground
        layer.cornerRadius = 10
        layer.borderWidth = 1.5

        indicator.contentMode = .scaleAspectFit
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)

        label.text = option.label
        label.font = font
        label.textColor = option.style == .destructive ? .systemRed : .label
        label.numberOfLines = Self.collapsedLines
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        addSubview(label)

        expandButton.tintColor = .secondaryLabel
        expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
        addSubview(expandButton)

        accessibilityIdentifier = "appagent.decision.\(option.id)"
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1
        }
    }

    @objc private func handleExpand() {
        isExpanded.toggle()
        label.numberOfLines = isExpanded ? 0 : Self.collapsedLines
        updateAppearance()
        setNeedsLayout()
        onToggleExpand?()
    }

    private func updateAppearance() {
        indicator.image = UIImage(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        indicator.tintColor = isSelected ? .systemBlue : .tertiaryLabel
        layer.borderColor = (isSelected ? UIColor.systemBlue : UIColor.clear).cgColor
        expandButton.setImage(UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down"), for: .normal)
        expandButton.accessibilityLabel = isExpanded ? "收起" : "展开全文"
    }

    // MARK: - Layout

    /// 给定行宽下的高度。折叠时最多两行，展开后是全文高度。
    func preferredHeight(width: CGFloat) -> CGFloat {
        let text = textMetrics(rowWidth: width)
        return max(Self.minHeight, text.height + Self.inset * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = textMetrics(rowWidth: bounds.width)
        let textY = (bounds.height - text.height) / 2
        // 单选圈与箭头对齐第一行，多行时不跑到中间去。
        let firstLineMidY = textY + font.lineHeight / 2
        indicator.frame = CGRect(x: Self.inset,
                                 y: firstLineMidY - Self.indicatorSize / 2,
                                 width: Self.indicatorSize,
                                 height: Self.indicatorSize)
        label.frame = CGRect(x: indicator.frame.maxX + Self.spacing,
                             y: textY,
                             width: text.width,
                             height: text.height)
        expandButton.isHidden = !text.expandable
        expandButton.frame = CGRect(x: bounds.width - Self.expandWidth - Self.inset / 2,
                                    y: firstLineMidY - Self.expandWidth / 2,
                                    width: Self.expandWidth,
                                    height: Self.expandWidth)
    }

    /// 文字区宽高，以及是否需要展开箭头。先按不带箭头的宽度量，超过两行再让出箭头位置重量。
    private func textMetrics(rowWidth: CGFloat) -> (width: CGFloat, height: CGFloat, expandable: Bool) {
        let collapsedHeight = ceil(font.lineHeight * CGFloat(Self.collapsedLines))
        var width = max(0, rowWidth - Self.inset * 2 - Self.indicatorSize - Self.spacing)
        var fullHeight = fullTextHeight(width: width)
        let expandable = fullHeight > collapsedHeight + 0.5
        if expandable {
            width = max(0, width - Self.expandWidth)
            fullHeight = fullTextHeight(width: width)
        }
        let height = isExpanded ? fullHeight : min(fullHeight, collapsedHeight)
        return (width, height, expandable)
    }

    private func fullTextHeight(width: CGFloat) -> CGFloat {
        let rect = (option.label as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.height)
    }
}
#endif
