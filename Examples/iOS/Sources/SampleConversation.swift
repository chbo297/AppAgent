//
//  SampleConversation.swift
//  AppAgentDemo
//
//  仅 DEBUG：`-show-sample-conversation` 往当前会话里灌一段样例对话，用来肉眼验收
//  对话列表的分层与 markdown 渲染；不需要真的连模型。
//
//  样例刻意复刻了「工具不可用 + 子代理没配 provider」那种一轮里多次失败的真实形态：
//  用户气泡只该有一条，工具往返应该全部收进 agent 的过程区并折叠起来。
//

//  Demo target 直接编译 SDK 源码（没有独立的 AppAgent module），所以这里不 import。
#if DEBUG
import Foundation

enum SampleConversation {

    static func install(into session: AISession) {
        session.clearHistory()
        session.updateMessages(messages)
    }

    private static let messages: [AIAgentMessage] = [
        // 第 1 轮：没有工具调用的简单问答，用来对比「过程区为空时不显示」。
        AIAgentMessage(role: .user, content: [.text("先随便聊一句")], turnID: 1),
        AIAgentMessage(role: .assistant, content: [.text("好，随时开始。")], turnID: 1),

        // 第 2 轮：一轮里两次工具往返（都失败），最后给 markdown 答案。
        AIAgentMessage(role: .user, content: [.text("github 上有哪些可以运行在 iOS app 上的 ai agent 开源项目")], turnID: 2),
        AIAgentMessage(role: .assistant, content: [
            .text("我先按「原生 iOS/Swift、可嵌入 App、具备 Agent/工具调用能力」筛选，并区分完整 Agent 与底层 SDK。"),
            .toolUse(.init(id: "call_1", name: "web_fetch",
                           arguments: ["url": .string("https://github.com/search?q=ios+agent")])),
        ], turnID: 2),
        AIAgentMessage(role: .user, content: [
            .toolResult(.init(toolCallId: "call_1", content: "Error: Tool 'web_fetch' not found")),
        ], turnID: 2),
        AIAgentMessage(role: .assistant, content: [
            .toolUse(.init(id: "call_2", name: "delegate_task",
                           arguments: ["goal": .string("列出 iOS 上可运行的 agent 项目")])),
        ], turnID: 2),
        AIAgentMessage(role: .user, content: [
            .toolResult(.init(toolCallId: "call_2", content: "Error: Sub-agent error: Provider error: No provider configured")),
        ], turnID: 2),
        AIAgentMessage(role: .assistant, content: [.text(answerMarkdown)], turnID: 2),
    ]

    private static let answerMarkdown = """
        抓取工具不可用，下面是训练时的了解。

        ### 原生 Swift Agent / 工具调用

        - **LangChain.swift**：Swift 版 LangChain，提供 Chain / Memory / Agent / Tool 抽象。
        - **swift-sdk**：官方 MCP Swift SDK，可作为工具协议层。

        ### 选型建议

        1. 只要「能调工具」，用 `swift-sdk` 接自己的执行器。
        2. 想要完整循环，参考 [LangChain.swift](https://github.com/bsorrentino/LangChain.swift)。

        | 项目 | 用途 | 是否完整 Agent |
        | --- | --- | --- |
        | LangChain.swift | Agent / Tool 抽象 | 是 |
        | swift-sdk | MCP 工具协议层 | 否 |
        """
}
#endif
