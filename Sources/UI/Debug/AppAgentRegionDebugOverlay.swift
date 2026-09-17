//
//  AppAgentRegionDebugOverlay.swift
//  AppAgentUI
//
//  比 AppAgentWindow 更高一层的调试窗口：一颗浮动 debug 按钮 + 三个开关，
//  分别用红 / 黄 / 蓝 1pt 边框把「点击输入区域」「上滑触发键盘区域」
//  「上滑触发对话列表面板区域」实时框出来。
//

#if canImport(UIKit)
import UIKit

/// 四类可被框出来的交互响应区域。
public enum AppAgentInteractionRegion: CaseIterable {
    /// 点击后弹起键盘的输入区域（已按 bar 白色背景高度纵向扩大）。
    case inputTap
    /// 在输入区域上向上滑唤起键盘的区域（同样扩大；生效还需处于键盘模式且未聚焦）。
    case keyboardSwipe
    /// 上滑改变对话列表面板档位的区域（面板内容命中区）。
    case chatPanelSwipe
    /// 底部 bar 自身的响应区域——它遮住下面的对话面板与宿主 app。
    case inputBarHit

    var title: String {
        switch self {
        case .inputTap: return "点击输入区域"
        case .keyboardSwipe: return "上滑触发键盘区域"
        case .chatPanelSwipe: return "上滑触发对话列表面板区域"
        case .inputBarHit: return "底部 bar 响应区域"
        }
    }

    var color: UIColor {
        switch self {
        case .inputTap: return .systemRed
        case .keyboardSwipe: return .systemYellow
        case .chatPanelSwipe: return .systemBlue
        case .inputBarHit: return .systemGreen
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .inputTap: return "appagent.regionDebug.inputTap"
        case .keyboardSwipe: return "appagent.regionDebug.keyboardSwipe"
        case .chatPanelSwipe: return "appagent.regionDebug.chatPanelSwipe"
        case .inputBarHit: return "appagent.regionDebug.inputBarHit"
        }
    }
}

/// 调试窗口的门面。宿主 app 一行 attach 即可，窗口层级高于 AppAgent 的 overlay window。
@MainActor
public final class AppAgentRegionDebugOverlay {

    public let window: UIWindow
    public let viewController: AppAgentRegionDebugViewController

    @discardableResult
    public static func attach(
        in windowScene: UIWindowScene,
        target: AppAgentViewController
    ) -> AppAgentRegionDebugOverlay {
        AppAgentRegionDebugOverlay(windowScene: windowScene, target: target)
    }

    private init(windowScene: UIWindowScene, target: AppAgentViewController) {
        let controller = AppAgentRegionDebugViewController()
        controller.target = target
        self.viewController = controller
        // AppAgentWindow 用的是 .normal + 1，这里再高一层，确保按钮永远在最上面。
        let window = AppAgentRegionDebugWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.backgroundColor = .clear
        window.windowLevel = .normal + 2
        window.isHidden = false
        self.window = window
    }

    public func show() { window.isHidden = false }

    public func hide() { window.isHidden = true }
}

/// 除调试按钮/面板本身以外全部穿透的窗口。
final class AppAgentRegionDebugWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

/// 单个区域的 1pt 边框 + 角标。
final class AppAgentRegionOutlineView: UIView {
    private let nameLabel = UILabel()

    init(region: AppAgentInteractionRegion) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.borderWidth = 1
        layer.borderColor = region.color.cgColor

        nameLabel.text = region.title
        nameLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.backgroundColor = region.color
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
