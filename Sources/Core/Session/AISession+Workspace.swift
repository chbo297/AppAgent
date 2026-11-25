//
//  AISession+Workspace.swift
//  AppAgent
//
//  改本会话的对话面板档位和工作区数据。只改数据并落盘；界面由 UI 层观察
//  `uiState` 的对应 key，在这个会话是当前会话时应用。
//

import Foundation

public struct SessionWorkspaceError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

extension AISession {

    /// `uiState.onChange` 在对话面板档位变化时带的 key。
    public static let chatPanelChangedKey = "chatPanel"

    /// 工作区数据变了（不论是不是当前会话）。object 为该 AISession。界面和宿主状态都听它。
    public static let workspaceDidChangeNotification = Notification.Name("AISessionWorkspaceDidChange")

    public func setChatPanel(_ panel: SessionChatPanel) {
        guard panel != chatPanel else {
            return
        }
        chatPanel = panel
        uiState.set(Self.chatPanelChangedKey, value: panel.rawValue)
        persistSoon()
    }

    /// 改本会话的工作区：改完整体校验，超限或 `change` 抛错就整笔不改。返回改后的数据。
    @discardableResult
    public func updateWorkspace(_ change: (inout SessionWorkspace) throws -> Void) throws -> SessionWorkspace {
        let result: Result<(SessionWorkspace, Bool), Error> = $workspace.mutate { value in
            var next = value
            do {
                try change(&next)
            } catch {
                return .failure(error)
            }
            if let violation = SessionWorkspaceLimits.violation(in: next) {
                return .failure(SessionWorkspaceError(violation))
            }
            let changed = next != value
            value = next
            return .success((next, changed))
        }
        let (next, changed) = try result.get()
        if changed {
            persistSoon()
            NotificationCenter.default.post(name: Self.workspaceDidChangeNotification, object: self)
        }
        return next
    }

    /// 界面数据（面板、工作区）不走一轮结束时的自动保存，改完就存。页面 setState、插槽回写可能很密，
    /// 一个窗口内的多次改动合并成一次整份保存；清掉排队标记后再取快照，之后的改动会再排一次，不会漏存。
    private func persistSoon() {
        guard let manager = agentMask?.agent?.sessionManager else {
            return
        }
        let shouldSchedule = $interfaceSavePending.mutate { pending -> Bool in
            guard !pending else {
                return false
            }
            pending = true
            return true
        }
        guard shouldSchedule else {
            return
        }
        let session = self
        Task {
            try? await Task.sleep(nanoseconds: Self.interfaceSaveDelay)
            session.interfaceSavePending = false
            try? await manager.saveSession(session)
        }
    }

    private static let interfaceSaveDelay: UInt64 = 300_000_000
}
