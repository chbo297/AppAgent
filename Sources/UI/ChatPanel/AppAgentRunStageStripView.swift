//
//  AppAgentRunStageStripView.swift
//  AppAgentUI
//
//  一轮回答的「阶段指示条」：准备 › 请求 › 输出 › 工具 › 完成 五格，卡在哪一步一眼可见。
//
//  为什么需要它：以前 UI 只有一个 `isStreaming`，于是「请求还没发出去」「发出去了
//  没首字」「工具在跑」三种完全不同的卡法长得一模一样。阶段由 Core 的
//  `AIAgentRunStage` 打点，这里只负责画。
//
//  点亮规则按 `furthestStage`（走到过的最远一步），不按当前 stage：一轮里多次工具
//  往返会在 `.streaming` ↔ `.tooling` 之间来回，按当前 stage 画会来回闪。
//

#if canImport(UIKit)
import UIKit

final class AppAgentRunStageStripView: UIView {

    /// 点失败的阶段格：展开/收起失败详情，不额外添加尾部警告。
    var onErrorTapped: (() -> Void)?

    /// 阶段 → SF Symbol（都是 iOS 13 就有的符号，iOS 15 最低线安全）。
    nonisolated static func iconName(for stage: AIAgentRunStage) -> String {
        switch stage {
        case .preparing:  return "text.badge.plus"
        case .requesting: return "arrow.up.circle"
        case .streaming:  return "text.alignleft"
        case .tooling:    return "wrench.and.screwdriver"
        case .finished:   return "checkmark.circle"
        }
    }

    /// 阶段中文名：指示条上当前那一格显示它，时间线的失败文案也复用这一份。
    nonisolated static func title(for stage: AIAgentRunStage) -> String {
        switch stage {
        case .preparing:  return "准备"
        case .requesting: return "请求"
        case .streaming:  return "输出"
        case .tooling:    return "工具"
        case .finished:   return "完成"
        }
    }

    private static let failureIconName = "exclamationmark.triangle.fill"

    /// 一格：图标 +（仅当前格）中文名。
    private struct Cell {
        let container: UIControl
        let icon: UIImageView
        let label: UILabel
    }

    private let rootStack = UIStackView()
    private var cells: [AIAgentRunStage: Cell] = [:]
    private var connectors: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 4
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        // 纯 Auto Layout：这条会被塞进过程区的垂直 UIStackView，自己不管 frame。
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])

        for (index, stage) in AIAgentRunStage.allCases.enumerated() {
            if index > 0 {
                let connector = UIView()
                connector.backgroundColor = AppAgentAppearance.secondaryText.withAlphaComponent(0.3)
                connector.translatesAutoresizingMaskIntoConstraints = false
                connector.setContentCompressionResistancePriority(.required, for: .horizontal)
                NSLayoutConstraint.activate([
                    connector.widthAnchor.constraint(equalToConstant: 6),
                    connector.heightAnchor.constraint(equalToConstant: 2)
                ])
                connectors.append(connector)
                rootStack.addArrangedSubview(connector)
            }
            let cell = makeCell(for: stage)
            cells[stage] = cell
            rootStack.addArrangedSubview(cell.container)
        }

        // 总高约 18pt：塞在气泡上方不抢视觉。
        let height = heightAnchor.constraint(equalToConstant: 18)
        // UIStackView 隐藏成功轮次时会加 required 的零高度约束。
        height.priority = .defaultHigh
        height.isActive = true
    }

    private func makeCell(for stage: AIAgentRunStage) -> Cell {
        let icon = UIImageView(image: UIImage(systemName: Self.iconName(for: stage)))
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let label = UILabel()
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.text = Self.title(for: stage)
        label.isHidden = true

        let content = UIStackView(arrangedSubviews: [icon, label])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 2
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = UIControl()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        container.accessibilityIdentifier = "appagent.runStage.\(stage.rawValue)"
        container.addTarget(self, action: #selector(didTapError), for: .touchUpInside)
        return Cell(container: container, icon: icon, label: label)
    }

    @objc private func didTapError() {
        onErrorTapped?()
    }

    /// 喂一轮的阶段信息。
    ///
    /// - Parameters:
    ///   - stage: 当前在哪一步（高亮 + 显示中文名）。
    ///   - furthest: 走到过的最远一步，决定哪些格子算「已走过」。
    ///   - failedStage: 失败发生在哪一步；非 nil 时那一格变红且可点击。
    ///   - isRunning: 仅影响「完成」那一格是否算已走过。
    func configure(
        stage: AIAgentRunStage?,
        furthest: AIAgentRunStage?,
        failedStage: AIAgentRunStage?,
        isRunning: Bool
    ) {
        // 既不在跑也没失败过：这一轮没有阶段信息（历史记录），整条不显示。
        guard failedStage != nil || (isRunning && stage != nil) else {
            isHidden = true
            return
        }
        isHidden = false

        let reached = furthest ?? stage
        let passed = AppAgentAppearance.secondaryText
        let pending = AppAgentAppearance.secondaryText.withAlphaComponent(0.3)

        for stageCase in AIAgentRunStage.allCases {
            guard let cell = cells[stageCase] else { continue }
            let isFailed = stageCase == failedStage
            let isCurrent = !isFailed && stageCase == stage && isRunning
            let isPassed = (reached?.order ?? -1) >= stageCase.order

            let iconName = isFailed ? Self.failureIconName : Self.iconName(for: stageCase)
            cell.icon.image = UIImage(systemName: iconName)

            if isFailed {
                cell.icon.tintColor = .systemRed
                cell.label.textColor = .systemRed
            } else if isCurrent {
                cell.icon.tintColor = .systemBlue
                cell.label.textColor = .systemBlue
            } else {
                cell.icon.tintColor = isPassed ? passed : pending
                cell.label.textColor = passed
            }

            // 中文名只给「正在这一步」和「失败在这一步」，否则五个名字堆成一行太吵。
            cell.label.isHidden = !(isCurrent || isFailed)
            cell.container.isUserInteractionEnabled = isFailed
            cell.container.isEnabled = isFailed
            cell.container.isAccessibilityElement = isFailed
            cell.container.accessibilityTraits = isFailed ? .button : .none
            cell.container.accessibilityLabel = isFailed ? "\(Self.title(for: stageCase))失败，展开或收起详情" : nil
        }
    }
}
#endif
