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
            self?.promptDeleteSession(item)
        }
        view.addSubview(sessionSidebarView)
        reloadSessionSidebarItems()
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

    /// 弹出删除确认；确认后删除会话并存盘。若删的是当前会话，则切到最近的其它会话，
    /// 没有其它会话时新建一个空会话，避免出现无当前会话的空态。
    private func promptDeleteSession(_ item: AppAgentSessionSidebarItem) {
        guard let sessionID = item.sessionID,
              agent?.session(id: sessionID) != nil else { return }
        let alert = UIAlertController(
            title: "删除会话",
            message: "确定删除「\(item.title)」？该操作不可撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.performDeleteSession(sessionID)
        })
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(alert, animated: true)
    }

    private func performDeleteSession(_ sessionID: String) {
        guard let agent else { return }
        let deletingCurrent = (sessionID == currentSessionId)
        Task { @MainActor in
            try? await agent.deleteSession(sessionID)
            if deletingCurrent {
                if let next = agent.allSessions.first {
                    self.switchSession(to: next.id)
                } else {
                    let fresh = await agent.createSession(title: "对话")
                    self.switchSession(to: fresh.id)
                }
            }
            self.reloadSessionSidebarItems()
        }
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
    }

    func hideSessionSidebar(animated: Bool) {
        sessionSidebarView.setPresented(false, animated: animated)
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
