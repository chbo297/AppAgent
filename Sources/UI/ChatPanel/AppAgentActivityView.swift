//
//  AppAgentActivityView.swift
//  AppAgentUI
//
//  Codex 风格过程输出：• 动作 + └ 明细；点摘要展开/收起整轮。
//  进行中保留阶段图标，成功后隐藏；失败时图标与失败阶段始终可见。
//

#if canImport(UIKit)
import UIKit
import BOUIKit

final class AppAgentActivityView: UIView {
    /// 约七行过程文本；完整明细由内部滚动承载，不持续撑高正文所在的 cell。
    static let maximumDetailHeight: CGFloat = 140
    var onToggle: (() -> Void)?

    private let headerControl = UIControl()
    private let chevronLabel = UILabel()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let previewLabel = UILabel()
    private let bodyStack = UIStackView()
    let detailScrollView = UIScrollView()
    private let stageStrip = AppAgentRunStageStripView()
    private let emptyDetailLabel = UILabel()
    private var bodyTextViews: [UITextView] = []
    private var renderedItems: [AppAgentActivityItem] = []
    private var displayedStartedAt: Date?
    private var followDetailBottom = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        chevronLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        chevronLabel.textColor = AppAgentAppearance.secondaryText
        chevronLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = AppAgentAppearance.secondaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        headerControl.addSubview(chevronLabel)
        headerControl.addSubview(titleLabel)
        headerControl.addSubview(spinner)
        headerControl.addTarget(self, action: #selector(didTapHeader), for: .touchUpInside)
        headerControl.isAccessibilityElement = true
        headerControl.accessibilityTraits = .button
        headerControl.translatesAutoresizingMaskIntoConstraints = false

        configureDetailLabel(previewLabel)
        previewLabel.numberOfLines = 4
        configureDetailLabel(emptyDetailLabel)
        emptyDetailLabel.text = "本轮未记录思考或工具明细。"

        bodyStack.axis = .vertical
        bodyStack.spacing = 8
        bodyStack.clipsToBounds = true
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        // 失败阶段图标和摘要共用同一个展开状态，必须经列表重测高度。
        // 不把展开状态藏在 view 内，否则模板 cell 测量不到，过程文本会被裁掉。
        stageStrip.onErrorTapped = { [weak self] in self?.onToggle?() }
        let details = UIStackView(arrangedSubviews: [
            previewLabel, emptyDetailLabel, bodyStack
        ])
        details.axis = .vertical
        details.spacing = 4
        details.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.contentInsetAdjustmentBehavior = .never
        detailScrollView.showsHorizontalScrollIndicator = false
        detailScrollView.alwaysBounceVertical = false
        detailScrollView.bounces = false
        detailScrollView.scrollsToTop = false
        detailScrollView.addSubview(details)
        // 低于 label 的 hugging/compression：长明细不压缩，只让视口停在上限；
        // 短明细按自身高度参与模板 cell 测量，无需先 layoutSubviews 再回写高度。
        let fitDetails = detailScrollView.heightAnchor.constraint(equalTo: details.heightAnchor)
        fitDetails.priority = UILayoutPriority(249)
        NSLayoutConstraint.activate([
            details.topAnchor.constraint(equalTo: detailScrollView.contentLayoutGuide.topAnchor),
            details.bottomAnchor.constraint(equalTo: detailScrollView.contentLayoutGuide.bottomAnchor),
            details.leadingAnchor.constraint(equalTo: detailScrollView.contentLayoutGuide.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: detailScrollView.contentLayoutGuide.trailingAnchor),
            details.widthAnchor.constraint(equalTo: detailScrollView.frameLayoutGuide.widthAnchor),
            detailScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maximumDetailHeight),
            detailScrollView.heightAnchor.constraint(lessThanOrEqualTo: details.heightAnchor),
            fitDetails
        ])
        let root = UIStackView(arrangedSubviews: [stageStrip, headerControl, detailScrollView])
        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            headerControl.heightAnchor.constraint(equalToConstant: 28),
            chevronLabel.leadingAnchor.constraint(equalTo: headerControl.leadingAnchor),
            chevronLabel.widthAnchor.constraint(equalToConstant: 20),
            chevronLabel.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: chevronLabel.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: headerControl.trailingAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20)
        ])
    }

    private func configureDetailLabel(_ label: UILabel) {
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = AppAgentAppearance.secondaryText
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
    }

    private func configureDetailTextView(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = true
        // 明细由外层 detailScrollView 滚动；内部 UITextView 不参与滚动，
        // 避免和 BODragScroll / 外层 UIScrollView 争抢手势。
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = AppAgentAppearance.secondaryText
        textView.dataDetectorTypes = []
        textView.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func didTapHeader() { onToggle?() }

    func configure(with timeline: AppAgentActivityTimeline, expanded: Bool) {
        let sameTimeline = displayedStartedAt == timeline.startedAt
        followDetailBottom = sameTimeline && timeline.isRunning
            && detailScrollView.bo_isScrolledToBottom(tolerance: 1)
        if !sameTimeline {
            detailScrollView.bo_setContentOffset(.zero, animated: false)
        }
        displayedStartedAt = timeline.startedAt
        stageStrip.configure(
            stage: timeline.stage,
            furthest: timeline.furthestStage,
            failedStage: timeline.displayedFailedStage,
            isRunning: timeline.isRunning
        )
        stageStrip.isHidden = !timeline.showsStageStrip

        chevronLabel.text = expanded ? "▾" : "▸"
        // 产品要求去掉「处理过程」标题：正常完成轮只留放大的三角，失败/工具失败仍给状态文案。
        let title = timeline.headerTitle()
        titleLabel.text = title
        titleLabel.isHidden = title.isEmpty
        titleLabel.textColor = timeline.failedStage == nil ? AppAgentAppearance.secondaryText : .systemRed
        headerControl.accessibilityLabel = title.isEmpty ? "处理过程" : title
        headerControl.accessibilityValue = expanded ? "已展开" : "已收起"
        headerControl.accessibilityHint = expanded ? "收起过程输出" : "展开过程输出"
        if timeline.isRunning { spinner.startAnimating() } else { spinner.stopAnimating() }

        // 终局错误已经拼接到最终 assistant 正文中。过程区只保留失败阶段和标题，
        // 不再重复渲染同一段错误正文；工具条目自身的失败明细仍属于真实过程。

        // 运行中收起：只给最新动作的终端式预览；完成后只留一行总览。
        // 没有明细的已完成纯文本回复由 cell 隐藏整个过程区，不会走到这里。
        previewLabel.isHidden = expanded || !timeline.isRunning || timeline.items.isEmpty
        if !previewLabel.isHidden, let item = timeline.items.last {
            previewLabel.attributedText = attributedRow(item, expanded: false)
        }

        bodyStack.isHidden = !expanded || timeline.items.isEmpty
        emptyDetailLabel.isHidden =
            !expanded || timeline.isRunning || !timeline.items.isEmpty || timeline.displayedFailedStage != nil
        detailScrollView.isHidden = [previewLabel, emptyDetailLabel, bodyStack]
            .allSatisfy(\.isHidden)
        setNeedsLayout()
        guard expanded else { return }
        // 逐字思考不能每次拆掉整棵 stack：已完成行保留，只更新变化行。
        while bodyTextViews.count > timeline.items.count {
            let textView = bodyTextViews.removeLast()
            bodyStack.removeArrangedSubview(textView)
            textView.removeFromSuperview()
        }
        while bodyTextViews.count < timeline.items.count {
            let textView = UITextView()
            configureDetailTextView(textView)
            bodyTextViews.append(textView)
            bodyStack.addArrangedSubview(textView)
        }
        for (index, item) in timeline.items.enumerated() {
            if bodyTextViews[index].attributedText == nil
                || index >= renderedItems.count || renderedItems[index] != item {
                bodyTextViews[index].attributedText = attributedRow(item, expanded: true)
            }
        }
        renderedItems = timeline.items
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        detailScrollView.layoutIfNeeded()
        guard !detailScrollView.isHidden else { return }
        let maximum = detailScrollView.bo_maximumContentOffsetY
        let targetY = followDetailBottom ? maximum : min(maximum, max(0, detailScrollView.contentOffset.y))
        detailScrollView.bo_setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        followDetailBottom = false
    }

    private func attributedRow(_ item: AppAgentActivityItem, expanded: Bool) -> NSAttributedString {
        let heading = AppAgentActivityTranscript.heading(for: item)
        let detail = AppAgentActivityTranscript.detail(item.detail, expanded: expanded)
        let text = detail.isEmpty ? heading : heading + "\n" + detail
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.headIndent = 16
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: item.state == .failed ? UIColor.systemRed : AppAgentAppearance.secondaryText,
            .paragraphStyle: paragraph
        ])
        result.addAttributes([
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: item.state == .failed ? UIColor.systemRed : AppAgentAppearance.primaryText
        ], range: NSRange(location: 0, length: (heading as NSString).length))
        result.addAttribute(.foregroundColor, value: markerColor(for: item), range: NSRange(location: 0, length: 1))
        return result
    }

    private func markerColor(for item: AppAgentActivityItem) -> UIColor {
        switch item.state {
        case .running: return .systemBlue
        case .done: return item.kind == .tool ? .systemGreen : AppAgentAppearance.secondaryText
        case .failed: return .systemRed
        }
    }
}
#endif
