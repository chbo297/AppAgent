//
//  HostTabBarController.swift
//  AppAgentDemo
//

import UIKit

private enum DemoPalette {
    static let background = color(light: 0xF7F9FC, dark: 0x15181D)
    static let chrome = color(light: 0xFFFFFF, dark: 0x22262C)
    static let chromeSelected = color(light: 0xEAF3FF, dark: 0x2B3440)
    static let primaryText = color(light: 0x1D2430, dark: 0xF4F7FB)
    static let secondaryText = color(light: 0x697386, dark: 0xAEB7C3)
    static let accent = color(light: 0x0A7AFF, dark: 0x5AC8FA)
    static let separator = color(light: 0xDDE4ED, dark: 0x343A43)

    private static func color(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traitCollection in
            rgb(traitCollection.userInterfaceStyle == .dark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A minimal tab bar host that simulates a real app's window hierarchy.
/// The AppAgent SDK's chat UI lives in its own independent overlay window
/// floating above this controller.
final class HostTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()

        let home = HostPlaceholderViewController(label: "Host App – Home", showsHapticButton: true)
        home.tabBarItem = UITabBarItem(
            title: "Home",
            image: UIImage(systemName: "house"),
            selectedImage: UIImage(systemName: "house.fill")
        )

        let browse = HostPlaceholderViewController(label: "Host App – Browse")
        browse.tabBarItem = UITabBarItem(
            title: "Browse",
            image: UIImage(systemName: "magnifyingglass"),
            selectedImage: UIImage(systemName: "magnifyingglass.circle.fill")
        )

        let profile = HostPlaceholderViewController(label: "Host App – Profile")
        profile.tabBarItem = UITabBarItem(
            title: "Profile",
            image: UIImage(systemName: "person"),
            selectedImage: UIImage(systemName: "person.fill")
        )

        viewControllers = [home, browse, profile]
        selectedIndex = 0
    }

    private func configureAppearance() {
        view.backgroundColor = DemoPalette.background
        tabBar.tintColor = DemoPalette.accent
        tabBar.unselectedItemTintColor = DemoPalette.secondaryText

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = DemoPalette.chrome
        appearance.shadowColor = DemoPalette.separator
        appearance.selectionIndicatorTintColor = DemoPalette.chromeSelected

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = DemoPalette.secondaryText
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: DemoPalette.secondaryText,
            .font: UIFont.systemFont(ofSize: 13, weight: .medium)
        ]
        itemAppearance.selected.iconColor = DemoPalette.accent
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: DemoPalette.accent,
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - Placeholder Tab

/// A trivial view controller showing a centered label, used to make the host
/// app visually distinct from the SDK's overlay UI.
final class HostPlaceholderViewController: UIViewController {

    private let titleLabel = UILabel()
    private let hapticButton = UIButton(type: .system)
    private let selfCheckButton = UIButton(type: .system)
    private let labelText: String
    private let showsHapticButton: Bool
    private lazy var hapticGenerator = makeHapticGenerator()

    init(label: String, showsHapticButton: Bool = false) {
        self.labelText = label
        self.showsHapticButton = showsHapticButton
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DemoPalette.background

        titleLabel.text = labelText
        titleLabel.font = .systemFont(ofSize: 22, weight: .medium)
        titleLabel.textColor = DemoPalette.primaryText
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        view.addSubview(titleLabel)

        guard showsHapticButton else { return }
        hapticButton.setTitle("Haptic", for: .normal)
        hapticButton.setImage(UIImage(systemName: "waveform.path"), for: .normal)
        hapticButton.tintColor = DemoPalette.accent
        hapticButton.setTitleColor(DemoPalette.accent, for: .normal)
        hapticButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        hapticButton.backgroundColor = DemoPalette.chrome
        hapticButton.layer.cornerRadius = 10
        hapticButton.layer.borderWidth = 1
        hapticButton.layer.borderColor = DemoPalette.separator.cgColor
        hapticButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        hapticButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        hapticButton.addTarget(self, action: #selector(playHapticFeedback), for: .touchDown)
        hapticButton.addTarget(self, action: #selector(playHapticFeedback), for: .touchUpInside)
        view.addSubview(hapticButton)

        selfCheckButton.setTitle("能力自检", for: .normal)
        selfCheckButton.setImage(UIImage(systemName: "checkmark.seal"), for: .normal)
        selfCheckButton.tintColor = DemoPalette.accent
        selfCheckButton.setTitleColor(DemoPalette.accent, for: .normal)
        selfCheckButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        selfCheckButton.backgroundColor = DemoPalette.chrome
        selfCheckButton.layer.cornerRadius = 10
        selfCheckButton.layer.borderWidth = 1
        selfCheckButton.layer.borderColor = DemoPalette.separator.cgColor
        selfCheckButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        selfCheckButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        selfCheckButton.addTarget(self, action: #selector(runCapabilitySelfCheck), for: .touchUpInside)
        view.addSubview(selfCheckButton)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let labelW = bounds.width - 48
        let labelH: CGFloat = 60
        titleLabel.frame = CGRect(
            x: (bounds.width - labelW) / 2,
            y: (bounds.height - labelH) / 2,
            width: labelW,
            height: labelH
        )

        guard showsHapticButton else { return }
        let buttonSize = hapticButton.sizeThatFits(CGSize(width: labelW, height: 48))
        hapticButton.frame = CGRect(
            x: (bounds.width - buttonSize.width) / 2,
            y: titleLabel.frame.maxY + 16,
            width: buttonSize.width,
            height: 44
        )

        let scSize = selfCheckButton.sizeThatFits(CGSize(width: labelW, height: 48))
        selfCheckButton.frame = CGRect(
            x: (bounds.width - scSize.width) / 2,
            y: hapticButton.frame.maxY + 12,
            width: scSize.width,
            height: 44
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        hapticButton.layer.borderColor = DemoPalette.separator.cgColor
        selfCheckButton.layer.borderColor = DemoPalette.separator.cgColor
    }

    @objc private func runCapabilitySelfCheck() {
        selfCheckButton.isEnabled = false
        Task { @MainActor in
            let session: AISession
            if let existing = DemoAgentHolder.currentSession() {
                session = existing
            } else {
                session = await CapabilitySelfCheck.ephemeralSession()
            }
            let report = await CapabilitySelfCheck.run(session: session)
            self.selfCheckButton.isEnabled = true
            self.presentReport("能力自检结果", report)
        }
    }

    private func presentReport(_ title: String, _ body: String) {
        let vc = UIViewController()
        vc.title = title
        vc.view.backgroundColor = DemoPalette.background
        let textView = UITextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = DemoPalette.primaryText
        textView.backgroundColor = .clear
        textView.text = body
        textView.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
        ])
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissReport)
        )
        present(nav, animated: true)
    }

    @objc private func dismissReport() {
        presentedViewController?.dismiss(animated: true)
    }

    @objc private func playHapticFeedback() {
        hapticGenerator.prepare()
        hapticGenerator.impactOccurred(intensity: 1)
    }

    private func makeHapticGenerator() -> UIImpactFeedbackGenerator {
        if #available(iOS 17.5, *) {
            return UIImpactFeedbackGenerator(style: .heavy, view: view)
        } else {
            return UIImpactFeedbackGenerator(style: .heavy)
        }
    }
}
