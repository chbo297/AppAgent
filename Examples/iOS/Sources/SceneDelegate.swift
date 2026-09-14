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
                sessionStorage: InMemorySessionStorage()
            )
            self.agent = agent

            self.openAPPOverlay = await AppAgentOverlay.start(
                in: windowScene,
                agent: agent
            )
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
