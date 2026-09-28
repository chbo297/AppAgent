//
//  AIAgentTurnRecord.swift
//  AppAgent
//
//  一轮（一次提问 → 一次答复）的**阶段与终局**记录，会随会话快照落盘。
//
//  为什么需要它：展示层原来有两个数据源——持久的 wire 消息 + 易失的 `SessionUIState`。
//  「跑到哪一步」「这轮是怎么收场的」只活在后者里，于是同一个毛病反复出现：阶段信息要
//  喂两条路才不丢、重建时正在跑的那一轮会被当成空轮丢掉、进程被杀之后那一轮看起来
//  和普通空轮一模一样。把它落盘、变成单一真相，这些问题就没有生存空间了。
//
//  边界：这里只记阶段、终局与执行统计。每一步的明细（思考文本、工具往返）继续从 wire 消息
//  按 `turnID` 推导，不在这里重存一份——两边各有唯一真相，不重叠。
//

import Foundation

public struct AIAgentTurnRecord: Codable, Sendable, Equatable {

    /// 这一轮的收场方式。`nil`（`outcome == nil`）表示还在跑。
    ///
    /// **不变量：一轮只能通过写入 outcome 来结束。** UI 的终态渲染只看它，
    /// 所以「成功 / 空 / 失败 / 被停止 / 被打断」都必须是这里的一个 case，
    /// 不允许出现「结束了但没有 outcome」的状态——那就是界面上的静默。
    public enum Outcome: Codable, Sendable, Equatable {
        /// 有正文的正常答复。
        case answered
        /// 跑完了，但模型什么内容都没给。
        case empty
        /// 在某一步失败。`stage` 是失败发生的那一步，UI 据此标红。
        case failed(stage: AIAgentRunStage, message: String)
        /// 用户按了停止 / 这一轮被新的一轮取代。
        case cancelled
        /// 进程被杀（或会话被释放）时这一轮还没有终局。**进行中的流不可恢复**：
        /// SSE 断了就是断了，工具也没有幂等保证（`app_action` / `app_hotfix` 有副作用），
        /// 所以恢复时只把它标成「上次中断」交给用户决定要不要重问，绝不自动重放。
        case interrupted
    }

    public var turnID: Int
    public var startedAt: Date
    public var endedAt: Date?
    /// 走到过的最后一个阶段。失败时停在出错那一步，不推进到 `.finished`。
    public var stage: AIAgentRunStage
    public var outcome: Outcome?
    /// 这一轮实际用的模型（`"providerName/modelId"`；运行期回退后是回退到的那个）。
    public var modelRef: String?
    /// 已进入的模型执行循环数（包括重试 / 模型回退），不是工具调用个数。
    /// nil = 旧快照未记录；0 = 尚未进入循环。Optional 保证缺键的旧数据仍可解码。
    public var roundCount: Int?

    public init(
        turnID: Int,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        stage: AIAgentRunStage = .preparing,
        outcome: Outcome? = nil,
        modelRef: String? = nil,
        roundCount: Int? = nil
    ) {
        self.turnID = turnID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stage = stage
        self.outcome = outcome
        self.modelRef = modelRef
        self.roundCount = roundCount.map { max(0, $0) }
    }

    /// 是否已经有终局。
    public var isFinished: Bool { outcome != nil }

    /// 失败发生在哪一步（没失败时为 nil）。
    public var failedStage: AIAgentRunStage? {
        if case .failed(let stage, _) = outcome { return stage }
        return nil
    }

    /// 失败详情（没失败时为 nil）。
    public var failureMessage: String? {
        if case .failed(_, let message) = outcome { return message }
        return nil
    }

    /// 耗时：已结束用 `endedAt`，还在跑用「现在」。
    public func elapsed(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }
}
