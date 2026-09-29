//
//  AppAgentViewController+SessionSidebar.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Session Sidebar（接线层）
//
// 侧栏自身负责半宽布局、列表渲染和动画；ViewController 只提供 Session 快照并处理选择结果。

extension AppAgentViewController {
    func setupSessionSidebar() {
        sessionSidebarView.frame = view.bounds
        sessionSidebarView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sessionSidebarView.onDismissRequested = { [weak self] in
            self?.hideSessionSidebar(animated: true)
        }
        sessionSidebarView.onSelectItem = { [weak self] item in
            self?.selectSessionSidebarItem(item)
        }
        sessionSidebarView.onRenameItem = { [weak self] item in
            self?.promptRenameSession(item)
        }
        sessionSidebarView.onDeleteItem = { [weak self] item in
            self?.promptArchiveSession(item)
        }
        sessionSidebarView.sessionListView.onTrashTapped = { [weak self] in
            self?.presentSessionTrash()
        }
        sessionSidebarView.onSettingsTapped = { [weak self] in
            self?.presentSettings()
        }
        sessionSidebarView.onDebugTapped = { [weak self] in
            self?.presentDebugConsole()
        }
        view.addSubview(sessionSidebarView)
        reloadSessionSidebarItems()
    }

    /// 打开 AppAgent 层级内的设置面板（用 overlay 窗口最上层 VC 呈现）。
    /// 落地页给两个入口：「模型配置」push 进模型/API 页；「总是显示思考过程」开关就地生效。
    /// 模型配置保存后应用新配置，并新建一个会话让改动立即生效（会话 provider 创建后不可变）。
    private func presentSettings() {
        let menuVC = AppAgentSettingsMenuViewController()
        menuVC.onModelSettingsSaved = { [weak self] settings in
            guard let self, let agent = self.agent else { return }
            Task { @MainActor in
                await agent.applyEndpointSettings(settings)
                let session = await agent.createSession(title: "对话")
                self.switchSession(to: session.id)
            }
        }
        menuVC.onAlwaysShowThinkingChanged = { [weak self] _ in
            // 设置改变后按「重新浏览」语义重建当前会话列表，让成功轮的过程入口显隐立即生效。
            self?.reloadFromSession(reason: .browsing)
        }
        let nav = UINavigationController(rootViewController: menuVC)
        nav.modalPresentationStyle = .formSheet

        hideSessionSidebar(animated: false)
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(nav, animated: true)
    }

    /// 打开调试窗口：实时看模型接口的失败 / 重试 / 回退记录，并可导出。
    private func presentDebugConsole() {
        let debugVC = AppAgentDebugViewController()
        let nav = UINavigationController(rootViewController: debugVC)
        nav.modalPresentationStyle = .formSheet

        hideSessionSidebar(animated: false)
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(nav, animated: true)
    }

    /// 弹出重命名输入框，提交后重命名会话并立即存盘。

    private func promptRenameSession(_ item: AppAgentSessionSidebarItem) {
        guard let sessionID = item.sessionID,
              let session = agent?.session(id: sessionID) else { return }
        let alert = UIAlertController(title: "重命名会话", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = session.title
            field.placeholder = "会话名称"
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "rename_session_field"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            guard let self, let newTitle = alert?.textFields?.first?.text else { return }
            session.rename(newTitle)
            self.reloadSessionSidebarItems()
            Task { try? await self.agent?.sessionManager.saveSession(session) }
        })
        // 侧栏是加在 self.view 上的覆盖层，用最上层 VC 呈现 alert。
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(alert, animated: true)
    }

    /// 左侧导航按钮的统一入口；重复点击时从当前动画状态反向播放。
    func toggleSessionSidebar() {
        if sessionSidebarView.isPresented {
            hideSessionSidebar(animated: true)
        } else {
            showSessionSidebar(animated: true)
        }
    }

    func showSessionSidebar(animated: Bool) {
        reloadSessionSidebarItems()
        view.bringSubviewToFront(sessionSidebarView)
        if !voiceInputOverlayView.isHidden {
            view.bringSubviewToFront(voiceInputOverlayView)
        }
        sessionSidebarView.setPresented(true, animated: animated)
        notifyPresentationChangeIfNeeded(reason: .visibility)
    }

    func hideSessionSidebar(animated: Bool) {
        sessionSidebarView.setPresented(false, animated: animated)
        notifyPresentationChangeIfNeeded(reason: .visibility)
    }

    /// 刷新真实 Session；当前数量不足时补演示数据，后续接入完整多 Session 后无需改列表组件。
    func reloadSessionSidebarItems() {
        guard isViewLoaded else { return }

        let sessions = agent?.allSessions ?? []
        var items = sessions.map { session in
            let messageCount = session.messages.count
            return AppAgentSessionSidebarItem(
                sessionID: session.id,
                title: normalizedSessionTitle(session.title),
                detail: messageCount == 0 ? "暂无消息" : "\(messageCount) 条消息",
                isSelected: session.id == currentSessionId
            )
        }

        let remainingDemoCount = max(0, Self.sessionSidebarDemoItems.count - items.count)
        if remainingDemoCount > 0 {
            items.append(contentsOf: Self.sessionSidebarDemoItems.prefix(remainingDemoCount))
        }

        sessionSidebarView.setItems(items)
        chatPanelView.navigationBar.title = currentSession.map { normalizedSessionTitle($0.title) } ?? "对话"
    }

    private func selectSessionSidebarItem(_ item: AppAgentSessionSidebarItem) {
        if let sessionID = item.sessionID,
           sessionID != currentSessionId,
           agent?.session(id: sessionID) != nil {
            switchSession(to: sessionID)
        }
        hideSessionSidebar(animated: true)
    }

    private func normalizedSessionTitle(_ title: String) -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "未命名会话" : normalized
    }

    private static let sessionSidebarDemoItems: [AppAgentSessionSidebarItem] = [
        AppAgentSessionSidebarItem(
            sessionID: nil,
            title: "产品方案讨论",
            detail: "演示会话",
            isSelected: false
        ),
        AppAgentSessionSidebarItem(
            sessionID: nil,
            title: "本周计划",
            detail: "演示会话",
            isSelected: false
        ),
        AppAgentSessionSidebarItem(
            sessionID: nil,
            title: "旅行灵感",
            detail: "演示会话",
            isSelected: false
        ),
        AppAgentSessionSidebarItem(
            sessionID: nil,
            title: "随手记录",
            detail: "演示会话",
            isSelected: false
        )
    ]
}

#endif
