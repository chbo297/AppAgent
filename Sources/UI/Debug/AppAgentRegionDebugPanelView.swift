//
//  AppAgentRegionDebugPanelView.swift
//  AppAgentUI
//
//  调试浮窗：折叠时是一颗可拖动的 40pt 圆形按钮，点开是一块毛玻璃面板，
//  里面三个开关分别控制红 / 黄 / 蓝三类响应区域边框的显示。
//  形态参考 BWTimeGallery 的 DebugMapFloatingPanel。
//

#if canImport(UIKit)
import BOUIKit
import UIKit

final class AppAgentRegionDebugPanelView: UIView {

    static let collapsedSize = CGSize(width: 40, height: 40)
    static let expandedSize = CGSize(width: 272, height: 232)

    /// 折叠 / 展开切换。
    var onExpansionChange: ((Bool) -> Void)?
    /// 某个区域的开关被拨动。
    var onRegionVisibilityChange: ((AppAgentInteractionRegion, Bool) -> Void)?
    /// 折叠态被拖动到新的中心点（父视图坐标系）。
    var onDragToCenter: ((CGPoint) -> Void)?

    private(set) var isExpanded = false

    private let collapsedButton = UIButton(type: .custom)
    private let expandedEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let collapseButton = UIButton(type: .system)
    private let rowsStack = UIStackView()
    private var switches: [AppAgentInteractionRegion: UISwitch] = [:]

    private lazy var dragGesture = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureCollapsedButton()
        configureExpandedPanel()
        setExpanded(false, notify: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func isOn(_ region: AppAgentInteractionRegion) -> Bool {
        switches[region]?.isOn ?? false
    }

    func setExpanded(_ expanded: Bool, notify: Bool = true) {
        isExpanded = expanded
        // 折叠态把命中范围外扩 2pt（BOUIKit 正值扩大），展开态按面板实际边界。
        bo_hitAreaOutsets = expanded ? .zero : UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        collapsedButton.isHidden = expanded
        expandedEffectView.isHidden = !expanded
        dragGesture.isEnabled = !expanded
        if notify { onExpansionChange?(expanded) }
    }

    // MARK: - Setup

    private func configureCollapsedButton() {
        collapsedButton.backgroundColor = .systemOrange
        collapsedButton.layer.cornerRadius = Self.collapsedSize.width / 2
        collapsedButton.setTitle("👻", for: .normal)
        collapsedButton.titleLabel?.font = .systemFont(ofSize: 22)
        collapsedButton.accessibilityIdentifier = "appagent.regionDebug.toggle"
        collapsedButton.accessibilityLabel = "展开响应区域调试面板"
        collapsedButton.layer.shadowColor = UIColor.black.cgColor
        collapsedButton.layer.shadowOpacity = 0.2
        collapsedButton.layer.shadowRadius = 10
        collapsedButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        collapsedButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        collapsedButton.addGestureRecognizer(dragGesture)
        collapsedButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collapsedButton)
        NSLayoutConstraint.activate([
            collapsedButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            collapsedButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            collapsedButton.topAnchor.constraint(equalTo: topAnchor),
            collapsedButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureExpandedPanel() {
        expandedEffectView.clipsToBounds = true
        expandedEffectView.layer.cornerRadius = 18
        expandedEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(expandedEffectView)

        let title = UILabel()
        title.text = "响应区域"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = AppAgentAppearance.primaryText

        collapseButton.setTitle("收起", for: .normal)
        collapseButton.titleLabel?.font = .systemFont(ofSize: 13)
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [title, UIView(), collapseButton])
        header.alignment = .center

        rowsStack.axis = .vertical
        rowsStack.spacing = 8
        for region in AppAgentInteractionRegion.allCases {
            rowsStack.addArrangedSubview(makeRow(for: region))
        }

        let root = UIStackView(arrangedSubviews: [header, rowsStack])
        root.axis = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        expandedEffectView.contentView.addSubview(root)

        NSLayoutConstraint.activate([
            expandedEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            expandedEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandedEffectView.topAnchor.constraint(equalTo: topAnchor),
            expandedEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            root.leadingAnchor.constraint(equalTo: expandedEffectView.contentView.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: expandedEffectView.contentView.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: expandedEffectView.contentView.topAnchor, constant: 12)
        ])
    }

    private func makeRow(for region: AppAgentInteractionRegion) -> UIView {
        let swatch = UIView()
        swatch.backgroundColor = .clear
        swatch.layer.borderWidth = 1
        swatch.layer.borderColor = region.color.cgColor
        swatch.layer.cornerRadius = 2
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 16).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let label = UILabel()
        label.text = region.title
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = AppAgentAppearance.primaryText
        label.numberOfLines = 2

        let toggle = UISwitch()
        toggle.accessibilityIdentifier = region.accessibilityIdentifier
        toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        switches[region] = toggle

        let row = UIStackView(arrangedSubviews: [swatch, label, toggle])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    // MARK: - Actions

    @objc private func expandTapped() { setExpanded(true) }

    @objc private func collapseTapped() { setExpanded(false) }

    @objc private func switchChanged(_ sender: UISwitch) {
        guard let region = switches.first(where: { $0.value === sender })?.key else { return }
        onRegionVisibilityChange?(region, sender.isOn)
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let translation = gesture.translation(in: superview)
        let target = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        onDragToCenter?(target)
    }
}

#endif
