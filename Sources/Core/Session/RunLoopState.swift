//
//  RunLoopState.swift
//  AppAgent
//

import Foundation

/// `LLMExecutor.runLoop` 一轮执行期间会变的全部状态。
///
/// 这些字段原先是 `runLoop` 开头摊开的 11 个 `var`，在接下来五百多行里被各阶段随手读写：
/// 谁有权改哪一个、哪些必须一起改，只存在于作者脑子里。装进一个结构体之后，
/// 各阶段函数按 `inout` 接收它，「能动什么」写在签名上，编译器替人看着。
///
/// 字段名与原来的局部变量**逐一同名**，所以这次搬家是纯机械映射，对照 diff 即可核。
///
/// 值语义：`inout` 传递不产生额外分配，热路径开销为零。
struct RunLoopState {

    // MARK: - 消息

    /// 会话视角的消息（含失败/中断轮次，界面要显示它们）。
    var currentMessages: [AIAgentMessage]

    /// 发给模型的视角：孤儿轮次已剔除、压缩改写过。与 `currentMessages` 刻意分开。
    var providerMessages: [AIAgentMessage]

    // MARK: - 循环计数

    /// 执行循环的轮次，从 1 开始；进入循环后只增不减。
    var iteration = 0

    /// 当前模型上已经重试了几次。换模型后归零。
    var retryCount = 0

    /// 工具调用循环检测（精确重复 + A-B 乒乓）。值类型，逐轮累积。
    var loopDetector = ToolLoopDetector()

    // MARK: - 当前模型与运行期回退

    var provider: any ModelProvider
    var modelId: String

    /// 会话侧模型选择的代号。回退发布成功才 +1，用来识别「期间用户自己换过模型」。
    var modelSelectionGeneration: UInt64

    /// 还能不能把回退结果publish 回会话。一旦发布被拒（用户已手动改过），后续不再尝试。
    var canPublishFallback = true

    /// 这一轮已经试过的 "provider/model"，避免回退绕圈。
    var triedModelKeys: Set<String>

    // MARK: - 宿主上下文

    /// 下次请求是否强制重拍宿主状态快照（首轮、压缩后、回退后都要）。
    var forceHostSnapshotNextRequest = true

    init(
        initialMessages: [AIAgentMessage],
        provider: any ModelProvider,
        modelId: String,
        modelSelectionGeneration: UInt64,
        initialModelKey: String
    ) {
        self.currentMessages = initialMessages
        self.providerMessages = initialMessages
        self.provider = provider
        self.modelId = modelId
        self.modelSelectionGeneration = modelSelectionGeneration
        self.triedModelKeys = [initialModelKey]
    }
}
