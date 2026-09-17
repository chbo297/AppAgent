//
//  AppAgentSessionListView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// Session 侧栏中的内容视图，负责标题、列表渲染和条目选择，不负责进出场动画。
final class AppAgentSessionListView: UIView {
    var onSelectItem: ((AppAgentSessionSidebarItem) -> Void)?
    var onRenameItem: ((AppAgentSessionSidebarItem) -> Void)?
    var onDeleteItem: ((AppAgentSessionSidebarItem) -> Void)?
    var onSettingsTapped: (() -> Void)?
    var onDebugTapped: (() -> Void)?

    private(set) var items: [AppAgentSessionSidebarItem] = []

    private static let titleAreaHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 60
    private static let settingsButtonSize: CGFloat = 32

    private let titleLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    private let debugButton = UIButton(type: .system)
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

        let buttonSize = Self.settingsButtonSize
        settingsButton.frame = CGRect(
            x: max(0, bounds.width - 16 - buttonSize),
            y: safeTop + (Self.titleAreaHeight - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )
        settingsButton.layer.cornerRadius = buttonSize / 2

        debugButton.frame = CGRect(
            x: max(0, settingsButton.frame.minX - 8 - buttonSize),
            y: settingsButton.frame.minY,
            width: buttonSize,
            height: buttonSize
        )
        debugButton.layer.cornerRadius = buttonSize / 2

        titleLabel.frame = CGRect(
            x: 16,
            y: safeTop,
            width: max(0, debugButton.frame.minX - 8 - 16),
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

    func setItems(_ items: [AppAgentSessionSidebarItem]) {
        guard self.items != items else { return }
        self.items = items
        tableView.reloadData()
    }

    private func setup() {
        titleLabel.text = "会话"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textAlignment = .natural
        addSubview(titleLabel)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        settingsButton.setImage(UIImage(systemName: "gearshape", withConfiguration: symbolConfig), for: .normal)
        settingsButton.accessibilityLabel = "设置"
        settingsButton.addTarget(self, action: #selector(didTapSettings), for: .touchUpInside)
        addSubview(settingsButton)

        let debugIcon = UIImage(systemName: "ladybug", withConfiguration: symbolConfig)
            ?? UIImage(systemName: "ant", withConfiguration: symbolConfig)
            ?? UIImage(systemName: "exclamationmark.triangle", withConfiguration: symbolConfig)
        debugButton.setImage(debugIcon, for: .normal)
        debugButton.accessibilityLabel = "调试"
        debugButton.addTarget(self, action: #selector(didTapDebug), for: .touchUpInside)
        addSubview(debugButton)

        separatorView.isUserInteractionEnabled = false
        addSubview(separatorView)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(
            AppAgentSessionListCell.self,
            forCellReuseIdentifier: AppAgentSessionListCell.reuseIdentifier
        )
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        tableView.addGestureRecognizer(longPress)
        addSubview(tableView)

        applyAppearance()
    }

    @objc private func didTapSettings() {
        onSettingsTapped?()
    }

    @objc private func didTapDebug() {
        onDebugTapped?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              indexPath.row < items.count else { return }
        let item = items[indexPath.row]
        // Only real sessions (with a sessionID) can be renamed; demo placeholders can't.
        guard item.sessionID != nil else { return }
        onRenameItem?(item)
    }

    private func applyAppearance() {
        backgroundColor = AppAgentAppearance.inputBarBackground
        titleLabel.textColor = AppAgentAppearance.primaryText
        settingsButton.tintColor = AppAgentAppearance.icon
        settingsButton.backgroundColor = AppAgentAppearance.voicePressedBackground
        debugButton.tintColor = AppAgentAppearance.icon
        debugButton.backgroundColor = AppAgentAppearance.voicePressedBackground
        separatorView.backgroundColor = AppAgentAppearance.inputBarBorder
        tableView.reloadData()
    }
}

extension AppAgentSessionListView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: AppAgentSessionListCell.reuseIdentifier,
            for: indexPath
        ) as! AppAgentSessionListCell
        cell.configure(with: items[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onSelectItem?(items[indexPath.row])
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < items.count else { return nil }
        let item = items[indexPath.row]
        // Only real sessions (with a sessionID) can be deleted; demo placeholders can't.
        guard item.sessionID != nil else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.onDeleteItem?(item)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
    }
}

/// Session 列表单行视图，集中管理选中态、图标和两行文字样式。
private final class AppAgentSessionListCell: UITableViewCell {
    static let reuseIdentifier = "AppAgentSessionListCell"

    private let selectionBackgroundView = UIView()
    private let selectionIndicatorView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var item: AppAgentSessionSidebarItem?

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

    func configure(with item: AppAgentSessionSidebarItem) {
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
            ? AppAgentAppearance.accent.withAlphaComponent(0.12)
            : .clear
        selectionIndicatorView.backgroundColor = AppAgentAppearance.accent
        selectionIndicatorView.isHidden = !isSelected
        iconView.tintColor = isSelected ? AppAgentAppearance.accent : AppAgentAppearance.secondaryText
        titleLabel.textColor = AppAgentAppearance.primaryText
        detailLabel.textColor = AppAgentAppearance.secondaryText
    }
}

#endif
