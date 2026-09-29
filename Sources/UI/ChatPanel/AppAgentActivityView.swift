//
//  AppAgentActivityView.swift
//  AppAgentUI
//
//  Codex 风格过程输出：• 动作 + └ 明细；点摘要展开/收起整轮。
//  进行中保留阶段图标，成功后隐藏；失败时图标与失败阶段始终可见。
//  收起就只剩标题行：标题本身已经在说「思考中…」，底下再挂一条「• 思考」预览
//  等于同一条明细渲染两遍，看着像收起后又冒出一个新的思考块。
//

#if canImport(UIKit)
import UIKit
import BOUIKit

/// 过程明细的阅读位置。
///
/// **归属在列表，不在视图**：cell 是复用的，行滚出屏幕再滚回来换的是另一个实例，
/// 位置记在视图里等于记在「谁碰巧复用了这一格」上 —— 表现就是阅读位置归零或串到别的行。
/// 所以 `AppAgentActivityView` 只负责「应用」和「上报」，由
/// `AppAgentChatMessageListView` 按 `ChatRowIdentity` 持有。
public struct AppAgentActivityDetailPosition: Equatable, Sendable {
    public var offsetY: CGFloat
    /// 贴底状态要单独记：只记 offset 的话，明细追加后 offset 没变、但已经不在底部了，
    /// 「运行中跟随最新一行」就断掉。
    public var isPinnedToBottom: Bool

    public init(offsetY: CGFloat, isPinnedToBottom: Bool) {
        self.offsetY = offsetY
        self.isPinnedToBottom = isPinnedToBottom
    }

    /// 新行的默认位置：内容短的时候顶部同时也是底部，跟随语义与旧实现一致。
    public static let pinnedToBottom = AppAgentActivityDetailPosition(offsetY: 0, isPinnedToBottom: true)
}

final class AppAgentActivityView: UIView {
    /// 约七行过程文本；完整明细由内部滚动承载，不持续撑高正文所在的 cell。
    static let maximumDetailHeight: CGFloat = 140
    var onToggle: (() -> Void)?

    /// 用户手动滚过明细之后回调，让列表把新的阅读位置记到行身份上。
    /// 只在**用户拖动**时上报：程序化恢复也会走 `scrollViewDidScroll`，
    /// 那时若布局还没完成、最大 offset 是 0，回写就会把存好的位置抹成 0。
    var onDetailPositionChanged: ((AppAgentActivityDetailPosition) -> Void)?

    private let headerControl = UIControl()
    private let chevronLabel = UILabel()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bodyStack = UIStackView()
    let detailScrollView = UIScrollView()
    private let stageStrip = AppAgentRunStageStripView()
    private let emptyDetailLabel = UILabel()
    private var bodyTextViews: [UITextView] = []
    private var renderedItems: [AppAgentActivityItem] = []
    /// 当前该应用的阅读位置。只是「上一次 configure 传进来的值」的暂存，不是真相来源。
    private var detailPosition = AppAgentActivityDetailPosition.pinnedToBottom

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

        configureDetailLabel(emptyDetailLabel)
        emptyDetailLabel.text = "本轮未记录思考或工具明细。"

        bodyStack.axis = .vertical
        bodyStack.spacing = 8
        bodyStack.clipsToBounds = true
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        // 失败阶段图标和摘要共用同一个展开状态，必须经列表重测高度。
        // 不把展开状态藏在 view 内，否则模板 cell 测量不到，过程文本会被裁掉。
        stageStrip.onErrorTapped = { [weak self] in self?.onToggle?() }
        let details = UIStackView(arrangedSubviews: [emptyDetailLabel, bodyStack])
        details.axis = .vertical
        details.spacing = 4
        details.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.contentInsetAdjustmentBehavior = .never
        detailScrollView.showsHorizontalScrollIndicator = false
        detailScrollView.alwaysBounceVertical = false
        detailScrollView.bounces = false
        detailScrollView.scrollsToTop = false
        detailScrollView.delegate = self
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

    func configure(
        with timeline: AppAgentActivityTimeline,
        expanded: Bool,
        detailPosition: AppAgentActivityDetailPosition? = nil
    ) {
        // 位置由列表按行身份给出；没有记录（新行 / 模板 cell 测量）就用默认的贴底。
        self.detailPosition = detailPosition ?? .pinnedToBottom
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

        // 收起 = 只剩标题行（标题已经在说「思考中…」/「处理过程」），明细一概不渲染。
        // 没有明细的已完成纯文本回复由 cell 隐藏整个过程区，不会走到这里。
        bodyStack.isHidden = !expanded || timeline.items.isEmpty
        emptyDetailLabel.isHidden =
            !expanded || timeline.isRunning || !timeline.items.isEmpty || timeline.displayedFailedStage != nil
        detailScrollView.isHidden = [emptyDetailLabel, bodyStack].allSatisfy(\.isHidden)
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
                bodyTextViews[index].attributedText = attributedRow(item)
            }
        }
        renderedItems = timeline.items
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        detailScrollView.layoutIfNeeded()
        guard !detailScrollView.isHidden else { return }
        let maximum = detailScrollView.bo_maximumContentOffsetY
        // 贴底态跟随明细追加；否则夹取存下来的位置 —— 存的值可能比当前最大 offset 大
        // （明细收缩过），读的时候夹一次就够，不必回写。
        let targetY = detailPosition.isPinnedToBottom
            ? maximum
            : min(maximum, max(0, detailPosition.offsetY))
        detailScrollView.bo_setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
    }

    private func attributedRow(_ item: AppAgentActivityItem) -> NSAttributedString {
        let heading = AppAgentActivityTranscript.heading(for: item)
        let detail = AppAgentActivityTranscript.detail(item.detail)
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

// MARK: - UIScrollViewDelegate

extension AppAgentActivityView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 只认用户拖动：程序化恢复（`layoutSubviews` 的 `bo_setContentOffset`）也会走到这里，
        // 那条路径不能反过来覆盖列表存的位置。
        guard scrollView === detailScrollView,
              scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else {
            return
        }
        detailPosition = AppAgentActivityDetailPosition(
            offsetY: scrollView.contentOffset.y,
            isPinnedToBottom: scrollView.bo_isScrolledToBottom(tolerance: 1)
        )
        onDetailPositionChanged?(detailPosition)
    }
}
#endif
