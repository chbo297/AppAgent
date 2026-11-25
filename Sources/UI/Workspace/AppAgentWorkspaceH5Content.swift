import Foundation

enum AppAgentWorkspaceH5Error: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

/// 页面实际加载的 H5：从会话的工作区数据取出，交给 scheme handler。
/// 内容相同就不重新加载，所以只放影响加载结果的字段；页面状态另走桥脚本注入，不在这里。
struct AppAgentWorkspaceH5Content: Equatable {
    let title: String

    /// 插槽层显示时，H5 背景透明，透明处的触摸交给插槽视图。
    let hasSlot: Bool

    /// `index.html` 的内容；页面没写文件时为空，只露出插槽层。
    let html: String

    /// 除 `index.html` 外的文件，按相对路径加载。
    let resources: [String: String]

    init(workspace: SessionWorkspace, fallbackTitle: String) throws {
        if let violation = SessionWorkspaceLimits.violation(in: workspace) {
            throw AppAgentWorkspaceH5Error.invalid(violation)
        }
        let suppliedTitle = workspace.title
        title = suppliedTitle.isEmpty ? (fallbackTitle.isEmpty ? "工作区" : fallbackTitle) : suppliedTitle
        hasSlot = workspace.shownSlot != nil
        html = workspace.h5.files["index.html"] ?? ""
        var others = workspace.h5.files
        others.removeValue(forKey: "index.html")
        resources = others
    }

    static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "css":
            return "text/css"
        case "js":
            return "application/javascript"
        case "json":
            return "application/json"
        case "svg":
            return "image/svg+xml"
        default:
            return "text/html"
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
