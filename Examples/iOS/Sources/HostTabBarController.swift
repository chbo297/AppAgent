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
        configureChromeButton(hapticButton,
                              title: "Haptic",
                              systemImage: "waveform.path")
        hapticButton.addTarget(self, action: #selector(playHapticFeedback), for: .touchDown)
        hapticButton.addTarget(self, action: #selector(playHapticFeedback), for: .touchUpInside)
        view.addSubview(hapticButton)

        configureChromeButton(selfCheckButton,
                              title: "能力自检",
                              systemImage: "checkmark.seal")
        selfCheckButton.addTarget(self, action: #selector(runCapabilitySelfCheck), for: .touchUpInside)
        view.addSubview(selfCheckButton)
    }

    /// 图标 + 标题的小胶囊按钮。`contentEdgeInsets` / `imageEdgeInsets` 在 iOS 15 起
    /// 被 `UIButton.Configuration` 取代（设了 configuration 之后这两个属性会被忽略），
    /// 所以内距、图标间距、字体、前景色一并走 configuration；背景色和圆角/描边仍留在
    /// layer 上（configuration 的 background 显式置空，不参与绘制）。
    private func configureChromeButton(_ button: UIButton, title: String, systemImage: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: systemImage)
        // 旧写法：contentEdgeInsets(10, 16, 10, 16) —— 数值一一对应，left/right → leading/trailing。
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        // 旧写法：imageEdgeInsets(0, -4, 0, 4) 只是把图标往左推 4pt，制造图标与标题之间
        // 的 4pt 间隙（宽度贡献 -4 + 4 = 0），configuration 里就是 imagePadding = 4。
        config.imagePadding = 4
        config.baseForegroundColor = DemoPalette.accent
        // 旧写法没给 image 配 symbol configuration，SF Symbol 走 `UIImage(systemName:)`
        // 的默认口径（.body 文本样式）。configuration 有可能按标题字体另算一套，这里
        // 显式钉住默认口径，图标尺寸就和改前完全一致。
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        // configuration 会接管标题属性，`titleLabel.font` 不再生效，字体在这里保住。
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 16, weight: .semibold)
            return outgoing
        }
        config.background = .clear()
        button.configuration = config
        button.tintColor = DemoPalette.accent
        button.backgroundColor = DemoPalette.chrome
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1
        button.layer.borderColor = DemoPalette.separator.cgColor
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
