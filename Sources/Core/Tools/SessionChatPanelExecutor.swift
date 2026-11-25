//
//  SessionChatPanelExecutor.swift
//  AppAgent
//

import Foundation

/// `session` 工具的 op='chat_panel'：设置本会话的对话面板档位。
///
/// 只改会话数据（随会话落盘）；这个会话在屏幕上时 UI 层立即应用，否则切过去时再应用。
/// 输入框是小球还是展开是全局的，不在这里改。
struct SessionChatPanelExecutor: ToolProtocol {
    let name = "session.chat_panel"

    let description = """
        Set how far this conversation's chat panel opens: collapsed (only the input bar), half or full. \
        Use collapsed when the user should look at what is underneath (an App page or this conversation's \
        workspace); open it again when there is important conversation content to show.
        """
    let parameters = Tool.Schema(
        properties: [
            "state": .string(
                description: "collapsed, half or full.",
                enumValues: SessionChatPanel.allCases.map(\.rawValue)
            )
        ],
        required: ["state"]
    )
    let group: String = "session"
    let safetyLevel: Tool.SafetyLevel = .moderate

    init() {}

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let raw = arguments["state"]?.stringValue, let panel = SessionChatPanel(rawValue: raw) else {
            return .error("state must be collapsed, half or full.")
        }
        session.setChatPanel(panel)
        return .json(.object([
            "chatPanel": .string(panel.rawValue)
        ]))
    }
}
