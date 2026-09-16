//
//  SceneDelegate.swift
//  AppAgentDemo
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var hostWindow: UIWindow?
    var openAPPOverlay: AppAgentOverlay?
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
        // `-run-selfcheck` to run every host-introspection + session tool once
        // and print the report to the log, then skip normal chat wiring. Works
        // without any provider config (tools execute without the model).
        if ProcessInfo.processInfo.arguments.contains("-run-selfcheck") {
            Task { @MainActor in
                let session = await CapabilitySelfCheck.ephemeralSession()
                let report = await CapabilitySelfCheck.run(session: session)
                NSLog("APPAGENT_SELFCHECK_BEGIN\n%@\nAPPAGENT_SELFCHECK_END", report)
            }
        }

        // 1) Host app's own window (any normal iOS app would do this).
        let host = UIWindow(windowScene: windowScene)
        host.rootViewController = HostTabBarController()
        host.makeKeyAndVisible()
        self.hostWindow = host

        // 2) SDK chat UI – mounted in its own independent overlay window.
        Task { @MainActor in
            guard DemoConfig.loaded != nil, DemoConfig.hasUsableProviderConfig else {
                if let presenter = host.rootViewController {
                    showAlert(
                        on: presenter,
                        title: "配置未完成",
                        message: "请复制示例配置并填入 API key:\ncp Examples/iOS/Resources/config.json.example Examples/iOS/Resources/config.json\n\n然后重新运行 demo。"
                    )
                }
                return
            }

            for entry in DemoConfig.allProviders {
                await ModelProviderCentral.`default`.register(
                    name: entry.name,
                    provider: entry.provider
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
                modelPolicy: DemoConfig.modelPolicy,
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
