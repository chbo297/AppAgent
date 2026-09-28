#if canImport(UIKit)
import XCTest
import UIKit
import BOUIKit
@testable import AppAgent

/// 只覆盖最新回复高度的核心链路：初始留白怎么来、什么时候只增不减、什么时候恢复实际高度。
/// 观感级细节（具体 offset、具体档位时序）不在这里锁，靠 demo 与自检验。
@MainActor
final class AppAgentReplyPresentationTests: XCTestCase {
    private let longText = String(repeating: "增长中的回复正文。\n\n", count: 40)
    private let expectedCoordinatorLatestReplyInitialHeight: CGFloat = max(
        44,
        412.5
            - 90
            - AppAgentChatMessageListView.contentBottomSpacing
            - AppAgentChatMessageListView.latestReplyUserTailHeight
    )

    func testCompletedHistoryUsesExactHeightEvenAtTail() {
        for status in [ChatMessage.Status.complete, .error] {
            for text in ["短回复", longText] {
                let list = makeList()
                let reply = ChatMessage(role: .assistant, text: text, status: status)
                list.setMessages([reply])
                list.layoutIfNeeded()
                assertExactTailHeight(in: list)
                list.setMessages([reply])
                assertExactTailHeight(in: list)
            }
        }
    }

    func testTerminalKeepsAllocationUntilNewPresentationThenNeverReallocates() {
        for status in [ChatMessage.Status.complete, .error] {
            let list = makeList()
            let reply = ChatMessage(role: .assistant, text: longText, status: .streaming)
            list.setMessages([reply])
            list.layoutIfNeeded()
            let grown = tailHeight(in: list)
            XCTAssertGreaterThan(grown, 400)
            list.updateMessage(text: "终局", status: status, messageID: reply.id)
            list.setMessages(list.messages, forceScrollToBottom: false)
            XCTAssertEqual(tailHeight(in: list), grown)
            list.updateLatestReplyInitialHeight(
                halfScreenVisibleHeight: 300,
                bottomInset: 90
            )
            XCTAssertEqual(tailHeight(in: list), grown)

            list.beginNewPresentation()
            assertExactTailHeight(in: list)
            XCTAssertLessThan(tailHeight(in: list), 400)
            // 重复终局刷新、展开过程区、旋转均不能重新分配已释放的留白。
            list.setMessages(list.messages, forceScrollToBottom: true)
            list.toggleActivityExpanded(messageID: reply.id)
            list.frame.size.width = 600
            list.setNeedsLayout()
            list.layoutIfNeeded()
            assertExactTailHeight(in: list)
            list.beginNewPresentation()
            assertExactTailHeight(in: list)
        }
    }

    func testNewPresentationDoesNotShrinkRunningReply() {
        let list = makeList()
        let reply = ChatMessage(role: .assistant, text: longText, status: .streaming)
        list.setMessages([reply])
        list.layoutIfNeeded()
        let grown = tailHeight(in: list)
        list.updateMessage(text: "仍在运行", status: .streaming, messageID: reply.id)
        list.beginNewPresentation()
        list.setMessages(list.messages, preservingReplyHeight: false)
        XCTAssertEqual(tailHeight(in: list), grown)
        list.updateMessage(text: "完成", status: .complete, messageID: reply.id)
        XCTAssertEqual(tailHeight(in: list), grown, "重入时尚未结束，之后终局仍是本次连续阅读")
        list.beginNewPresentation()
        assertExactTailHeight(in: list)
        list.append(ChatMessage(role: .assistant, text: "", status: .streaming), followLatest: false)
        XCTAssertEqual(tailHeight(in: list), 400, "下一轮重新从 400pt 分配")
    }

    func testHalfScreenInitialReplyKeepsUserTailVisible() throws {
        let halfScreenVisibleHeight: CGFloat = 412.5
        let bottomInset: CGFloat = 90
        let expectedReplyHeight = halfScreenVisibleHeight
            - bottomInset
            - AppAgentChatMessageListView.contentBottomSpacing
            - AppAgentChatMessageListView.latestReplyUserTailHeight

        for userText in [
            "单行用户消息",
            "第一行用户消息\n第二行用户消息\n最后一行用户消息"
        ] {
            let list = AppAgentChatMessageListView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 700)
            )
            list.updateLatestReplyInitialHeight(
                halfScreenVisibleHeight: halfScreenVisibleHeight,
                bottomInset: bottomInset
            )
            let history = (0..<20).map {
                ChatMessage(role: .assistant, text: "历史回复 \($0)")
            }
            let user = ChatMessage(role: .user, text: userText)
            let reply = ChatMessage(role: .assistant, text: "", status: .streaming)
            list.setMessages(history + [user, reply])
            list.updateVisibleArea(
                visibleHeight: halfScreenVisibleHeight,
                bottomInset: bottomInset
            )
            list.layoutIfNeeded()

            let table = try XCTUnwrap(list.participantScrollView as? UITableView)
            table.layoutIfNeeded()
            XCTAssertEqual(
                tailHeight(in: list),
                expectedReplyHeight,
                accuracy: 0.5
            )

            let userPath = IndexPath(row: list.messages.count - 2, section: 0)
            let userCell = try XCTUnwrap(
                table.cellForRow(at: userPath) as? ChatMessageCell,
                "半屏滚底时用户消息的最后一行必须仍有可见 cell"
            )
            let visibleContentRect = table.bounds.inset(
                by: UIEdgeInsets(
                    top: table.adjustedContentInset.top,
                    left: 0,
                    bottom: table.adjustedContentInset.bottom,
                    right: 0
                )
            )
            let userTextRect = userCell.messageTextView.convert(
                userCell.messageTextView.bounds,
                to: table
            )

            XCTAssertTrue(
                userTextRect.intersects(visibleContentRect),
                "用户消息尾部必须落在半屏有效可见区域内：\(userTextRect)"
            )
        }
    }

    func testLateGeometryRebasesFallbackButNeverShrinksRunningReply() {
        let list = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let reply = ChatMessage(role: .assistant, text: "", status: .streaming)
        list.setMessages([reply])
        list.layoutIfNeeded()
        XCTAssertEqual(tailHeight(in: list), AppAgentChatMessageListView.fallbackLatestReplyInitialHeight)

        let largerHeight: CGFloat = 650 - 90
            - AppAgentChatMessageListView.contentBottomSpacing
            - AppAgentChatMessageListView.latestReplyUserTailHeight
        list.updateLatestReplyInitialHeight(halfScreenVisibleHeight: 650, bottomInset: 90)
        XCTAssertEqual(tailHeight(in: list), largerHeight, accuracy: 0.5)

        list.updateLatestReplyInitialHeight(halfScreenVisibleHeight: 400, bottomInset: 90)
        XCTAssertEqual(tailHeight(in: list), largerHeight, accuracy: 0.5)
    }

    func testAutomaticTerminalNotificationsKeepHeightAndExplicitRefreshReleasesIt() async throws {
        for outcome in [AIAgentTurnRecord.Outcome.answered,
                        .failed(stage: .requesting, message: "失败"), .empty, .cancelled, .interrupted] {
            let (controller, session, turnID) = await makeRunningController()
            let list = controller.chatPanelView.listView
            let grown = tailHeight(in: list)
            XCTAssertGreaterThan(grown, expectedCoordinatorLatestReplyInitialHeight)
            session.closeTurnRecord(turnID: turnID, outcome: outcome, stage: .finished)
            for key in [SessionUIState.runStageKey, "isStreaming", "lastError"] {
                controller.handleUIStateChange(key: key)
                XCTAssertEqual(tailHeight(in: list), grown)
            }
            controller.reloadFromSession(reason: .browsing)
            assertExactTailHeight(in: list)
            for key in [SessionUIState.runStageKey, "isStreaming", "lastError"] {
                controller.handleUIStateChange(key: key)
                assertExactTailHeight(in: list)
            }
        }
    }

    /// 流式输出中正文末尾挂一个闪烁光标；终局立刻撤掉（连动画一起），
    /// 还没有正文的思考阶段不重复提示（那时由过程区的「思考中…」表示进行中）。
    func testStreamingCaretFollowsTextAndStopsAtTerminal() {
        let cell = ChatMessageCell(style: .default, reuseIdentifier: ChatMessageCell.reuseIdentifier)
        cell.bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
        cell.contentView.bounds = cell.bounds

        cell.configure(with: ChatMessage(role: .assistant, text: "正在输出", status: .streaming))
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        XCTAssertFalse(cell.streamingCaretView.isHidden)
        XCTAssertEqual(cell.streamingCaretView.layer.animationKeys()?.isEmpty, false, "光标要在闪")
        // 贴在最后一个字形之后：越过了行首，也没跑出正文宽度。
        XCTAssertGreaterThan(cell.streamingCaretView.frame.minX, 0)
        XCTAssertLessThanOrEqual(
            cell.streamingCaretView.frame.maxX,
            cell.messageTextView.bounds.width + 4
        )

        cell.configure(with: ChatMessage(role: .assistant, text: "输出完成", status: .complete))
        XCTAssertTrue(cell.streamingCaretView.isHidden)
        XCTAssertNil(cell.streamingCaretView.layer.animationKeys())

        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("分析中")
        cell.configure(with: ChatMessage(
            role: .assistant, text: "", status: .streaming,
            activity: timeline, isActivityExpanded: true
        ))
        XCTAssertTrue(cell.streamingCaretView.isHidden)
    }

    private func makeList() -> AppAgentChatMessageListView {
        let list = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )
        // Explicit fixture for independent list tests: preserve the historical
        // 400pt ladder; 400pt is not the production default.
        list.updateLatestReplyInitialHeight(
            halfScreenVisibleHeight: 554,
            bottomInset: 90
        )
        return list
    }

    private func makeRunningController() async -> (AppAgentViewController, AISession, Int) {
        let agent = await AIAgentCentral().create(
            name: "presentation-height",
            profile: AIAgentProfile(autoPersist: false, registerBuiltInTools: false),
            sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Presentation")
        let turnID = session.addUserMessage("问题")
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
        if let reply = list.messages.last {
            list.updateMessage(text: longText, status: .streaming, messageID: reply.id)
        }
        return (controller, session, turnID)
    }

    private func tailHeight(in list: AppAgentChatMessageListView) -> CGFloat {
        let table = list.participantScrollView as! UITableView
        return table.delegate?.tableView?(
            table, heightForRowAt: IndexPath(row: list.messages.count - 1, section: 0)
        ) ?? 0
    }

    private func assertExactTailHeight(
        in list: AppAgentChatMessageListView, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let reply = list.messages.last else {
            return XCTFail("缺少尾回复", file: file, line: line)
        }
        let measured = ChatMessageHeightCache().height(for: reply, width: list.participantScrollView.bounds.width)
        XCTAssertEqual(tailHeight(in: list), measured, accuracy: 0.5, file: file, line: line)
    }
}
#endif
