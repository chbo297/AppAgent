//
//  AppAgentActivityTranscript.swift
//  AppAgentUI
//
//  参考 openai/codex 的 tui/src/exec_cell/compact.rs：
//  • 动作主行 + └ 输出分支。预览裁剪只发生在展示层，展开仍能看到完整内容。
//

#if canImport(UIKit)
import Foundation

enum AppAgentActivityTranscript {
    static let previewLineCount = 3

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

    static func detail(_ text: String, expanded: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let lines = text.components(separatedBy: .newlines)
        let visible = expanded ? lines : Array(lines.suffix(previewLineCount))
        var output = visible.enumerated().map { index, line in
            let content = expanded ? line : ChatMessageAssembler.compact(line, limit: 100)
            return (index == 0 ? "  └ " : "    ") + content
        }
        if !expanded, lines.count > previewLineCount {
            output.insert("    …", at: 0)
        }
        return output.joined(separator: "\n")
    }
}
#endif
