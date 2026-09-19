//
//  ChatMessageAssemblerTests.swift
//  AppAgentUITests
//
//  对话列表分层的回归：wire 记录（一次提问展开成多轮 tool 往返）必须被组装成
//  用户视角的列表（一次提问 = 一个用户气泡 + 一个 agent 气泡，过程收进过程区）。
//

#if canImport(UIKit)
import XCTest
@testable import AppAgent

final class ChatMessageAssemblerTests: XCTestCase {

    private func user(_ text: String, turn: Int) -> AIAgentMessage {
        AIAgentMessage(role: .user, content: [.text(text)], turnID: turn)
    }

    private func toolResults(_ pairs: [(id: String, content: String)], turn: Int) -> AIAgentMessage {
        toolResults(pairs.map { (id: $0.id, content: $0.content, isError: false) }, turn: turn)
    }

    /// 带失败标记的工具结果。失败与否由 `isError` 决定，不靠嗅 `Error:` 前缀。
    private func toolResults(
        _ triples: [(id: String, content: String, isError: Bool)],
        turn: Int
    ) -> AIAgentMessage {
        AIAgentMessage(
            role: .user,
            content: triples.map {
                .toolResult(AIAgentMessage.ToolCallResult(
                    toolCallId: $0.id,
                    content: $0.content,
                    isError: $0.isError
                ))
            },
            turnID: turn
        )
    }

    private func assistant(text: String?, calls: [AIAgentMessage.ToolCall] = [], turn: Int) -> AIAgentMessage {
        var content: [AIAgentMessage.Content] = []
        if let text { content.append(.text(text)) }
        content.append(contentsOf: calls.map { .toolUse($0) })
        return AIAgentMessage(role: .assistant, content: content, turnID: turn)
    }

    private func call(_ id: String, _ name: String) -> AIAgentMessage.ToolCall {
        AIAgentMessage.ToolCall(id: id, name: name, arguments: ["op": .string("x")])
    }

    /// 工具结果在 wire 上是 user 角色，但绝不能渲染成用户气泡。
    func testToolResultsNeverBecomeUserBubbles() {
        let messages: [AIAgentMessage] = [
            user("查一下天气", turn: 1),
            assistant(text: nil, calls: [call("c1", "web_fetch")], turn: 1),
            toolResults([("c1", "Error: Tool 'web_fetch' not found")], turn: 1),
            assistant(text: "拿不到天气。", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant])
        XCTAssertEqual(bubbles.first?.text, "查一下天气")
        XCTAssertEqual(bubbles.last?.text, "拿不到天气。")
        // 工具结果的原文一个字都不该出现在用户气泡里。
        XCTAssertFalse(bubbles.contains { $0.role == .user && $0.text.contains("not found") })
        XCTAssertFalse(bubbles.contains { $0.text.contains("Result:") })
    }

    /// 工具往返（含中间过程）落在 agent 气泡的过程区里，且失败步骤被标出来。
    func testToolRoundTripsLandInAgentActivity() {
        let messages: [AIAgentMessage] = [
            user("查一下天气", turn: 1),
            assistant(text: "我先抓一下", calls: [call("c1", "web_fetch")], turn: 1),
            toolResults([("c1", "Tool 'web_fetch' not found", true)], turn: 1),
            assistant(text: "拿不到天气。", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)
        let agent = bubbles.last
        let activity = agent?.activity
        let toolStep = activity?.items.first { $0.kind == .tool }

        XCTAssertEqual(activity?.stepCount, 1)
        XCTAssertEqual(toolStep?.title, "web_fetch")
        XCTAssertEqual(toolStep?.state, .failed)
        // 中间发言（"我先抓一下"）属于过程，不该混进最终答案。
        XCTAssertTrue(activity?.items.contains { $0.kind == .thinking } ?? false)
        XCTAssertEqual(agent?.text, "拿不到天气。")
    }

    /// 成功的工具结果即使正文以「Error:」开头也不算失败：失败只看 `isError`。
    /// （工具正常返回的正文完全可能这么开头，嗅前缀会把成功标红。）
    func testSuccessfulResultIsNotFailedJustBecauseTextStartsWithError() {
        let messages: [AIAgentMessage] = [
            user("读日志", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1),
            toolResults([("c1", "Error: connection reset —— 这是日志文件里的一行")], turn: 1),
            assistant(text: "日志里有一条报错。", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)
        let toolStep = bubbles.last?.activity?.items.first { $0.kind == .tool }

        XCTAssertEqual(toolStep?.state, .done)
    }

    /// 一次提问内部有多轮往返，也只产生一个 agent 气泡；第二次提问才开新的一轮。
    func testMultipleRoundTripsCollapseIntoOneAgentBubble() {
        let messages: [AIAgentMessage] = [
            user("第一问", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1),
            toolResults([("c1", "ok")], turn: 1),
            assistant(text: nil, calls: [call("c2", "file_write")], turn: 1),
            toolResults([("c2", "ok")], turn: 1),
            assistant(text: "第一个答案", turn: 1),
            user("第二问", turn: 2),
            assistant(text: "第二个答案", turn: 2)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(bubbles.map(\.text), ["第一问", "第一个答案", "第二问", "第二个答案"])
        XCTAssertEqual(bubbles[1].activity?.stepCount, 2)
        XCTAssertEqual(bubbles[3].activity?.stepCount ?? 0, 0)
    }

    /// 归属靠 turnID：即使中间轮次被上下文压缩挪过位置，也不会挂到别的提问下。
    func testAttributionFollowsTurnIDNotPosition() {
        let messages: [AIAgentMessage] = [
            user("第一问", turn: 1),
            assistant(text: "答案一", turn: 1),
            user("第二问", turn: 2),
            // 迟到的第一轮工具结果（位置在第二问之后，但归属仍是第 1 轮）
            toolResults([("c9", "late result")], turn: 1),
            assistant(text: "答案二", turn: 2)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.count, 4)
        XCTAssertEqual(bubbles[1].activity?.items.count, 1, "迟到的结果应回到第 1 轮的过程里")
        XCTAssertEqual(bubbles[3].activity?.items.count ?? 0, 0)
    }

    /// 旧快照没有 turnID：按「真的用户发言开新一轮」回退，工具结果依旧不算用户输入。
    func testLegacyMessagesWithoutTurnIDStillGroupCorrectly() {
        let messages: [AIAgentMessage] = [
            AIAgentMessage(role: .user, content: [.text("旧的一问")]),
            AIAgentMessage(role: .assistant, content: [.toolUse(call("c1", "file_read"))]),
            AIAgentMessage(role: .user, content: [
                .toolResult(AIAgentMessage.ToolCallResult(toolCallId: "c1", content: "ok"))
            ]),
            AIAgentMessage(role: .assistant, content: [.text("旧的答案")]),
            AIAgentMessage(role: .user, content: [.text("旧的二问")]),
            AIAgentMessage(role: .assistant, content: [.text("答案二")])
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(bubbles.map(\.text), ["旧的一问", "旧的答案", "旧的二问", "答案二"])
        XCTAssertEqual(bubbles[1].activity?.stepCount, 1)
    }

    /// 进行中的一轮：过程区展开、状态是 streaming；结束后自动折叠。
    func testRunningTurnExpandsAndFinishedTurnCollapses() {
        let messages: [AIAgentMessage] = [
            user("在跑的一问", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1)
        ]

        let running = ChatMessageAssembler.assemble(messages, streamingText: "正在写", isRunning: true)
        XCTAssertEqual(running.last?.status, .streaming)
        XCTAssertEqual(running.last?.isActivityExpanded, true)
        XCTAssertEqual(running.last?.text, "正在写")

        let finished = ChatMessageAssembler.assemble(
            messages + [assistant(text: "写完了", turn: 1)]
        )
        XCTAssertEqual(finished.last?.status, .complete)
        XCTAssertEqual(finished.last?.isActivityExpanded, false)
        XCTAssertEqual(finished.last?.text, "写完了")
    }

    /// 进行中的一轮即使还没有正文，也要有气泡承载过程区（不能整轮消失）。
    func testRunningTurnWithNoTextYetStillShowsActivity() {
        let messages: [AIAgentMessage] = [
            user("一问", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages, isRunning: true)

        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles.last?.role, .assistant)
        XCTAssertEqual(bubbles.last?.activity?.stepCount, 1)
    }

    /// 一轮里来了两段纯文本（多个 text block / 分两条消息）时不能只留最后一段。
    func testMultipleFinalTextsAreJoinedNotOverwritten() {
        let messages: [AIAgentMessage] = [
            user("一问", turn: 1),
            AIAgentMessage(role: .assistant,
                           content: [.text("第一段"), .text("第二段")],
                           turnID: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.last?.text, "第一段\n\n第二段")
    }

    /// 「没配 API Key / 没有 provider」这种一步都没跑起来的失败：那一轮既没有正文
    /// 也没有过程，以前会被整轮丢掉，界面上什么都不显示。错误必须能撑起一个气泡。
    func testErrorTextSurfacesEvenWhenTurnProducedNothing() {
        let messages: [AIAgentMessage] = [user("一问", turn: 1)]

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            errorText: "Error: No provider configured"
        )

        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant])
        XCTAssertEqual(bubbles.last?.text, "Error: No provider configured")
        XCTAssertEqual(bubbles.last?.status, .error)
    }

    /// 已经吐了半截答案又失败：正文不能被错误覆盖掉。
    func testErrorTextIsAppendedAfterPartialAnswer() {
        let messages: [AIAgentMessage] = [
            user("一问", turn: 1),
            assistant(text: "写到一半", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages, errorText: "Error: 断线了")

        XCTAssertEqual(bubbles.last?.text, "写到一半\n\nError: 断线了")
        XCTAssertEqual(bubbles.last?.status, .error)
    }

    /// 用户点开过的那一轮，重建列表后过程区仍然展开；没点过的照旧折叠。
    func testExpandedTurnIDsKeepActivityOpenAfterReassembly() {
        let messages: [AIAgentMessage] = [
            user("一问", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1),
            toolResults([(id: "c1", content: "ok")], turn: 1),
            assistant(text: "答案", turn: 1)
        ]

        let collapsed = ChatMessageAssembler.assemble(messages)
        XCTAssertEqual(collapsed.last?.isActivityExpanded, false)
        // 气泡要带上轮次号，否则展开态无处安放（`id` 每次组装都是新的）。
        XCTAssertEqual(collapsed.last?.turnID, 1)

        let expanded = ChatMessageAssembler.assemble(messages, expandedTurnIDs: [1])
        XCTAssertEqual(expanded.last?.isActivityExpanded, true)
    }
}

#endif
