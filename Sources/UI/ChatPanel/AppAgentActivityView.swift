//
//  AppAgentActivityView.swift
//  AppAgentUI
//
//  可折叠的「思考 / 执行过程」区块：一行摘要 + 展开后的分步明细。
//  折叠行：▸ 思考中…（附最新思考摘要）/ ▾ 已思考 12.3 秒 · 3 步
//

#if canImport(UIKit)
import UIKit

final class AppAgentActivityView: UIView {

    /// 点击折叠行。
    var onToggle: (() -> Void)?

    private let headerControl = UIControl()
    private let chevronLabel = UILabel()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let summaryLabel = UILabel()
    private let bodyStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        chevronLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        chevronLabel.textColor = AppAgentAppearance.secondaryText
        chevronLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = AppAgentAppearance.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        headerControl.addSubview(chevronLabel)
        headerControl.addSubview(titleLabel)
        headerControl.addSubview(spinner)
        headerControl.addTarget(self, action: #selector(didTapHeader), for: .touchUpInside)
        headerControl.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .italicSystemFont(ofSize: 12)
        summaryLabel.textColor = AppAgentAppearance.secondaryText
        summaryLabel.numberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyStack.axis = .vertical
        bodyStack.spacing = 6
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let root = UIStackView(arrangedSubviews: [headerControl, summaryLabel, bodyStack])
        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            headerControl.heightAnchor.constraint(equalToConstant: 20),
            chevronLabel.leadingAnchor.constraint(equalTo: headerControl.leadingAnchor),
            chevronLabel.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: chevronLabel.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
            spinner.trailingAnchor.constraint(lessThanOrEqualTo: headerControl.trailingAnchor)
        ])
    }

    @objc private func didTapHeader() {
        onToggle?()
    }

    /// 渲染一轮过程。`expanded` 决定是否展开明细；进行中会转圈并显示最新思考摘要。
    func configure(with timeline: AppAgentActivityTimeline, expanded: Bool) {
        chevronLabel.text = expanded ? "▾" : "▸"
        titleLabel.text = timeline.headerTitle()
        if timeline.isRunning {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }

        // 折叠时给一行摘要；展开且仍在进行时也保留摘要，让最新一轮始终有「一句话进度」。
        let summary = timeline.headerSummary
        let showSummary = summary != nil && (!expanded || timeline.isRunning)
        summaryLabel.text = summary
        summaryLabel.isHidden = !showSummary

        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        bodyStack.isHidden = !expanded
        guard expanded else { return }
        for item in timeline.items {
            bodyStack.addArrangedSubview(makeRow(for: item))
        }
    }

    private func makeRow(for item: AppAgentActivityItem) -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = item.kind == .thinking ? .italicSystemFont(ofSize: 12) : .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = AppAgentAppearance.secondaryText

        let marker: String
        switch item.state {
        case .running: marker = "•"
        case .done: marker = "✓"
        case .failed: marker = "✕"
        }
        let elapsed = item.finishedAt == nil ? "" : String(format: " (%.1fs)", item.elapsed())
        let head = item.kind == .thinking ? "\(marker) 思考\(elapsed)" : "\(marker) \(item.title)\(elapsed)"

        let detail = item.detail.count > 600 ? String(item.detail.prefix(600)) + "…" : item.detail
        let text = detail.isEmpty ? head : "\(head)\n\(detail)"

        let attributed = NSMutableAttributedString(string: text)
        let headRange = NSRange(location: 0, length: min(head.count, text.count))
        attributed.addAttribute(
            .foregroundColor,
            value: item.state == .failed ? UIColor.systemRed : AppAgentAppearance.primaryText.withAlphaComponent(0.75),
            range: headRange
        )
        label.attributedText = attributed
        return label
    }
}
#endif

