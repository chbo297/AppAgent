//
//  AppAgentActivityTimeline.swift
//  AppAgentUI
//
//  一轮回答的「过程」时间线：思考（reasoning）+ 工具执行，供聊天气泡上方的可折叠区展示。
//  参考 Codex CLI / ChatGPT app：进行中显示当前步骤与摘要，结束后折叠成
//  「已思考 12.3 秒 · 3 步」一行，点开可看全过程；最终答案仍在气泡里单独展示。
//

#if canImport(UIKit)
import Foundation

/// 过程中的一步。
public struct AppAgentActivityItem: Equatable {
    public enum Kind: Equatable {
        case thinking
        case tool
    }

    public enum State: Equatable {
        case running
        case done
        case failed
    }

    public var id: String
    public var kind: Kind
    /// 一行标题：思考步骤为「思考」，工具步骤为工具名。
    public var title: String
    /// 展开后的正文：思考内容 / 工具参数与结果。
    public var detail: String
    public var state: State
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: String,
        kind: Kind,
        title: String,
        detail: String = "",
        state: State = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// 一轮回答的完整过程。值类型，UI 直接持有快照渲染。
public struct AppAgentActivityTimeline: Equatable {

    public private(set) var items: [AppAgentActivityItem] = []
    public private(set) var startedAt: Date
    public private(set) var finishedAt: Date?

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    public var isRunning: Bool { finishedAt == nil }
    public var isEmpty: Bool { items.isEmpty }
    /// 工具执行步数（思考不计步，和 Codex 的「N 步」一致）。
    public var stepCount: Int { items.filter { $0.kind == .tool }.count }
    public func elapsed(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    // MARK: - 累积

    /// 追加思考增量：连续的思考并进同一步，被工具打断后开新的一步。
    public mutating func appendThinking(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let index = items.indices.last, items[index].kind == .thinking, items[index].state == .running {
            items[index].detail += delta
        } else {
            items.append(AppAgentActivityItem(
                id: "thinking-\(items.count)", kind: .thinking, title: "思考", detail: delta
            ))
        }
    }

    /// 工具开始执行；同时把仍在进行的思考步骤收尾。
    public mutating func startTool(id: String, name: String, argumentsPreview: String) {
        closeRunningThinking()
        let detail = argumentsPreview.isEmpty ? "" : "参数：\(argumentsPreview)"
        items.append(AppAgentActivityItem(id: id, kind: .tool, title: name, detail: detail))
    }

    public mutating func finishTool(id: String, resultPreview: String) {
        guard let index = items.lastIndex(where: { $0.id == id && $0.kind == .tool }) else { return }
        items[index].state = .done
        items[index].finishedAt = Date()
        if !resultPreview.isEmpty {
            items[index].detail += items[index].detail.isEmpty ? "结果：\(resultPreview)" : "\n结果：\(resultPreview)"
        }
    }

    public mutating func failTool(id: String, name: String, message: String) {
        if let index = items.lastIndex(where: { $0.id == id && $0.kind == .tool }) {
            items[index].state = .failed
            items[index].finishedAt = Date()
            items[index].detail += items[index].detail.isEmpty ? "失败：\(message)" : "\n失败：\(message)"
        } else {
            items.append(AppAgentActivityItem(
                id: id, kind: .tool, title: name, detail: "失败：\(message)",
                state: .failed, finishedAt: Date()
            ))
        }
    }

    /// 整轮结束：收尾所有进行中的步骤。
    public mutating func finish(at date: Date = Date()) {
        guard finishedAt == nil else { return }
        for index in items.indices where items[index].state == .running {
            items[index].state = .done
            items[index].finishedAt = date
        }
        finishedAt = date
    }

    private mutating func closeRunningThinking() {
        for index in items.indices where items[index].kind == .thinking && items[index].state == .running {
            items[index].state = .done
            items[index].finishedAt = Date()
        }
    }

    // MARK: - 摘要（折叠时显示）

    /// 折叠行主标题：进行中显示当前动作，结束后显示「已思考 x 秒 · N 步」。
    public func headerTitle(now: Date = Date()) -> String {
        if isRunning {
            if let last = items.last {
                switch last.kind {
                case .tool where last.state == .running: return "执行 \(last.title)…"
                case .tool: return "已完成 \(last.title)，继续思考…"
                case .thinking: return "思考中…"
                }
            }
            return "思考中…"
        }
        let seconds = String(format: "%.1f", max(0, elapsed(now: now)))
        return stepCount > 0 ? "已思考 \(seconds) 秒 · \(stepCount) 步" : "已思考 \(seconds) 秒"
    }

    /// 折叠行副标题：最新思考的一句话摘要（没有思考内容时给工具名序列）。
    public var headerSummary: String? {
        if let snippet = latestThinkingSnippet { return snippet }
        let tools = items.filter { $0.kind == .tool }.map { $0.title }
        return tools.isEmpty ? nil : tools.suffix(3).joined(separator: " → ")
    }

    /// 思考文本里最后一段有内容的话，压成一行并截断，作为摘要。
    public var latestThinkingSnippet: String? {
        guard let text = items.last(where: { $0.kind == .thinking })?.detail else { return nil }
        let lines = text
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return last.count <= 64 ? last : String(last.prefix(64)) + "…"
    }
}

#endif
