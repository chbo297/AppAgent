//
//  SceneDelegate.swift
//  AppAgentDemo
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var hostWindow: UIWindow?
    var openAPPOverlay: AppAgentOverlay?
    var regionDebugOverlay: AppAgentRegionDebugOverlay?
    var agent: AIAgent?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        Logger.isEnabled = true
        Logger.minimumLevel = .debug

        // Headless capability self-check for simulator/CI: launch with
        // `-run-selfcheck` to run every tool once, write the report to
        // Documents/selfcheck-report.txt and emit it to the log. It runs *after*
        // the overlay is mounted (see the end of the setup task below) so the
        // view-hierarchy dump covers the SDK's own overlay window too, and the
        // "no API key" alert is suppressed so it does not pollute that dump.
        // Works without any provider config — tools execute without the model.
        let isSelfCheck = ProcessInfo.processInfo.arguments.contains("-run-selfcheck")
        // 样例对话同样是无模型跑法，别让「未配置 API Key」的弹窗盖住要看的面板。
        let showsSampleConversation =
            ProcessInfo.processInfo.arguments.contains("-show-sample-conversation")

        // 1) Host app's own window (any normal iOS app would do this).
        let host = UIWindow(windowScene: windowScene)
        let tabs = HostTabBarController()
        host.rootViewController = tabs
        host.makeKeyAndVisible()
        self.hostWindow = host
        DemoAgentHolder.hostTabBarController = tabs

        // 2) SDK chat UI – mounted in its own independent overlay window.
        Task { @MainActor in
            // AppAgent 默认接口为 OneAPI；用户可在会话列表右上角的「设置」里填写自己的 API Key、
            // 拉取并勾选模型。已保存过设置则用保存值，否则回落到 OneAPI 默认（apiKey 为空）。
            let settings = AppAgentSettingsStore.loadOrDefault()
            await ModelProviderCentral.`default`.register(settings: settings)

            if !settings.hasUsableAPIKey, !isSelfCheck, !showsSampleConversation, let presenter = host.rootViewController {
                showAlert(
                    on: presenter,
                    title: "尚未配置 API Key",
                    message: "AppAgent 默认使用 OneAPI 接口。请点开对话面板会话列表右上角的「设置」填写 API Key、拉取并勾选模型后即可开始对话。"
                )
            }

            let agentProfile = AIAgentProfile(
                identity: "You are a helpful AI assistant.",
                additionalPromptBuilders: [
                    PromptBuilder("Be concise and helpful."),
                    PromptBuilder("If unsure, say so honestly.")
                ]
            )

            let agent = await AIAgentCentral.default.create(
                name: "main",
                profile: agentProfile,
                modelPolicy: settings.modelPolicy,
                sessionStorage: FileSessionStorage()
            )
            self.agent = agent

            // Restore sessions persisted from a previous launch so conversation
            // history survives the app being killed.
            try? await agent.restoreAll()

            let overlay: AppAgentOverlay
            if let latest = agent.allSessions.first {
                // Resume the most recently updated restored session.
                overlay = AppAgentOverlay.attach(in: windowScene)
                overlay.bind(agent: agent, sessionId: latest.id)
                DemoAgentHolder.currentSessionId = latest.id
            } else {
                // Fresh install / no history — create a new session.
                overlay = await AppAgentOverlay.start(in: windowScene, agent: agent)
                DemoAgentHolder.currentSessionId = agent.allSessions.first?.id
            }
            DemoAgentHolder.agent = agent
            self.openAPPOverlay = overlay

            #if DEBUG
            // 比 AppAgent overlay 再高一层的调试窗口：👻 按钮里可以开关三类响应区域的边框。
            self.regionDebugOverlay = AppAgentRegionDebugOverlay.attach(
                in: windowScene,
                target: overlay.viewController
            )
            #endif

            if isSelfCheck {
                let session = await CapabilitySelfCheck.ephemeralSession()
                _ = await CapabilitySelfCheck.run(session: session)
            }

            #if DEBUG
            // `-show-sample-conversation`：灌一段样例对话并展开面板，用来肉眼验收
            // 对话列表的分层（一次提问一个气泡 + 过程折叠）与 markdown 渲染。
            if ProcessInfo.processInfo.arguments.contains("-show-sample-conversation"),
               let sessionId = DemoAgentHolder.currentSessionId,
               let session = agent.allSessions.first(where: { $0.id == sessionId }) {
                SampleConversation.install(into: session)
                overlay.show()
                // show() 之后视图才加载完，列表内容要再灌一次才拿得到。
                DispatchQueue.main.async {
                    overlay.viewController.reloadFromSession(forceScrollToBottom: true)
                }
            }

            // `-show-decision-card`：展开面板并真的发一次私网授权请求，让 AppAgent
            // 自己的决策卡片走完整链路弹出来（截图人工验观感用）。2s 后自动点「拒绝」，
            // 免得留一个永远等着的 continuation。
            if ProcessInfo.processInfo.arguments.contains("-show-decision-card"),
               let sessionId = DemoAgentHolder.currentSessionId,
               let session = agent.allSessions.first(where: { $0.id == sessionId }) {
                overlay.show()
                overlay.viewController.debugPresentDecision(
                    .privateNetworkAccess(host: "10.0.0.5",
                                          url: "http://10.0.0.5/admin/api/users"),
                    on: session,
                    autoTapOptionId: "deny",
                    after: 30
                )
            }
            #endif
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Persist all sessions when going to background.
        Task {
            try? await agent?.sessionManager.saveAll()
        }
    }

    private func showAlert(on viewController: UIViewController, title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        viewController.present(alert, animated: true)
    }
}
