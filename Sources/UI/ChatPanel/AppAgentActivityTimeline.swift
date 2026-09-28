//
//  AppAgentActivityTimeline.swift
//  AppAgentUI
//
//  一轮回答的「过程」时间线：思考（reasoning）+ 工具执行，供聊天气泡上方的可折叠区展示。
//  参考 Codex CLI / ChatGPT app：有思考或工具明细时，进行中显示当前步骤与摘要，
//  结束后折叠成「处理过程」一行，点开可看全过程；没有明细的纯结果回复只展示最终答案。
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
    /// 区分真正的工具返回（含失败）与整轮 finish 自动关闭的条目。
    var hasToolResult = false

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
        self.hasToolResult = kind == .tool && state != .running
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
    /// 模型执行轮数，与工具数分开；历史缺记录时由 assembler 按 assistant 消息回退。
    public private(set) var roundCount: Int

    /// 本轮走到哪一步（nil = 这一轮没有阶段信息，比如历史记录恢复出来的旧轮次）。
    public private(set) var stage: AIAgentRunStage?
    /// 走到过的最远一步：多次工具往返会让 stage 在 streaming/tooling 之间来回，
    /// 指示条要按「最远」点亮已完成的格子，否则会来回闪。
    public private(set) var furthestStage: AIAgentRunStage?
    public private(set) var failedStage: AIAgentRunStage?
    /// 失败详情（供最终结果拼接、诊断与历史重建使用；过程区不重复渲染）。
    public private(set) var errorText: String?

    public init(startedAt: Date = Date(), roundCount: Int = 0) {
        self.startedAt = startedAt
        self.roundCount = max(0, roundCount)
    }

    public var isRunning: Bool { finishedAt == nil }
    public var isEmpty: Bool { items.isEmpty }
    /// 是否需要在消息 cell 中占用过程区。
    ///
    /// 没有思考、工具或失败信息的已完成纯文本回复不提供空的「处理过程」入口；
    /// 进行中的轮次仍保留入口，避免请求尚未产出内容时没有任何状态反馈。
    var shouldDisplayActivity: Bool {
        isRunning || !items.isEmpty || displayedFailedStage != nil
    }
    /// 工具调用数，仅用于过程统计，不能当作模型执行轮数。
    public var stepCount: Int { items.filter { $0.kind == .tool }.count }
    public var failedToolCount: Int { items.filter { $0.kind == .tool && $0.state == .failed }.count }
    /// 整轮失败优先；工具失败即使后来恢复，也保留工具阶段的排查入口。
    var displayedFailedStage: AIAgentRunStage? {
        failedStage ?? (failedToolCount > 0 ? .tooling : nil)
    }
    var displayedErrorText: String? {
        errorText ?? items.last(where: { $0.state == .failed })?.detail
    }
    var showsStageStrip: Bool {
        displayedFailedStage != nil || (isRunning && stage != nil)
    }
    public func elapsed(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// 执行记录比 wire 时间戳 / 实时收尾时刻准确，重建和实时更新都统一校准到它。
    mutating func setRunMetrics(startedAt: Date, endedAt: Date?, roundCount: Int?) {
        self.startedAt = startedAt
        if let roundCount { self.roundCount = max(0, roundCount) }
        if let endedAt {
            finish(at: endedAt)
            // finish 幂等，但这里允许用持久记录替换先前的展示层收尾时间。
            finishedAt = endedAt
        }
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

    /// wire 中的中间发言有稳定身份，与仅实时展示的 reasoning 分开，重建时不重复追加。
    mutating func appendRecordedThinking(_ text: String, id: String) {
        guard !text.isEmpty else { return }
        closeRunningThinking()
        items.append(AppAgentActivityItem(
            id: "wire-thinking-\(id)", kind: .thinking, title: "思考", detail: text
        ))
    }

    /// 重建时补回本次展示中已见过的内容，不能把 live 的阶段/终局覆盖到记录上。
    /// 以共同 item 为锚合并：保留 reasoning 与工具的相对顺序，wire 的最终结果优先。
    mutating func preserveDisplayedItems(from displayed: AppAgentActivityTimeline) {
        var merged = displayed.items
        var pending: [AppAgentActivityItem] = []
        for item in items {
            if let index = merged.firstIndex(where: { $0.kind == item.kind && $0.id == item.id }) {
                let previous = merged[index]
                var updated = item
                // 只有 toolUse 的条目即使已被整轮 finish 改成 done，也没有最终结果。
                if item.kind == .tool, !item.hasToolResult, previous.hasToolResult {
                    updated = previous
                } else {
                    updated.startedAt = previous.startedAt
                    if item.state == previous.state {
                        updated.finishedAt = previous.finishedAt
                    }
                }
                merged[index] = updated
                merged.insert(contentsOf: pending, at: index)
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(item)
            }
        }
        merged.append(contentsOf: pending)
        // assembler 已收尾，新补入的实时条目也必须收尾，但不能重新启动整轮。
        if let finishedAt {
            for index in merged.indices where merged[index].state == .running {
                merged[index].state = .done
                merged[index].finishedAt = finishedAt
            }
        }
        items = merged
        if let furthest = displayed.furthestStage,
           furthest.order > (furthestStage?.order ?? -1) {
            furthestStage = furthest
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
        items[index].hasToolResult = true
        items[index].finishedAt = Date()
        if !resultPreview.isEmpty {
            items[index].detail += items[index].detail.isEmpty ? "结果：\(resultPreview)" : "\n结果：\(resultPreview)"
        }
    }

    /// completed 表示工具返回了值，不代表业务成功；结构化 .error 仍必须标红。
    mutating func completeTool(id: String, result: Tool.Output) {
        if case .error(let message) = result {
            let name = items.last(where: { $0.id == id && $0.kind == .tool })?.title ?? "tool"
            failTool(id: id, name: name, message: message)
        } else {
            finishTool(id: id, resultPreview: ChatMessageAssembler.activityDetail(output: result))
        }
    }

    public mutating func failTool(id: String, name: String, message: String) {
        if let index = items.lastIndex(where: { $0.id == id && $0.kind == .tool }) {
            items[index].state = .failed
            items[index].hasToolResult = true
            items[index].finishedAt = Date()
            items[index].detail += items[index].detail.isEmpty ? "失败：\(message)" : "\n失败：\(message)"
        } else {
            items.append(AppAgentActivityItem(
                id: id, kind: .tool, title: name, detail: "失败：\(message)",
                state: .failed, finishedAt: Date()
            ))
        }
    }

    // MARK: - 阶段（给指示条用）

    /// 记下「现在在哪一步」。
    ///
    /// 传 nil（比如某次重建时 uiState 已经没有运行中的阶段了）**只**清掉「当前在哪」，
    /// 不动 `furthestStage` / 失败信息：那两样是本轮已经发生过的事实，清掉之后
    /// 指示条会突然变空，而失败恰恰是最需要一直看得见的。
    public mutating func setStage(_ stage: AIAgentRunStage?) {
        self.stage = stage
        guard let stage = stage else { return }
        if let furthest = furthestStage {
            furthestStage = stage.order > furthest.order ? stage : furthest
        } else {
            furthestStage = stage
        }
        // `.finished` 就是「本轮结束」，所以顺手收尾。少了这一步就会出现
        // 「指示条已经走到完成、下面还挂着转圈的『思考中…』」——两个字段各说各话。
        if stage == .finished, finishedAt == nil {
            finish()
        }
    }

    /// 本轮在某一步失败：stage 停在出错那一步，不往后推进（推到 `.finished` 就看不出
    /// 是哪一步崩的了，而这是这条指示条存在的唯一理由）。
    public mutating func markFailed(stage: AIAgentRunStage, message: String) {
        failedStage = stage
        errorText = message
        self.stage = stage
        if let furthest = furthestStage {
            furthestStage = stage.order > furthest.order ? stage : furthest
        } else {
            furthestStage = stage
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
        // 失败过的轮次保留「停在哪一步」；只有正常结束才推到 `.finished`。
        if failedStage == nil {
            setStage(.finished)
        }
    }

    private mutating func closeRunningThinking() {
        for index in items.indices where items[index].kind == .thinking && items[index].state == .running {
            items[index].state = .done
            items[index].finishedAt = Date()
        }
    }

    // MARK: - 摘要（折叠时显示）

    /// 折叠行主标题：进行中显示当前动作，终局保留过程入口与失败信息。
    public func headerTitle(now: Date = Date()) -> String {
        if isRunning {
            if let last = items.last {
                switch last.kind {
                case .tool where last.state == .running: return "执行 \(last.title)…"
                case .tool where last.state == .failed: return "调用失败 · \(last.title)，继续处理…"
                case .tool: return "已完成 \(last.title)，继续思考…"
                case .thinking: return "思考中…"
                }
            }
            switch stage {
            case .preparing: return "准备中…"
            case .requesting: return "等待响应…"
            case .streaming: return "正在输出…"
            case .tooling: return "执行工具…"
            default: return "思考中…"
            }
        }
        // 终局标题：失败/异常给状态文案；正常完成轮给「处理过程」。
        // 是否展示这个入口由上层（`ChatMessage.suppressResolvedActivity` + 设置开关）决定，
        // 这里只负责在需要展示时给出标题文案。不展示耗时和轮数。
        if let failedStage = failedStage {
            return "执行失败 · \(AppAgentRunStageStripView.title(for: failedStage))"
        }
        if failedToolCount > 0 { return "\(failedToolCount) 次工具失败" }
        return "处理过程"
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
