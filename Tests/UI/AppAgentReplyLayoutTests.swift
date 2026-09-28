#if canImport(UIKit)
import XCTest
import UIKit
import BOUIKit
@testable import AppAgent

/// 只覆盖列表侧的核心行为：最新回复高度单调、乐观占位与权威记录的身份衔接。
/// 像素级样式和逐帧 offset 不在单测里锁。
@MainActor
final class AppAgentReplyLayoutTests: XCTestCase {
    private let longAnswer = String(repeating: "长正文，验证回复高度与实际内容测量。\n\n", count: 40)

    func testLatestHeightSurvivesRebuildCollapseCompletionAndWidthChanges() throws {
        let list = AppAgentChatMessageListView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        installLegacy400LatestReplyFixture(on: list)
        var timeline = AppAgentActivityTimeline(startedAt: Date(timeIntervalSince1970: 100))
        timeline.appendThinking(String(repeating: "思考\n", count: 20))
        let streaming = ChatMessage(role: .assistant, text: longAnswer, status: .streaming,
                                    turnID: 1, activity: timeline, isActivityExpanded: true)
        list.setMessages([streaming])
        list.layoutIfNeeded()
        let grown = height(in: list, row: 0)
        XCTAssertGreaterThan(grown, 400)
        timeline.finish()
        for status in [ChatMessage.Status.complete, .error] {
            let rebuilt = ChatMessage(role: .assistant, text: "短的终局", status: status,
                                      turnID: 1, activity: timeline)
            XCTAssertNotEqual(rebuilt.id, streaming.id)
            list.setMessages([rebuilt], forceScrollToBottom: false)
            XCTAssertEqual(height(in: list, row: 0), grown)
            list.toggleActivityExpanded(messageID: rebuilt.id)
            list.toggleActivityExpanded(messageID: rebuilt.id)
            XCTAssertEqual(height(in: list, row: 0), grown)
        }
        list.frame.size.width = 600
        list.setNeedsLayout()
        list.layoutIfNeeded()
        XCTAssertEqual(height(in: list, row: 0), grown)
        list.append(contentsOf: [
            ChatMessage(role: .user, text: "下一问", turnID: 2),
            ChatMessage(role: .assistant, text: "", status: .streaming, turnID: 2)
        ], followLatest: false)
        XCTAssertLessThan(height(in: list, row: 0), 400)
        XCTAssertLessThan(height(in: list, row: 1), 400)
        XCTAssertEqual(height(in: list, row: 2), 400)
    }

    func testOptimisticReplyAdoptsRecordedIdentityAndClearDoesNotReuseHeight() {
        let list = AppAgentChatMessageListView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        installLegacy400LatestReplyFixture(on: list)
        let start = Date(timeIntervalSince1970: 100)
        let optimistic = ChatMessage(role: .assistant, text: longAnswer, status: .streaming,
                                     activity: AppAgentActivityTimeline(startedAt: start))
        list.setMessages([ChatMessage(role: .user, text: "同一个问题"), optimistic])
        list.layoutIfNeeded()
        let grown = height(in: list, row: 1)
        XCTAssertGreaterThan(grown, 400)
        let recorded = ChatMessage(role: .assistant, text: "短回复", turnID: 7,
                                   activity: AppAgentActivityTimeline(startedAt: start.addingTimeInterval(1)))
        list.setMessages([ChatMessage(role: .user, text: "同一个问题", turnID: 7), recorded])
        XCTAssertEqual(height(in: list, row: 1), grown)
        // 清历史后复用编号但起点不同，即使列表未先收到空快照也不能继承。
        let newTurn = ChatMessage(role: .assistant, text: "", status: .streaming, turnID: 7,
                                  activity: AppAgentActivityTimeline(startedAt: start.addingTimeInterval(2)))
        list.setMessages([newTurn])
        XCTAssertEqual(height(in: list, row: 0), 400)
        list.updateMessage(text: longAnswer, status: .streaming, messageID: newTurn.id)
        XCTAssertGreaterThan(height(in: list, row: 0), 400)
        list.setMessages([])
        list.setMessages([ChatMessage(role: .assistant, text: "新会话")])
        XCTAssertEqual(height(in: list, row: 0),
                       ChatMessageHeightCache().height(for: list.messages[0], width: 320))
    }

    func testLatestReplyGetsPlaceholderBeforeWidthIsKnown() {
        let list = AppAgentChatMessageListView()
        list.setMessages([ChatMessage(role: .assistant, text: "", status: .streaming)])
        XCTAssertEqual(height(in: list, row: 0), 400)
    }

    private func height(in list: AppAgentChatMessageListView, row: Int) -> CGFloat {
        let table = list.participantScrollView as! UITableView
        return table.delegate?.tableView?(table, heightForRowAt: IndexPath(row: row, section: 0)) ?? 0
    }

    private func installLegacy400LatestReplyFixture(on list: AppAgentChatMessageListView) {
        // Explicit fixture for independent list tests: preserve the historical
        // 400pt ladder; 400pt is not the production default.
        list.updateLatestReplyInitialHeight(
            halfScreenVisibleHeight: 554,
            bottomInset: 90
        )
    }
}
#endif
