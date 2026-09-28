//
//  ModelSwitchStep.swift
//  AppAgent
//

import Foundation

/// 「换下一个模型重跑这一轮」的结果。
///
/// 原先这套动作在 `runLoop` 里有**两份近乎逐行相同的拷贝**（约 57 行 × 2）：
/// 一份在流错误的 catch 块里（重试用尽后回退），一份在协议异常分支里
/// （`stop=tool_use` 却 0 个调用，同一端点重试没意义、只能换模型）。
/// 两份都要做：轮次预算守卫 → 探测下一个候选 → 取消守卫 → 记下已试过的 key →
/// 改 6 个状态字段 → 把新模型发布回会话（带 generation 校验）→ 推进阶段。
///
/// 拷贝的危险不在行数，而在**只改了一份**：这段是全文件状态转换最密的地方，
/// 两边一旦漂移，症状是「某一类失败换模型了、另一类没换」，极难定位。
enum ModelSwitchOutcome {
    /// 已经换到下一个模型，调用方应 `continue` 重跑这一轮。
    case switched
    /// 候选已用尽。调用方按自己的语义报错（两处的终局文案刻意不同）。
    case noCandidateLeft
    /// 轮次预算先用完了。调用方报 `maxIterationsReached`。
    case budgetExhausted
    /// 探测候选期间被取消。调用方负责 discard 宿主上下文 + 报 `.cancelled`。
    case cancelled
}

/// 换模型这一步需要的、一轮之内不变的上下文。
///
/// 单独成结构体只为把参数表收窄到可读：这些字段调用方本来就都持有。
struct ModelSwitchContext {
    let session: AISession
    let agent: AIAgent
    let runID: UUID
    let turnID: Int
    let maxIterations: Int
    let systemParts: [ContentOrCacheControl<SystemPrompt>]
    let toolSegments: [ContentOrCacheControl<any ToolProtocol>]
}
