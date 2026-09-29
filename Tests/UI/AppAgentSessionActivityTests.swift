#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

/// 整个用例类都在主线程：它断言的是 UIKit 视图的布局与刷新行为，连那条期望高度都由
/// `AppAgentChatMessageListView` 的 MainActor 常量算出来。隔离标在类上一次，
/// 省掉每个方法各标一遍，也让存储属性的默认值有合法的求值环境。
@MainActor
final class AppAgentSessionActivityTests: XCTestCase {
    private let expectedCoordinatorLatestReplyInitialHeight: CGFloat = max(
        44,
        412.5
            - 90
            - AppAgentChatMessageListView.contentBottomSpacing
            - AppAgentChatMessageListView.latestReplyUserTailHeight
    )

    func testTerminalReloadRetainsAllocatedHeightAndSessionSwitchResetsIt() async throws {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "reply-height",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Height")
        let turnID = session.addUserMessage("长回复")
        session.openTurnRecord(turnID: turnID, modelRef: nil)
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: session.id)
        controller.loadViewIfNeeded()
        controller.chatPanelCoordinator.updateLayout(
            bounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            safeAreaInsets: UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        )
        session.uiState.onChange = nil
        let list = controller.chatPanelView.listView
        list.layoutIfNeeded()
        let table = try XCTUnwrap(list.participantScrollView as? UITableView)
        func height() -> CGFloat {
            table.delegate?.tableView?(table, heightForRowAt: IndexPath(row: 1, section: 0)) ?? 0
        }
        let id = try XCTUnwrap(list.messages.last?.id)
        list.updateMessage(text: String(repeating: "长回复内容\n\n", count: 50), status: .streaming, messageID: id)
        let grown = height()
        XCTAssertGreaterThan(grown, expectedCoordinatorLatestReplyInitialHeight)
        session.closeTurnRecord(turnID: turnID, outcome: .failed(stage: .requesting, message: "失败"), stage: .requesting)
        controller.handleUIStateChange(key: SessionUIState.runStageKey)
        XCTAssertNotEqual(list.messages.last?.id, id)
        XCTAssertEqual(height(), grown)

        let other = await agent.createSession(title: "Other")
        let next = other.addUserMessage("另一会话")
        other.openTurnRecord(turnID: next, modelRef: nil)
        controller.switchSession(to: other.id)
        other.uiState.onChange = nil
        XCTAssertEqual(height(), expectedCoordinatorLatestReplyInitialHeight, accuracy: 0.5)
        controller.switchSession(to: session.id)
        session.uiState.onChange = nil
        let restored = try XCTUnwrap(list.messages.last)
        XCTAssertEqual(height(), ChatMessageHeightCache().height(for: restored, width: table.bounds.width))
        XCTAssertLessThan(
            height(),
            expectedCoordinatorLatestReplyInitialHeight,
            "切回已完成会话不再分配留白"
        )
    }

    func testStageRefreshPreservesLiveContentAndCollapseChoice() async throws {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "activity-refresh",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Live")
        session.addUserMessage("检查页面")
        let turnID = session.currentTurnID
        session.openTurnRecord(turnID: turnID, modelRef: nil)
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: session.id)
        session.uiState.onChange = nil // 精确驱动与生产相同的通知入口，不依赖调度时序。

        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("先检查结构")
        timeline.startTool(id: "slow", name: "web_fetch", argumentsPreview: "url=example")
        controller.applyActivity(timeline)
        var message = try XCTUnwrap(controller.chatMessages.last)
        message.isActivityExpanded = false
        controller.handleActivityToggled(message)
        let originalID = message.id

        for stage in [AIAgentRunStage.tooling, .requesting, .streaming] {
            session.advanceTurnStage(turnID: turnID, stage: stage)
            controller.handleUIStateChange(key: SessionUIState.runStageKey)
            let updated = try XCTUnwrap(controller.chatMessages.last)
            XCTAssertEqual(updated.id, originalID, "阶段变化只刷新当前行，不重建整张表")
            XCTAssertEqual(updated.activity?.items, timeline.items)
            XCTAssertEqual(updated.activity?.stage, stage)
            XCTAssertEqual(updated.activity?.furthestStage, .tooling)
            XCTAssertFalse(updated.isActivityExpanded)
        }
        // 工具仍未落到 session.messages，显式重建也不能让实时内容消失。
        XCTAssertEqual(session.messages.count, 1)
        controller.reloadFromSession(reason: .browsing)
        XCTAssertEqual(controller.chatMessages.last?.activity?.items, timeline.items)
        XCTAssertFalse(try XCTUnwrap(controller.chatMessages.last).isActivityExpanded)

        timeline.appendThinking("等待期间收到的新内容")
        controller.applyActivity(timeline)
        XCTAssertEqual(controller.chatMessages.last?.activity?.furthestStage, .tooling)

        // 另一个会话也从 turn 1 开始；相同 turnID 不能继承上一个会话的过程。
        let other = await agent.createSession(title: "Other")
        other.addUserMessage("新会话")
        other.openTurnRecord(turnID: other.currentTurnID, modelRef: nil)
        controller.switchSession(to: other.id)
        XCTAssertTrue(controller.chatMessages.last?.activity?.isEmpty == true)
        XCTAssertTrue(controller.chatMessages.last?.isActivityExpanded == true)
    }

    func testCompletedReasoningSurvivesReloadExpansionAndFollowingTurn() async throws {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "activity-reasoning",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Reasoning")
        let turnID = session.addUserMessage("解释结果")
        session.openTurnRecord(turnID: turnID, modelRef: nil)
        session.advanceTurnRound(turnID: turnID, roundCount: 2)
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: session.id)
        session.uiState.onChange = nil

        let reasoning = (1...30).map { "思考明细第 \($0) 行" }.joined(separator: "\n")
        var live = AppAgentActivityTimeline()
        live.appendThinking(reasoning)
        controller.applyActivity(live)
        session.updateMessages(session.messages + [
            AIAgentMessage(role: .assistant, content: [.text("最终答案")], turnID: turnID)
        ])
        session.closeTurnRecord(turnID: turnID, outcome: .answered, stage: .finished)
        let record = try XCTUnwrap(session.turnRecord(turnID: turnID))
        controller.handleUIStateChange(key: SessionUIState.runStageKey)

        func firstAnswer() throws -> ChatMessage {
            try XCTUnwrap(controller.chatMessages.first {
                $0.role == .assistant && $0.turnID == turnID
            })
        }
        let finished = try firstAnswer()
        XCTAssertEqual(finished.text, "最终答案")
        XCTAssertFalse(finished.isActivityExpanded)
        XCTAssertEqual(finished.activity?.items.map(\.detail), [reasoning])
        XCTAssertEqual(finished.activity?.items.map(\.state), [.done])
        XCTAssertEqual(finished.activity?.startedAt, record.startedAt)
        XCTAssertEqual(finished.activity?.finishedAt, record.endedAt)
        XCTAssertEqual(finished.activity?.roundCount, 2)
        XCTAssertFalse(try XCTUnwrap(finished.activity).isRunning)
        let summary = finished.activity?.headerTitle()

        for expanded in [true, false, true] {
            var message = try firstAnswer()
            message.isActivityExpanded = expanded
            controller.handleActivityToggled(message)
            controller.reloadFromSession(reason: .browsing)
            controller.handleUIStateChange(key: "isStreaming")
            let reloaded = try firstAnswer()
            XCTAssertEqual(reloaded.isActivityExpanded, expanded)
            XCTAssertEqual(reloaded.activity?.items, finished.activity?.items)
            XCTAssertEqual(reloaded.activity?.headerTitle(), summary)
        }

        let nextTurnID = session.addUserMessage("下一问")
        session.openTurnRecord(turnID: nextTurnID, modelRef: nil)
        controller.reloadFromSession(reason: .browsing)
        XCTAssertEqual(try firstAnswer().activity?.items, finished.activity?.items)
        XCTAssertTrue(controller.chatMessages.last?.activity?.isEmpty == true)

        // 清空后可以复用 turn 1，但那已经不是同一次运行，即使还没来得及刷新空列表。
        session.clearHistory()
        let reusedTurnID = session.addUserMessage("清空后的问题")
        XCTAssertEqual(reusedTurnID, turnID)
        session.openTurnRecord(turnID: reusedTurnID, modelRef: nil)
        controller.handleUIStateChange(key: SessionUIState.runStageKey)
        controller.reloadFromSession(reason: .browsing)
        XCTAssertTrue(controller.chatMessages.last?.activity?.isEmpty == true)
    }

    func testTerminalWithoutWireActivityPreservesDisplayedDetails() async throws {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "activity-terminal-details",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        let outcomes: [AIAgentTurnRecord.Outcome] = [
            .empty, .cancelled, .interrupted, .failed(stage: .requesting, message: "连接失败")
        ]
        for outcome in outcomes {
            let session = await agent.createSession(title: "Terminal")
            let turnID = session.addUserMessage("检查页面")
            session.openTurnRecord(turnID: turnID, modelRef: nil)
            let controller = AppAgentViewController()
            controller.agent = agent
            controller.switchSession(to: session.id)
            session.uiState.onChange = nil

            var live = AppAgentActivityTimeline()
            live.appendThinking("已经展示的思考")
            live.startTool(id: "read", name: "file_read", argumentsPreview: "path=a")
            live.failTool(id: "read", name: "file_read", message: "完整错误\n最后一行")
            controller.applyActivity(live)
            session.closeTurnRecord(turnID: turnID, outcome: outcome, stage: .requesting)
            controller.reloadFromSession(reason: .browsing)
            let activity = try XCTUnwrap(controller.chatMessages.last?.activity)
            XCTAssertFalse(activity.isRunning)
            XCTAssertEqual(activity.items.map(\.detail), live.items.map(\.detail))
            XCTAssertEqual(activity.failedToolCount, 1)
            XCTAssertEqual(activity.failedStage, session.turnRecord(turnID: turnID)?.failedStage)
            XCTAssertFalse(try XCTUnwrap(controller.chatMessages.last).isActivityExpanded)
            let headerTitle = activity.headerTitle()
            if case .failed = outcome {
                XCTAssertTrue(headerTitle.hasPrefix("执行失败"), headerTitle)
            } else {
                XCTAssertTrue(headerTitle.contains("次工具失败"), headerTitle)
            }

            // 有 toolUse 不等于有最终结果；终局的自动 finish 不能擦掉实时错误。
            session.updateMessages(session.messages + [
                AIAgentMessage(role: .assistant, content: [.toolUse(.init(
                    id: "read", name: "file_read", arguments: ["path": .string("a")]
                ))], turnID: turnID)
            ])
            for _ in 0..<2 {
                controller.reloadFromSession(reason: .browsing)
                XCTAssertEqual(controller.chatMessages.last?.activity?.items.map(\.detail), activity.items.map(\.detail))
                XCTAssertEqual(controller.chatMessages.last?.activity?.failedToolCount, 1)
            }
        }
    }

    func testTerminalRefreshUsesRecordedFailureAndIgnoresLateLiveEvents() async throws {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "activity-terminal",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Failure")
        session.addUserMessage("读取文件")
        let turnID = session.currentTurnID
        session.openTurnRecord(turnID: turnID, modelRef: nil)
        let controller = AppAgentViewController()
        controller.agent = agent
        controller.switchSession(to: session.id)
        session.uiState.onChange = nil

        let call = AIAgentMessage.ToolCall(id: "read", name: "file_read", arguments: [:])
        var live = AppAgentActivityTimeline()
        live.appendThinking("先确认文件位置")
        live.startTool(id: call.id, name: call.name, argumentsPreview: "")
        live.appendThinking("等待读取结果")
        controller.applyActivity(live)
        var expanded = try XCTUnwrap(controller.chatMessages.last)
        expanded.isActivityExpanded = true
        controller.handleActivityToggled(expanded)

        session.updateMessages(session.messages + [
            AIAgentMessage(role: .assistant, content: [.text("准备读取文件"), .toolUse(call)], turnID: turnID),
            AIAgentMessage(role: .user, content: [.toolResult(.init(
                toolCallId: call.id, content: "完整错误\n最后一行", isError: true
            ))], turnID: turnID)
        ])
        session.closeTurnRecord(turnID: turnID, outcome: .failed(stage: .requesting, message: "后续请求失败"),
                                stage: .requesting)
        controller.handleUIStateChange(key: SessionUIState.runStageKey)
        controller.applyActivity(live) // 排在终局之后的旧工具事件，不可改回绿色/运行中。
        let final = try XCTUnwrap(controller.chatMessages.last)
        XCTAssertEqual(final.status, .error)
        XCTAssertTrue(final.isActivityExpanded)
        XCTAssertEqual(final.activity?.failedStage, .requesting)
        XCTAssertEqual(final.activity?.failedToolCount, 1)
        XCTAssertFalse(try XCTUnwrap(final.activity).isRunning)
        let activity = try XCTUnwrap(final.activity)
        XCTAssertEqual(activity.items.map(\.kind), [.thinking, .thinking, .tool, .thinking])
        XCTAssertEqual(activity.items.filter { $0.kind == .thinking }.map(\.detail),
                       ["先确认文件位置", "准备读取文件", "等待读取结果"])
        XCTAssertTrue(activity.items.first { $0.kind == .tool }?.detail.contains("最后一行") == true)
        XCTAssertFalse(activity.items.contains { $0.state == .running })

        for _ in 0..<3 {
            controller.reloadFromSession(reason: .browsing)
            XCTAssertEqual(controller.chatMessages.last?.activity?.items.map(\.detail), activity.items.map(\.detail))
            XCTAssertEqual(controller.chatMessages.last?.activity?.failedToolCount, 1)
        }
    }
}
#endif
