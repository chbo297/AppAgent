//
//  LijiRequirementListView.swift
//  OpenAPP — Liji 面板 UI
//
//  「需求列表」纯 UIKit 视图：展示状态、摘要/错误，并通过回调暴露应用/分享/取消/重新生成动作。
//  数据来自 LijiPanelDataSource.requirementRows（不含网络逻辑，由宿主注入回调触发 client 调用）。
//

#if canImport(UIKit)
import UIKit

public final class LijiRequirementListView: UIView {
    /// 用户点击某行的某个动作。
    public var onAction: ((LijiRequirementRow, LijiRequirementAction) -> Void)?
    /// 下拉刷新回调（宿主重新拉取列表后调用 setRows）。
    public var onRefresh: (() -> Void)?

    private let tableView = UITableView()
    private let refreshControl = UIRefreshControl()
    private let emptyLabel = UILabel()
    private var rows: [LijiRequirementRow] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds
        emptyLabel.frame = bounds.insetBy(dx: 24, dy: 24)
    }

    public func setRows(_ rows: [LijiRequirementRow]) {
        self.rows = rows
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
        refreshControl.endRefreshing()
    }

    private func setup() {
        backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
        tableView.register(LijiRequirementCell.self, forCellReuseIdentifier: LijiRequirementCell.reuseIdentifier)
        refreshControl.addTarget(self, action: #selector(didPullRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        addSubview(tableView)

        emptyLabel.text = "暂无需求，去和 app agent 说说你的产品想法吧"
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    @objc private func didPullRefresh() {
        onRefresh?()
    }
}

/// 需求行支持的动作。
public enum LijiRequirementAction: Sendable {
    case apply, share, cancel, regenerate
}

extension LijiRequirementListView: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: LijiRequirementCell.reuseIdentifier, for: indexPath
        ) as! LijiRequirementCell
        let row = rows[indexPath.row]
        cell.configure(with: row) { [weak self] action in
            self?.onAction?(row, action)
        }
        return cell
    }
}

/// 单条需求卡片：标题/摘要/状态徽标 + 一排动作按钮。
private final class LijiRequirementCell: UITableViewCell {
    static let reuseIdentifier = "LijiRequirementCell"

    private let promptLabel = UILabel()
    private let statusBadge = UILabel()
    private let detailLabel = UILabel()
    private let buttonStack = UIStackView()
    private var onAction: ((LijiRequirementAction) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(with row: LijiRequirementRow, onAction: @escaping (LijiRequirementAction) -> Void) {
        self.onAction = onAction
        promptLabel.text = row.prompt
        statusBadge.text = "  \(row.status.displayText)  "
        statusBadge.backgroundColor = Self.badgeColor(for: row.status)
        let detail = row.error.isEmpty ? row.summary : "错误：\(row.error)"
        detailLabel.text = detail.isEmpty ? "生成中，请稍候…" : detail
        detailLabel.textColor = row.error.isEmpty ? .secondaryLabel : .systemRed

        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var actions: [(String, LijiRequirementAction)] = []
        if row.canApply { actions.append(("应用", .apply)) }
        if row.canShare { actions.append(("分享", .share)) }
        if row.canCancel { actions.append(("取消", .cancel)) }
        if row.canRegenerate { actions.append(("重新生成", .regenerate)) }
        for (title, action) in actions {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            button.tag = Self.tag(for: action)
            button.addTarget(self, action: #selector(didTapButton(_:)), for: .touchUpInside)
            buttonStack.addArrangedSubview(button)
        }
        buttonStack.isHidden = actions.isEmpty
    }

    @objc private func didTapButton(_ sender: UIButton) {
        guard let action = Self.action(for: sender.tag) else { return }
        onAction?(action)
    }

    private static func tag(for action: LijiRequirementAction) -> Int {
        switch action {
        case .apply: return 1
        case .share: return 2
        case .cancel: return 3
        case .regenerate: return 4
        }
    }

    private static func action(for tag: Int) -> LijiRequirementAction? {
        switch tag {
        case 1: return .apply
        case 2: return .share
        case 3: return .cancel
        case 4: return .regenerate
        default: return nil
        }
    }

    private static func badgeColor(for status: LijiRequirementRow.StatusKind) -> UIColor {
        switch status {
        case .patchGenerated, .applied: return .systemGreen
        case .failed: return .systemRed
        case .cancelled, .disabled: return .systemGray
        case .inProgress, .pending: return .systemOrange
        case .unknown: return .systemGray
        }
    }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .clear

        promptLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        promptLabel.numberOfLines = 2

        statusBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        statusBadge.textColor = .white
        statusBadge.layer.cornerRadius = 8
        statusBadge.layer.masksToBounds = true
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.numberOfLines = 3

        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .equalSpacing

        let topRow = UIStackView(arrangedSubviews: [promptLabel, statusBadge])
        topRow.axis = .horizontal
        topRow.alignment = .top
        topRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [topRow, detailLabel, buttonStack])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }
}

#endif
