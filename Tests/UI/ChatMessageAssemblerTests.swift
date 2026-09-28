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

    /// 一轮的持久状态。「还在跑」= 没有 outcome。
    private func records(_ list: [AIAgentTurnRecord]) -> [Int: AIAgentTurnRecord] {
        Dictionary(list.map { ($0.turnID, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func record(
        turn: Int,
        stage: AIAgentRunStage,
        outcome: AIAgentTurnRecord.Outcome? = nil
    ) -> AIAgentTurnRecord {
        AIAgentTurnRecord(
            turnID: turn,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: outcome == nil ? nil : Date(timeIntervalSince1970: 2),
            stage: stage,
            outcome: outcome
        )
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

    /// 进行中的一轮：还没输出最终结果时过程区展开；一旦最终结果开始输出就自动收起，
    /// 让结果显示在收起的过程入口下方；结束后仍保持折叠。
    func testRunningTurnExpandsAndFinishedTurnCollapses() {
        let messages: [AIAgentMessage] = [
            user("在跑的一问", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1)
        ]

        // 还没有最终结果（streamingText 为空）：思考过程默认展开。
        let thinking = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .streaming)])
        )
        XCTAssertEqual(thinking.last?.status, .streaming)
        XCTAssertEqual(thinking.last?.isActivityExpanded, true)

        // 最终结果开始输出（streamingText 非空）：过程区自动收起，正文即结果文案。
        let answering = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .streaming)]),
            streamingText: "正在写"
        )
        XCTAssertEqual(answering.last?.status, .streaming)
        XCTAssertEqual(answering.last?.isActivityExpanded, false)
        XCTAssertEqual(answering.last?.text, "正在写")

        let finished = ChatMessageAssembler.assemble(
            messages + [assistant(text: "写完了", turn: 1)],
            turnRecords: records([record(turn: 1, stage: .finished, outcome: .answered)])
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

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .streaming)])
        )

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
    /// 也没有过程，以前会被整轮丢掉，界面上什么都不显示。失败记录必须能撑起一个气泡。
    func testFailedOutcomeSurfacesEvenWhenTurnProducedNothing() {
        let messages: [AIAgentMessage] = [user("一问", turn: 1)]

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([
                record(turn: 1, stage: .preparing,
                       outcome: .failed(stage: .preparing, message: "No provider configured"))
            ])
        )

        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant])
        XCTAssertEqual(bubbles.last?.text, "Error: No provider configured")
        XCTAssertEqual(bubbles.last?.status, .error)
        // 卡在哪一步也要能看见（指示条那一格标红）。
        XCTAssertEqual(bubbles.last?.activity?.failedStage, .preparing)
        XCTAssertEqual(bubbles.last?.activity?.isRunning, false)
    }

    /// 已经吐了半截答案又失败：正文不能被错误覆盖掉。
    func testFailureMessageIsAppendedAfterPartialAnswer() {
        let messages: [AIAgentMessage] = [
            user("一问", turn: 1),
            assistant(text: "写到一半", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([
                record(turn: 1, stage: .streaming,
                       outcome: .failed(stage: .streaming, message: "断线了"))
            ])
        )

        XCTAssertEqual(bubbles.last?.text, "写到一半\n\nError: 断线了")
        XCTAssertEqual(bubbles.last?.status, .error)
    }

    func testLoopLimitFailureRemainsInFinalText() {
        let failure = "AIAgent loop exceeded maximum(70) iterations"
        let bubbles = ChatMessageAssembler.assemble(
            [user("一问", turn: 1)],
            turnRecords: records([
                record(
                    turn: 1,
                    stage: .tooling,
                    outcome: .failed(stage: .tooling, message: failure)
                )
            ])
        )

        XCTAssertEqual(bubbles.last?.text, "Error: \(failure)")
        XCTAssertEqual(bubbles.last?.status, .error)
        XCTAssertEqual(bubbles.last?.activity?.errorText, failure)
        XCTAssertTrue(bubbles.last?.activity?.shouldDisplayActivity == true)
    }

    /// 模型回了空内容 / 用户按了停止 / 上次运行被中断：三种终局都要在界面上有说法，
    /// 不能是一个空气泡。
    func testTerminalOutcomesRenderVisiblePlaceholders() {
        let messages: [AIAgentMessage] = [user("一问", turn: 1)]

        let empty = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .finished, outcome: .empty)])
        )
        XCTAssertEqual(empty.last?.text, "（本轮没有返回任何内容）")
        XCTAssertEqual(empty.last?.status, .complete)

        let cancelled = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .streaming, outcome: .cancelled)])
        )
        XCTAssertEqual(cancelled.last?.text, "（已停止）")
        XCTAssertEqual(cancelled.last?.activity?.isRunning, false)

        let interrupted = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .tooling, outcome: .interrupted)])
        )
        XCTAssertTrue(interrupted.last?.text.contains("中断") ?? false)
        XCTAssertEqual(interrupted.last?.activity?.isRunning, false)
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

    /// 刚提问、还没有任何产出的那一轮**不能**被丢掉。
    ///
    /// 丢了的话 `applyActivity` 的「最后一条 assistant 气泡」会落到上一轮的回复上，
    /// loading / 过程区就显示到上一条答案的上面（真机实测踩过）。
    func testRunningTurnWithoutOutputStillProducesAssistantBubble() {
        let messages: [AIAgentMessage] = [
            user("几点了", turn: 1),
            assistant(text: "现在 15:40。", turn: 1),
            user("那今天星期几", turn: 2)   // 第 2 轮刚发出，模型还没有任何产出
        ]

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([
                record(turn: 1, stage: .finished, outcome: .answered),
                record(turn: 2, stage: .requesting)
            ])
        )

        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(bubbles.last?.turnID, 2)
        XCTAssertEqual(bubbles.last?.status, .streaming)
        // 上一轮的答案必须还在自己的位置上，没被当成本轮的气泡。
        XCTAssertEqual(bubbles[1].text, "现在 15:40。")
    }

    /// 一问一答（没有工具、没有思考文本）的轮次必须是「已收尾」的。
    ///
    /// 踩过：这种轮次曾在 `timeline(for:)` 里提前 return 一条没 `finish()` 的时间线，
    /// 于是指示条已经走到「完成」，下面那行还挂着转圈的「思考中…」——问一句「几点了」
    /// 就能复现。
    func testPlainQATurnTimelineIsFinished() {
        let messages: [AIAgentMessage] = [
            user("几点了", turn: 1),
            assistant(text: "现在 15:40。", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record(turn: 1, stage: .finished, outcome: .answered)])
        )

        guard let activity = bubbles.last?.activity else {
            return XCTFail("最后一轮应保留时间线数据")
        }
        XCTAssertFalse(activity.isRunning)
        XCTAssertFalse(activity.headerTitle().contains("思考中"))
        XCTAssertEqual(activity.stage, .finished)
        XCTAssertFalse(activity.shouldDisplayActivity)
    }

    func testCompletedPlainAnswerRetainsTimelineDataButHidesActivityEntry() {
        let messages: [AIAgentMessage] = [
            AIAgentMessage(
                role: .user,
                content: [.text("一问")],
                turnID: 1
            ),
            AIAgentMessage(
                role: .assistant,
                content: [.text("答案")],
                turnID: 1
            )
        ]
        let record = AIAgentTurnRecord(
            turnID: 1,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 103),
            stage: .finished,
            outcome: .answered,
            roundCount: 2
        )

        let bubbles = ChatMessageAssembler.assemble(
            messages,
            turnRecords: records([record])
        )

        XCTAssertEqual(bubbles.last?.role, .assistant)
        XCTAssertEqual(bubbles.last?.text, "答案")
        XCTAssertEqual(bubbles.last?.status, .complete)
        XCTAssertNotNil(bubbles.last?.activity)
        XCTAssertEqual(
            bubbles.last?.activity?.headerTitle(),
            "处理过程"
        )
        XCTAssertFalse(bubbles.last?.activity?.shouldDisplayActivity == true)
        XCTAssertEqual(bubbles.last?.activity?.roundCount, 2)
        XCTAssertEqual(bubbles.last?.activity?.elapsed(), 3)
        XCTAssertEqual(bubbles.last?.isActivityExpanded, false)
    }

    func testLegacyPlainAnswerRetainsTimelineDataWithoutActivityEntry() {
        let messages: [AIAgentMessage] = [
            AIAgentMessage(
                role: .user,
                content: [.text("一问")],
                turnID: 1
            ),
            AIAgentMessage(
                role: .assistant,
                content: [.text("答案")],
                turnID: 1
            )
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.last?.activity?.roundCount, 1)
        XCTAssertEqual(bubbles.last?.activity?.headerTitle(), "处理过程")
        XCTAssertFalse(bubbles.last?.activity?.shouldDisplayActivity == true)
    }

    func testEveryTerminalOutcomeRetainsTimelineDataAndOnlyDetailedOrFailedEntriesDisplay() throws {
        let outcomes: [AIAgentTurnRecord.Outcome] = [
            .answered, .empty, .failed(stage: .requesting, message: "连接失败"),
            .cancelled, .interrupted
        ]
        for outcome in outcomes {
            let record = AIAgentTurnRecord(
                turnID: 1,
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 104),
                stage: .requesting,
                outcome: outcome,
                roundCount: 3
            )
            let messages = [user("一问", turn: 1)]
            let collapsed = try XCTUnwrap(ChatMessageAssembler.assemble(
                messages, turnRecords: records([record])
            ).last)
            XCTAssertEqual(collapsed.role, .assistant, "\(outcome)")
            XCTAssertEqual(collapsed.activity?.isRunning, false, "\(outcome)")
            let headerTitle = collapsed.activity?.headerTitle() ?? ""
            if case .failed = outcome {
                XCTAssertTrue(headerTitle.hasPrefix("执行失败"), "\(outcome): \(headerTitle)")
            } else {
                XCTAssertEqual(headerTitle, "处理过程", "\(outcome)")
            }
            let shouldDisplay = collapsed.activity?.shouldDisplayActivity == true
            let expectedShouldDisplay: Bool
            if case .failed = outcome {
                expectedShouldDisplay = true
            } else {
                expectedShouldDisplay = false
            }
            XCTAssertEqual(
                shouldDisplay,
                expectedShouldDisplay,
                "只有失败终局带失败入口；没有明细的纯终局只保留时间线数据：\(outcome)"
            )
            XCTAssertEqual(collapsed.activity?.roundCount, 3)
            XCTAssertEqual(collapsed.activity?.elapsed(), 4)
            XCTAssertFalse(collapsed.activity?.headerTitle().contains("耗时") == true)
            XCTAssertFalse(collapsed.activity?.headerTitle().contains("轮") == true)
            XCTAssertFalse(collapsed.isActivityExpanded)

            let expanded = ChatMessageAssembler.assemble(
                messages, turnRecords: records([record]), expandedTurnIDs: [1]
            ).last
            XCTAssertEqual(expanded?.isActivityExpanded, true, "\(outcome)")
            let collapsedAgain = ChatMessageAssembler.assemble(
                messages, turnRecords: records([record]), collapsedTurnIDs: [1]
            ).last
            XCTAssertEqual(collapsedAgain?.isActivityExpanded, false, "\(outcome)")
            XCTAssertEqual(collapsedAgain?.activity?.headerTitle(), collapsed.activity?.headerTitle())
        }
    }

    func testMultipleToolCallsInOneAssistantMessageDoNotBecomeMultipleRounds() {
        let messages: [AIAgentMessage] = [
            user("一问", turn: 1),
            assistant(
                text: nil,
                calls: [call("c1", "file_read"), call("c2", "file_search"), call("c3", "web_fetch")],
                turn: 1
            ),
            toolResults([("c1", "ok"), ("c2", "ok"), ("c3", "ok")], turn: 1),
            assistant(text: "答案", turn: 1)
        ]

        let bubbles = ChatMessageAssembler.assemble(messages)

        XCTAssertEqual(bubbles.last?.activity?.stepCount, 3)
        XCTAssertEqual(bubbles.last?.activity?.roundCount, 2,
                       "三个工具调用不应被计成三轮；这里是工具请求轮 + 最终回答轮")
    }

    func testAlwaysShowThinkingOffSuppressesOnlyAnsweredTurns() throws {
        let base = Date(timeIntervalSince1970: 100)
        func makeRecord(_ outcome: AIAgentTurnRecord.Outcome) -> AIAgentTurnRecord {
            AIAgentTurnRecord(
                turnID: 1, startedAt: base, endedAt: base.addingTimeInterval(2),
                stage: .requesting, outcome: outcome, roundCount: 1
            )
        }
        let messages = [user("一问", turn: 1), assistant(text: "答案", turn: 1)]

        // 关闭「总是显示思考过程」：只有 .answered 的成功轮被抑制过程入口。
        let answered = try XCTUnwrap(ChatMessageAssembler.assemble(
            messages, turnRecords: records([makeRecord(.answered)]),
            alwaysShowThinkingProcess: false
        ).last)
        XCTAssertTrue(answered.suppressResolvedActivity)

        // 报错 / 异常回合不受开关影响，仍保留过程入口。
        for outcome in [AIAgentTurnRecord.Outcome.empty, .cancelled, .interrupted,
                        .failed(stage: .requesting, message: "boom")] {
            let bubble = try XCTUnwrap(ChatMessageAssembler.assemble(
                messages, turnRecords: records([makeRecord(outcome)]),
                alwaysShowThinkingProcess: false
            ).last)
            XCTAssertFalse(bubble.suppressResolvedActivity, "\(outcome)")
        }

        // 打开开关（默认）时成功轮也不抑制。
        let shown = try XCTUnwrap(ChatMessageAssembler.assemble(
            messages, turnRecords: records([makeRecord(.answered)]),
            alwaysShowThinkingProcess: true
        ).last)
        XCTAssertFalse(shown.suppressResolvedActivity)
    }

    func testExplicitCollapseSurvivesRunningStageReassembly() {
        let messages = [user("一问", turn: 1)]
        for stage in [AIAgentRunStage.preparing, .requesting, .streaming, .tooling] {
            let bubbles = ChatMessageAssembler.assemble(
                messages, turnRecords: records([record(turn: 1, stage: stage)]),
                collapsedTurnIDs: [1]
            )
            XCTAssertEqual(bubbles.last?.isActivityExpanded, false, stage.rawValue)
            XCTAssertEqual(bubbles.last?.status, .streaming)
        }
    }

    func testTranscriptPreservesChronologyAndLongFailureAfterReassembly() throws {
        let error = String(repeating: "详细原因🙂\n", count: 150) + "真正的错误在这里"
        let messages = [
            user("检查", turn: 1),
            assistant(text: "先读文件", calls: [call("c1", "file_read")], turn: 1),
            toolResults([("c1", "读取成功")], turn: 1),
            assistant(text: "再写文件", calls: [call("c2", "file_write")], turn: 1),
            toolResults([("c2", error, true)], turn: 1),
            assistant(text: "写入失败", turn: 1)
        ]
        let timeline = try XCTUnwrap(ChatMessageAssembler.assemble(messages).last?.activity)
        XCTAssertEqual(timeline.items.map(\.kind), [.thinking, .tool, .thinking, .tool])
        XCTAssertEqual(timeline.items[0].detail, "先读文件")
        XCTAssertEqual(timeline.items[2].detail, "再写文件")
        XCTAssertTrue(timeline.items[3].detail.hasSuffix(error), "历史展开也必须保留失败全文")
        XCTAssertEqual(timeline.displayedFailedStage, .tooling)
    }

    func testEarlyFailuresDoNotMarkLaterStagesAsReached() throws {
        for stage in [AIAgentRunStage.preparing, .requesting, .streaming] {
            let failed = record(turn: 1, stage: stage, outcome: .failed(stage: stage, message: "失败"))
            let timeline = try XCTUnwrap(ChatMessageAssembler.assemble(
                [user("问题", turn: 1)], turnRecords: records([failed])
            ).last?.activity)
            XCTAssertEqual(timeline.stage, stage)
            XCTAssertEqual(timeline.failedStage, stage)
            XCTAssertEqual(timeline.furthestStage, stage)
            XCTAssertFalse(timeline.isRunning)
        }
    }

    func testFollowupRequestFailureRetainsCompletedToolStageAfterReassembly() throws {
        let messages = [
            user("检查", turn: 1),
            assistant(text: nil, calls: [call("c1", "file_read")], turn: 1),
            toolResults([("c1", "读取成功")], turn: 1)
        ]
        let failed = record(
            turn: 1, stage: .requesting, outcome: .failed(stage: .requesting, message: "HTTP 503")
        )
        let timeline = try XCTUnwrap(ChatMessageAssembler.assemble(
            messages, turnRecords: records([failed])
        ).last?.activity)
        XCTAssertEqual(timeline.stage, .requesting)
        XCTAssertEqual(timeline.failedStage, .requesting)
        XCTAssertEqual(timeline.furthestStage, .tooling)
        XCTAssertFalse(timeline.isRunning)
        XCTAssertEqual(timeline.items.first?.state, .done)
    }

    func testActivityOutputRetainsNewlinesAndJSONIsReadable() {
        let text = String(repeating: "输出行\n", count: 100) + "末尾"
        XCTAssertEqual(ChatMessageAssembler.activityDetail(output: .text(text)), text)
        XCTAssertEqual(
            ChatMessageAssembler.activityDetail(arguments: ["op": .string("read"), "path": .string("a.swift")]),
            "op=\"read\", path=\"a.swift\""
        )
    }
}

#endif
