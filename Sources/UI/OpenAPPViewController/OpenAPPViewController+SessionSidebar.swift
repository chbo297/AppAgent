//
//  OpenAPPViewController+SessionSidebar.swift
//  OpenAPPUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Session Sidebar（接线层）
//
// 侧栏自身负责半宽布局、列表渲染和动画；ViewController 只提供 Session 快照并处理选择结果。

extension OpenAPPViewController {
    func setupSessionSidebar() {
        sessionSidebarView.frame = view.bounds
        sessionSidebarView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sessionSidebarView.onDismissRequested = { [weak self] in
            self?.hideSessionSidebar(animated: true)
        }
        sessionSidebarView.onSelectItem = { [weak self] item in
            self?.selectSessionSidebarItem(item)
        }
        view.addSubview(sessionSidebarView)
        reloadSessionSidebarItems()
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
            return OpenAPPSessionSidebarItem(
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

    private func selectSessionSidebarItem(_ item: OpenAPPSessionSidebarItem) {
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

    private static let sessionSidebarDemoItems: [OpenAPPSessionSidebarItem] = [
        OpenAPPSessionSidebarItem(
            sessionID: nil,
            title: "产品方案讨论",
            detail: "演示会话",
            isSelected: false
        ),
        OpenAPPSessionSidebarItem(
            sessionID: nil,
            title: "本周计划",
            detail: "演示会话",
            isSelected: false
        ),
        OpenAPPSessionSidebarItem(
            sessionID: nil,
            title: "旅行灵感",
            detail: "演示会话",
            isSelected: false
        ),
        OpenAPPSessionSidebarItem(
            sessionID: nil,
            title: "随手记录",
            detail: "演示会话",
            isSelected: false
        )
    ]
}

#endif
