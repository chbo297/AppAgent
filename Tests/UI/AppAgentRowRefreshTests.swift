#if canImport(UIKit)
import UIKit
import XCTest
@testable import AppAgent

@MainActor
final class AppAgentRowRefreshTests: XCTestCase {
    private let answer = "今天是**周四**（2026年9月24日）。"

    func testHeightChangingHeaderTapsKeepCellAndTextStorage() throws {
        let reply = completedReply()
        let list = makeList([reply, ChatMessage(role: .user, text: "下一问")])
        let table = table(in: list)
        let path = IndexPath(row: 0, section: 0)
        let cell = try visibleCell(in: table, at: path)
        let header = try XCTUnwrap(descendants(UIControl.self, in: cell).first {
            $0.accessibilityValue == "已收起"
        })
        let collapsedHeight = table.rectForRow(at: path).height
        let followingTop = table.rectForRow(at: IndexPath(row: 1, section: 0)).minY
        let selection = NSRange(location: 0, length: 2)
        cell.messageTextView.selectedRange = selection
        let edits = RowRefreshTextEditProbe()
        cell.messageTextView.textStorage.delegate = edits
        defer { cell.messageTextView.textStorage.delegate = nil }

        for _ in 0..<20 {
            try invokeRegisteredAction(header)
            XCTAssertTrue(try visibleCell(in: table, at: path) === cell)
            XCTAssertEqual(header.accessibilityValue, "已展开")
            XCTAssertGreaterThan(table.rectForRow(at: path).height, collapsedHeight)
            XCTAssertGreaterThan(table.rectForRow(at: IndexPath(row: 1, section: 0)).minY, followingTop)
            try invokeRegisteredAction(header)
            XCTAssertTrue(try visibleCell(in: table, at: path) === cell)
            XCTAssertEqual(header.accessibilityValue, "已收起")
            XCTAssertEqual(table.rectForRow(at: path).height, collapsedHeight, accuracy: 0.5)
            XCTAssertEqual(table.rectForRow(at: IndexPath(row: 1, section: 0)).minY, followingTop, accuracy: 0.5)
            XCTAssertEqual(cell.messageTextView.selectedRange, selection)
            // 检查实际子视图树，不只看 visibleCells：退出中的旧 cell 也不能留下第二份正文。
            XCTAssertEqual(descendants(UITextView.self, in: table).filter {
                $0.text == cell.messageTextView.text
            }.count, 1)
        }
        XCTAssertEqual(edits.count, 0, "只改过程区不能重新写入正文 textStorage")
        assertHeightsMatch(in: list)
    }

    func testReserved400PointReplyOnlyChangesInternalLayout() throws {
        let reply = completedReply()
        let list = makeList([])
        list.append(reply, followLatest: false)
        let table = table(in: list)
        table.layoutIfNeeded()
        let path = IndexPath(row: 0, section: 0)
        let cell = try visibleCell(in: table, at: path)
        let collapsedY = cell.messageTextView.convert(.zero, to: cell.contentView).y
        let size = table.contentSize
        let offset = table.contentOffset
        XCTAssertEqual(table.rectForRow(at: path).height, 400)

        let edits = RowRefreshTextEditProbe()
        cell.messageTextView.textStorage.delegate = edits
        defer { cell.messageTextView.textStorage.delegate = nil }
        for _ in 0..<20 {
            list.toggleActivityExpanded(messageID: reply.id)
            XCTAssertGreaterThan(cell.messageTextView.convert(.zero, to: cell.contentView).y, collapsedY)
            list.toggleActivityExpanded(messageID: reply.id)
            XCTAssertEqual(cell.messageTextView.convert(.zero, to: cell.contentView).y, collapsedY, accuracy: 0.5)
            XCTAssertTrue(try visibleCell(in: table, at: path) === cell)
            XCTAssertEqual(table.rectForRow(at: path).height, 400)
            XCTAssertEqual(table.contentSize, size)
            XCTAssertEqual(table.contentOffset, offset)
        }
        XCTAssertEqual(edits.count, 0)
    }

    func testStreamingGrowthAcrossHeightStepsKeepsCell() throws {
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.streaming)
        let reply = ChatMessage(role: .assistant, text: "开始", status: .streaming,
                                activity: timeline, isActivityExpanded: true)
        let list = makeList([reply])
        let table = table(in: list)
        let path = IndexPath(row: 0, section: 0)
        let cell = try visibleCell(in: table, at: path)
        var previousHeight = table.rectForRow(at: path).height
        XCTAssertEqual(previousHeight, 400)
        for count in [30, 50, 70] {
            let text = String(repeating: "逐步增加的正文。\n\n", count: count)
            list.updateMessage(text: text, status: .streaming, messageID: reply.id)
            table.layoutIfNeeded()
            XCTAssertTrue(try visibleCell(in: table, at: path) === cell)
            XCTAssertEqual(cell.messageTextView.text, AppAgentMarkdown.attributed(
                text, baseFont: .systemFont(ofSize: 15), color: AppAgentAppearance.primaryText
            ).string)
            XCTAssertGreaterThan(table.rectForRow(at: path).height, previousHeight)
            previousHeight = table.rectForRow(at: path).height
            assertHeightsMatch(in: list)
        }
        timeline.finish()
        list.updateActivity(timeline, expanded: false, messageID: reply.id)
        list.updateMessage(text: "完成", status: .complete, messageID: reply.id)
        XCTAssertTrue(try visibleCell(in: table, at: path) === cell)
        XCTAssertEqual(cell.messageTextView.text, "完成")
        XCTAssertEqual(table.rectForRow(at: path).height, previousHeight)
    }

    func testOffscreenHeightChangeIsAppliedWithoutDequeuingTarget() throws {
        let reply = completedReply()
        let list = makeList([reply] + (0..<50).map {
            ChatMessage(role: .user, text: "历史 \($0)")
        })
        let table = table(in: list)
        list.scrollToBottom(animated: false)
        table.layoutIfNeeded()
        let path = IndexPath(row: 0, section: 0)
        XCTAssertNil(table.cellForRow(at: path))
        let collapsedHeight = table.rectForRow(at: path).height
        list.toggleActivityExpanded(messageID: reply.id)
        table.layoutIfNeeded()
        XCTAssertGreaterThan(table.rectForRow(at: path).height, collapsedHeight)
        XCTAssertNil(table.cellForRow(at: path), "离屏更新不能主动创建目标 cell")
        list.toggleActivityExpanded(messageID: reply.id)
        XCTAssertEqual(table.rectForRow(at: path).height, collapsedHeight, accuracy: 0.5)
        assertHeightsMatch(in: list)
        table.scrollToRow(at: path, at: .top, animated: false)
        table.layoutIfNeeded()
        let cell = try visibleCell(in: table, at: path)
        XCTAssertEqual(cell.messageTextView.text, "今天是周四（2026年9月24日）。")
    }

    func testUpdatesBeforeFirstLayoutAndAfterSameCountReplacementUseLatestSnapshot() throws {
        let list = AppAgentChatMessageListView()
        let old = completedReply()
        list.setMessages([old], forceScrollToBottom: false)
        list.toggleActivityExpanded(messageID: old.id)
        list.updateMessage(text: "未布局时收到的正文", status: .complete, messageID: old.id)
        let replacement = completedReply()
        list.setMessages([replacement], forceScrollToBottom: false)
        list.toggleActivityExpanded(messageID: replacement.id)
        list.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        list.updateVisibleArea(visibleHeight: 600, bottomInset: 0)
        list.layoutIfNeeded()
        let table = table(in: list)
        table.layoutIfNeeded()
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(try visibleCell(in: table, at: IndexPath(row: 0, section: 0)).messageTextView.text,
                       "今天是周四（2026年9月24日）。")
        assertHeightsMatch(in: list)

        // 同行数的新快照尚未布局，就立刻收到展开态和正文更新。
        let next = completedReply()
        list.setMessages([next], forceScrollToBottom: false)
        list.toggleActivityExpanded(messageID: next.id)
        list.updateMessage(text: "新的会话正文", status: .complete, messageID: next.id)
        table.layoutIfNeeded()
        XCTAssertEqual(try visibleCell(in: table, at: IndexPath(row: 0, section: 0)).messageTextView.text,
                       "新的会话正文")
        assertHeightsMatch(in: list)
    }

    func testRapidUpdatesInterleavedWithAppendClearAndReplacement() throws {
        let list = makeList([])
        let table = table(in: list)
        for index in 0..<30 {
            let reply = completedReply()
            list.setMessages([reply], forceScrollToBottom: false, preservingReplyHeight: false)
            list.toggleActivityExpanded(messageID: reply.id)
            list.updateMessage(text: String(repeating: "正文\n\n", count: 2 + index % 5),
                               status: .complete, messageID: reply.id)
            list.append(ChatMessage(role: .user, text: "下一问"), followLatest: false)
            list.toggleActivityExpanded(messageID: reply.id)
            table.layoutIfNeeded()
            XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
            assertHeightsMatch(in: list)
            list.setMessages([], forceScrollToBottom: false)
            list.toggleActivityExpanded(messageID: reply.id)
            list.updateMessage(text: "迟到的更新", status: .complete, messageID: reply.id)
            table.layoutIfNeeded()
            XCTAssertEqual(table.numberOfRows(inSection: 0), 0)
        }
    }

    func testPreviouslyVisibleListRefreshesTextAfterZeroHeightViewport() throws {
        let reply = completedReply()
        let list = makeList([reply, ChatMessage(role: .user, text: "下一问")])
        let table = table(in: list)
        let path = IndexPath(row: 0, section: 0)
        _ = try visibleCell(in: table, at: path)
        let originalHeight = table.rectForRow(at: path).height
        // 不先点过程区：setMessages 的 reload 可能早已由 UIKit 布局消费，
        // 但列表自己的 needsReloadLayout 仍为 true，也必须登记零高期间的新内容。
        list.updateVisibleArea(visibleHeight: 0, bottomInset: 0)
        XCTAssertEqual(table.bounds.height, 0)
        let text = String(repeating: "隐藏期间收到正文。\n\n", count: 10)
        list.updateMessage(text: text, status: .complete, messageID: reply.id)
        list.updateVisibleArea(visibleHeight: 600, bottomInset: 0)
        list.layoutIfNeeded()
        table.layoutIfNeeded()
        XCTAssertGreaterThan(table.rectForRow(at: path).height, originalHeight)
        assertHeightsMatch(in: list)
        XCTAssertEqual(try visibleCell(in: table, at: path).messageTextView.text,
                       AppAgentMarkdown.attributed(text, baseFont: .systemFont(ofSize: 15),
                                                   color: AppAgentAppearance.primaryText).string)
    }

    func testPreviouslyVisibleListRefreshesActivityAfterZeroHeightViewport() throws {
        let reply = completedReply()
        let list = makeList([reply, ChatMessage(role: .user, text: "下一问")])
        let table = table(in: list)
        let path = IndexPath(row: 0, section: 0)
        _ = try visibleCell(in: table, at: path)
        let originalHeight = table.rectForRow(at: path).height
        list.updateVisibleArea(visibleHeight: 0, bottomInset: 0)
        XCTAssertEqual(table.bounds.height, 0)
        // 只更新展开态，不借正文刷新来提交这次高度变化。
        list.toggleActivityExpanded(messageID: reply.id)
        list.updateVisibleArea(visibleHeight: 600, bottomInset: 0)
        list.layoutIfNeeded()
        table.layoutIfNeeded()
        XCTAssertGreaterThan(table.rectForRow(at: path).height, originalHeight)
        assertHeightsMatch(in: list)
        let cell = try visibleCell(in: table, at: path)
        XCTAssertTrue(descendants(UIControl.self, in: cell).contains {
            $0.accessibilityValue == "已展开"
        })
        XCTAssertEqual(cell.messageTextView.text, "今天是周四（2026年9月24日）。")
    }

    func testToggleCallbackCanClearTheList() {
        let reply = completedReply()
        let list = makeList([reply])
        list.onActivityToggled = { [weak list] _ in list?.setMessages([]) }
        list.toggleActivityExpanded(messageID: reply.id)
        table(in: list).layoutIfNeeded()
        XCTAssertTrue(list.messages.isEmpty)
        XCTAssertEqual(table(in: list).numberOfRows(inSection: 0), 0)
    }

    func testTextRenderCacheInvalidatesForTextRoleErrorAndReuse() throws {
        let cell = ChatMessageCell(style: .default, reuseIdentifier: nil)
        var message = completedReply()
        cell.configure(with: message)
        let normalColor = cell.messageTextView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        message.status = .error
        cell.configure(with: message)
        XCTAssertEqual(cell.messageTextView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                       AppAgentAppearance.errorText)
        message.status = .complete
        cell.configure(with: message)
        XCTAssertEqual(cell.messageTextView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                       normalColor)
        message.text = "新的**答案** [链接](https://example.com)"
        cell.configure(with: message)
        XCTAssertEqual(cell.messageTextView.text, "新的答案 链接")
        let linkRange = (cell.messageTextView.text as NSString).range(of: "链接")
        XCTAssertNotNil(cell.messageTextView.attributedText.attribute(.link, at: linkRange.location, effectiveRange: nil))

        cell.messageTextView.selectedRange = NSRange(location: 0, length: 2)
        let user = ChatMessage(role: .user, text: message.text)
        cell.configure(with: user)
        XCTAssertEqual(cell.messageTextView.text, message.text, "用户消息不能复用 assistant 的 Markdown 结果")
        XCTAssertEqual(cell.messageTextView.selectedRange.length, 0)
        cell.prepareForReuse()
        cell.configure(with: message)
        XCTAssertEqual(cell.messageTextView.text, "新的答案 链接")
        XCTAssertEqual(cell.messageTextView.selectedRange.length, 0)
    }

    /// 行高缓存的身份必须活过重建：`ChatMessage.id` 每次组装都是新 UUID，
    /// 所以缓存只能挂在 Core 分配并落盘的 turnID 上（`ChatRowIdentity`）。
    ///
    /// 按 `id` 缓存时跨重建 100% miss —— 一轮里 `.preparing` / runStage 变化 / 流式结束 /
    /// 终局各触发一次整表重建，每次都要用模板 cell 把每一行重测 + 重解析 Markdown。
    func testRowIdentityStaysStableAcrossRebuild() {
        let first = completedReply(turnID: 7)
        let rebuilt = completedReply(turnID: 7)

        XCTAssertNotEqual(first.id, rebuilt.id)
        XCTAssertEqual(ChatRowIdentity(first), ChatRowIdentity(rebuilt))

        // 同一轮里用户气泡与 agent 回复是两行，不能共用一份高度。
        XCTAssertNotEqual(
            ChatRowIdentity(first),
            ChatRowIdentity(ChatMessage(role: .user, text: answer, turnID: 7))
        )
        XCTAssertNotEqual(ChatRowIdentity(first), ChatRowIdentity(completedReply(turnID: 8)))

        // 还没拿到 turnID 的乐观占位行只在本次列表内有效，彼此不可混用。
        let optimistic = ChatMessage(role: .assistant, text: answer)
        XCTAssertEqual(ChatRowIdentity(optimistic), ChatRowIdentity(optimistic))
        XCTAssertNotEqual(
            ChatRowIdentity(optimistic),
            ChatRowIdentity(ChatMessage(role: .assistant, text: answer))
        )
    }

    /// `suppressResolvedActivity` 决定整个过程区显隐，必须进测量输入。
    ///
    /// 身份稳定之后，漏掉它就会让同一行命中上一次的高度：过程区该显示时按隐藏的高度画，
    /// 而 cell / contentView / 过程区都 `clipsToBounds`，直接表现为内容被裁掉一截。
    func testSuppressResolvedActivityParticipatesInMeasuredHeight() {
        let cache = ChatMessageHeightCache()
        var shown = completedReply(turnID: 3)
        shown.suppressResolvedActivity = false
        var hidden = shown
        hidden.suppressResolvedActivity = true

        let shownHeight = cache.height(for: shown, width: 390)
        let hiddenHeight = cache.height(for: hidden, width: 390)

        XCTAssertGreaterThan(shownHeight, hiddenHeight)
    }

    /// 尾回复「已分配高度」的增长是一条显式命令，读行高一律不写状态。
    ///
    /// 这两条是本次读写分离建立的不变量（不是对某个可复现失败的回放）：
    /// ① 反复取高不改变结果 —— 防止再把增长塞回 getter：那样「读一次高度」就等于
    ///   「消耗掉一次增长」，`refreshRow` 前后两次取值会相等并按「高度没变」短路掉 batch；
    /// ② 增长后的高度仍落在 34pt 台阶上 —— 证明 `refreshRow` 里那次显式 reserve 真的生效，
    ///   而不是靠 getter 的 `max(measured, allocated)` 直接返回了裸内容高度。
    func testReservedTailHeightGrowsOnlyByExplicitReserve() throws {
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.streaming)
        let reply = ChatMessage(role: .assistant, text: "开始", status: .streaming,
                                activity: timeline, isActivityExpanded: true)
        let list = makeList([reply])
        let table = table(in: list)
        let path = IndexPath(row: 0, section: 0)
        let initialHeight = try XCTUnwrap(table.delegate?.tableView?(table, heightForRowAt: path))
        XCTAssertEqual(initialHeight, 400)
        for _ in 0..<20 {
            XCTAssertEqual(table.delegate?.tableView?(table, heightForRowAt: path), initialHeight)
        }

        let text = String(repeating: "逐步增加的正文。\n\n", count: 40)
        list.updateMessage(text: text, status: .streaming, messageID: reply.id)
        table.layoutIfNeeded()
        let grown = try XCTUnwrap(table.delegate?.tableView?(table, heightForRowAt: path))
        XCTAssertGreaterThan(grown, initialHeight)
        XCTAssertEqual((grown - initialHeight).truncatingRemainder(
            dividingBy: AppAgentChatMessageListView.latestReplyHeightStep
        ), 0, accuracy: 0.01, "增长必须按台阶走，不能直接用裸内容高度")
        for _ in 0..<20 {
            XCTAssertEqual(table.delegate?.tableView?(table, heightForRowAt: path), grown)
        }
        assertHeightsMatch(in: list)
    }

    /// 宽度变窄 → 正文换行更多 → 内容更高：已分配高度同样只增不减。
    /// 这一步以前是靠 getter 的副作用顺带完成的，读写分离后由 `applyTableViewFrame` 显式调用。
    func testNarrowingWidthStillRaisesReservedTailHeight() throws {
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.streaming)
        let reply = ChatMessage(role: .assistant,
                                text: String(repeating: "需要按宽度重新换行的一段正文。", count: 40),
                                status: .streaming, activity: timeline, isActivityExpanded: true)
        let list = makeList([reply])
        let table = table(in: list)
        let path = IndexPath(row: 0, section: 0)
        let wideHeight = try XCTUnwrap(table.delegate?.tableView?(table, heightForRowAt: path))

        list.frame = CGRect(x: 0, y: 0, width: 240, height: 600)
        list.layoutIfNeeded()
        table.layoutIfNeeded()
        let narrowHeight = try XCTUnwrap(table.delegate?.tableView?(table, heightForRowAt: path))
        XCTAssertGreaterThan(narrowHeight, wideHeight)
        assertHeightsMatch(in: list)

        // 转回宽视口不缩高：当前连续阅读期间已分配高度只增不减。
        list.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        list.layoutIfNeeded()
        table.layoutIfNeeded()
        XCTAssertEqual(table.delegate?.tableView?(table, heightForRowAt: path), narrowHeight)
        assertHeightsMatch(in: list)
    }

    private func completedReply() -> ChatMessage {
        completedReply(turnID: nil)
    }


    private func completedReply(turnID: Int?) -> ChatMessage {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("已完成处理")
        timeline.finish()
        return ChatMessage(role: .assistant, text: answer, turnID: turnID, activity: timeline)
    }

    private func makeList(_ messages: [ChatMessage]) -> AppAgentChatMessageListView {
        let list = AppAgentChatMessageListView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        // Explicit fixture for independent list tests: preserve the historical
        // 400pt ladder; 400pt is not the production default.
        list.updateLatestReplyInitialHeight(
            halfScreenVisibleHeight: 554,
            bottomInset: 90
        )
        list.setMessages(messages, forceScrollToBottom: false)
        list.updateVisibleArea(visibleHeight: 600, bottomInset: 0)
        list.layoutIfNeeded()
        table(in: list).layoutIfNeeded()
        return list
    }

    private func table(in list: AppAgentChatMessageListView) -> UITableView {
        list.participantScrollView as! UITableView
    }

    private func visibleCell(in table: UITableView, at path: IndexPath) throws -> ChatMessageCell {
        table.layoutIfNeeded()
        return try XCTUnwrap(table.cellForRow(at: path) as? ChatMessageCell)
    }

    private func assertHeightsMatch(in list: AppAgentChatMessageListView,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let table = table(in: list)
        table.layoutIfNeeded()
        var total: CGFloat = 0
        for row in list.messages.indices {
            let path = IndexPath(row: row, section: 0)
            let height = table.delegate?.tableView?(table, heightForRowAt: path) ?? 0
            XCTAssertEqual(table.rectForRow(at: path).height, height, accuracy: 0.5, file: file, line: line)
            total += height
        }
        XCTAssertEqual(table.contentSize.height, total, accuracy: 0.5, file: file, line: line)
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
}

private final class RowRefreshTextEditProbe: NSObject, NSTextStorageDelegate {
    private(set) var count = 0

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        count += 1
    }
}
#endif
