//
//  AppAgentActivityTranscript.swift
//  AppAgentUI
//
//  参考 openai/codex 的 tui/src/exec_cell/compact.rs：
//  • 动作主行 + └ 输出分支。收起时不渲染明细，展开给全文、不做裁剪。
//

#if canImport(UIKit)
import Foundation

enum AppAgentActivityTranscript {
    static func heading(for item: AppAgentActivityItem) -> String {
        if item.kind == .thinking { return "• 思考" }
        let verb: String
        switch item.state {
        case .running: verb = "正在调用"
        case .done: verb = "已调用"
        case .failed: verb = "调用失败"
        }
        return "• \(verb) \(item.title)"
    }

    /// 展开后的明细：首行挂 `└`，续行对齐缩进，全文不裁剪
    /// （工具输出预算由 Core 管，展示层不再二次截断）。
    static func detail(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return text.components(separatedBy: .newlines)
            .enumerated()
            .map { index, line in (index == 0 ? "  └ " : "    ") + line }
            .joined(separator: "\n")
    }
}
#endif
