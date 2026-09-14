//
//  LijiGrantListView.swift
//  OpenAPP — Liji 面板 UI
//
//  「分享给我的」列表：展示他人分享的补丁 + 开关。
//

#if canImport(UIKit)
import UIKit

public final class LijiGrantListView: UIView {
    /// 用户切换某条分享的开关。
    public var onToggle: ((LijiGrantRow, Bool) -> Void)?
    public var onRefresh: (() -> Void)?

    private let tableView = UITableView()
    private let refreshControl = UIRefreshControl()
    private let emptyLabel = UILabel()
    private var rows: [LijiGrantRow] = []

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

    public func setRows(_ rows: [LijiGrantRow]) {
        self.rows = rows
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
        refreshControl.endRefreshing()
    }

    private func setup() {
        backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .singleLine
        tableView.rowHeight = 64
        tableView.register(LijiGrantCell.self, forCellReuseIdentifier: LijiGrantCell.reuseIdentifier)
        refreshControl.addTarget(self, action: #selector(didPullRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        addSubview(tableView)

        emptyLabel.text = "还没有人分享给你补丁"
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    @objc private func didPullRefresh() { onRefresh?() }
}

extension LijiGrantListView: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: LijiGrantCell.reuseIdentifier, for: indexPath
        ) as! LijiGrantCell
        let row = rows[indexPath.row]
        cell.configure(with: row) { [weak self] enabled in
            self?.onToggle?(row, enabled)
        }
        return cell
    }
}

private final class LijiGrantCell: UITableViewCell {
    static let reuseIdentifier = "LijiGrantCell"

    private let titleLabel = UILabel()
    private let ownerLabel = UILabel()
    private let toggle = UISwitch()
    private var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(with row: LijiGrantRow, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        titleLabel.text = row.title
        ownerLabel.text = "来自 \(row.owner) · \(row.note)"
        toggle.isOn = row.enabled
    }

    @objc private func toggleChanged() {
        onToggle?(toggle.isOn)
    }

    private func setup() {
        selectionStyle = .none
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        ownerLabel.font = .systemFont(ofSize: 12)
        ownerLabel.textColor = .secondaryLabel
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, ownerLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [textStack, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
}

#endif
