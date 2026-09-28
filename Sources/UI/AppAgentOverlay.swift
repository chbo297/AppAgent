//
//  AppAgentOverlay.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// Single entry point for hosts that want AppAgent's chat UI as an overlay window
/// floating above their own `UIWindow` hierarchy.
///
/// `AppAgentOverlay` owns a passthrough `AppAgentWindow` plus an
/// `AppAgentViewController`. The overlay window does not steal key status from
/// the host; it auto-promotes to key only when the input bar's text field
/// becomes first responder.
@MainActor
public final class AppAgentOverlay {

    // MARK: - Public Properties

    /// The passthrough window mounted above the host's window.
    public let window: AppAgentWindow

    /// The chat view controller hosted inside `window`.
    public let viewController: AppAgentViewController

    // MARK: - Factories

    /// Create the overlay window in `windowScene` without binding any agent.
    /// The window becomes visible immediately; use `bind(agent:sessionId:)` later.
    @discardableResult
    public static func attach(in windowScene: UIWindowScene) -> AppAgentOverlay {
        AppAgentOverlay(windowScene: windowScene)
    }

    /// Create the overlay window, create a fresh session on `agent`, bind it, return.
    @discardableResult
    public static func start(
        in windowScene: UIWindowScene,
        agent: AIAgent,
        sessionTitle: String = "Chat"
    ) async -> AppAgentOverlay {
        let overlay = AppAgentOverlay(windowScene: windowScene)
        let session = await agent.createSession(title: sessionTitle)
        overlay.bind(agent: agent, sessionId: session.id)
        return overlay
    }

    // MARK: - Init

    private init(windowScene: UIWindowScene) {
        // 真机排查全靠这份落盘日志：挂上 overlay 就开始记，宿主不用写代码。
        // 调试面板的「导出全部数据」把它和会话快照一起打包带走。
        AppAgentRunLog.shared.install()
        let viewController = AppAgentViewController()
        self.viewController = viewController
        self.window = AppAgentWindow(
            windowScene: windowScene,
            rootViewController: viewController
        )
    }

    // MARK: - Binding

    /// Bind an agent + existing session id to the chat view controller.
    public func bind(agent: AIAgent, sessionId: String) {
        viewController.agent = agent
        viewController.switchSession(to: sessionId)
        viewController.currentSession?.inspectionSceneIdentifier = window.windowScene?.session.persistentIdentifier
    }

    // MARK: - Visibility

    public func show() {
        // window 隐藏/显示不保证触发 VC appearance；已可见时重复 show 不打断连续阅读。
        if window.isHidden {
            viewController.prepareChatForPresentation()
        }
        window.isHidden = false
        viewController.presentationDelegate?.appAgentChatPanelWillShow()
    }

    public func hide() {
        window.isHidden = true
        viewController.presentationDelegate?.appAgentChatPanelDidHide()
    }
}

#endif
