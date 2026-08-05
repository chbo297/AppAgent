//
//  OpenAPPSessionListView.swift
//  OpenAPPUI
//

#if canImport(UIKit)
import UIKit

/// Session 侧栏中的内容视图，负责标题、列表渲染和条目选择，不负责进出场动画。
final class OpenAPPSessionListView: UIView {
    var onSelectItem: ((OpenAPPSessionSidebarItem) -> Void)?

    private(set) var items: [OpenAPPSessionSidebarItem] = []

    private static let titleAreaHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 60

    private let titleLabel = UILabel()
    private let separatorView = UIView()
    private let tableView = UITableView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let safeTop = max(0, safeAreaInsets.top)
        let safeBottom = max(0, safeAreaInsets.bottom)
        titleLabel.frame = CGRect(
            x: 16,
            y: safeTop,
            width: max(0, bounds.width - 32),
            height: Self.titleAreaHeight
        )

        let separatorHeight = 1 / max(UIScreen.main.scale, 1)
        separatorView.frame = CGRect(
            x: 0,
            y: titleLabel.frame.maxY - separatorHeight,
            width: bounds.width,
            height: separatorHeight
        )

        let tableY = titleLabel.frame.maxY
        tableView.frame = CGRect(
            x: 0,
            y: tableY,
            width: bounds.width,
            height: max(0, bounds.height - tableY - safeBottom)
        )
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    func setItems(_ items: [OpenAPPSessionSidebarItem]) {
        guard self.items != items else { return }
        self.items = items
        tableView.reloadData()
    }

    private func setup() {
        titleLabel.text = "会话"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textAlignment = .natural
        addSubview(titleLabel)

        separatorView.isUserInteractionEnabled = false
        addSubview(separatorView)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(
            OpenAPPSessionListCell.self,
            forCellReuseIdentifier: OpenAPPSessionListCell.reuseIdentifier
        )
        addSubview(tableView)

        applyAppearance()
    }

    private func applyAppearance() {
        backgroundColor = OpenAPPAppearance.inputBarBackground
        titleLabel.textColor = OpenAPPAppearance.primaryText
        separatorView.backgroundColor = OpenAPPAppearance.inputBarBorder
        tableView.reloadData()
    }
}

extension OpenAPPSessionListView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: OpenAPPSessionListCell.reuseIdentifier,
            for: indexPath
        ) as! OpenAPPSessionListCell
        cell.configure(with: items[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onSelectItem?(items[indexPath.row])
    }
}

/// Session 列表单行视图，集中管理选中态、图标和两行文字样式。
private final class OpenAPPSessionListCell: UITableViewCell {
    static let reuseIdentifier = "OpenAPPSessionListCell"

    private let selectionBackgroundView = UIView()
    private let selectionIndicatorView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var item: OpenAPPSessionSidebarItem?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        selectionBackgroundView.frame = bounds.insetBy(dx: 8, dy: 3)
        selectionBackgroundView.layer.cornerRadius = 6
        selectionIndicatorView.frame = CGRect(
            x: 8,
            y: 12,
            width: 3,
            height: max(0, bounds.height - 24)
        )
        selectionIndicatorView.layer.cornerRadius = 1.5

        iconView.frame = CGRect(x: 16, y: (bounds.height - 24) / 2, width: 24, height: 24)
        let textX = iconView.frame.maxX + 10
        let textWidth = max(0, bounds.width - textX - 12)
        titleLabel.frame = CGRect(x: textX, y: 10, width: textWidth, height: 22)
        detailLabel.frame = CGRect(x: textX, y: 32, width: textWidth, height: 18)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    func configure(with item: OpenAPPSessionSidebarItem) {
        self.item = item
        titleLabel.text = item.title
        detailLabel.text = item.detail
        accessibilityLabel = item.detail.isEmpty ? item.title : "\(item.title)，\(item.detail)"
        accessibilityTraits = item.isSelected ? [.button, .selected] : [.button]
        applyAppearance()
    }

    private func setup() {
        backgroundColor = .clear
        selectionStyle = .none

        selectionBackgroundView.isUserInteractionEnabled = false
        contentView.addSubview(selectionBackgroundView)

        selectionIndicatorView.isUserInteractionEnabled = false
        contentView.addSubview(selectionIndicatorView)

        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.image = UIImage(systemName: "bubble.left.and.bubble.right", withConfiguration: configuration)
        iconView.contentMode = .center
        contentView.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(detailLabel)
    }

    private func applyAppearance() {
        let isSelected = item?.isSelected ?? false
        selectionBackgroundView.backgroundColor = isSelected
            ? OpenAPPAppearance.accent.withAlphaComponent(0.12)
            : .clear
        selectionIndicatorView.backgroundColor = OpenAPPAppearance.accent
        selectionIndicatorView.isHidden = !isSelected
        iconView.tintColor = isSelected ? OpenAPPAppearance.accent : OpenAPPAppearance.secondaryText
        titleLabel.textColor = OpenAPPAppearance.primaryText
        detailLabel.textColor = OpenAPPAppearance.secondaryText
    }
}

#endif
