#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

/// 过程时间线的折叠/摘要逻辑，以及 cell / 列表的展开切换。
final class AppAgentActivityTimelineTests: XCTestCase {

    func testConsecutiveThinkingMergesIntoOneStep() {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("先看")
        timeline.appendThinking("设置页结构")
        XCTAssertEqual(timeline.items.count, 1)
        XCTAssertEqual(timeline.items.first?.kind, .thinking)
        XCTAssertEqual(timeline.items.first?.detail, "先看设置页结构")
        XCTAssertEqual(timeline.stepCount, 0, "思考不计入步数")
    }

    func testToolBreaksThinkingAndCountsAsStep() {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("需要读文件")
        timeline.startTool(id: "c1", name: "file_read", argumentsPreview: "path=a.swift")
        timeline.finishTool(id: "c1", resultPreview: "12 行")
        timeline.appendThinking("继续分析")

        XCTAssertEqual(timeline.items.count, 3)
        XCTAssertEqual(timeline.items[0].state, .done, "工具开始时收尾上一段思考")
        XCTAssertEqual(timeline.items[1].title, "file_read")
        XCTAssertEqual(timeline.items[1].state, .done)
        XCTAssertTrue(timeline.items[1].detail.contains("参数：path=a.swift"))
        XCTAssertTrue(timeline.items[1].detail.contains("结果：12 行"))
        XCTAssertEqual(timeline.items[2].kind, .thinking)
        XCTAssertEqual(timeline.stepCount, 1)
    }

    func testFailedToolIsMarkedAndKeepsMessage() {
        var timeline = AppAgentActivityTimeline()
        timeline.startTool(id: "c1", name: "file_write", argumentsPreview: "")
        timeline.failTool(id: "c1", name: "file_write", message: "权限不足")
        XCTAssertEqual(timeline.items.first?.state, .failed)
        XCTAssertTrue(timeline.items.first?.detail.contains("权限不足") ?? false)
    }

    /// 进行中：标题跟着当前动作变；结束后变成「已思考 x 秒 · N 步」。
    func testHeaderTitleTracksRunningStateThenSummarises() {
        var timeline = AppAgentActivityTimeline(startedAt: Date().addingTimeInterval(-3))
        timeline.appendThinking("分析")
        XCTAssertEqual(timeline.headerTitle(), "思考中…")

        timeline.startTool(id: "c1", name: "app_runtime_inspect", argumentsPreview: "")
        XCTAssertEqual(timeline.headerTitle(), "执行 app_runtime_inspect…")

        timeline.finishTool(id: "c1", resultPreview: "ok")
        XCTAssertEqual(timeline.headerTitle(), "已完成 app_runtime_inspect，继续思考…")

        timeline.finish()
        XCTAssertFalse(timeline.isRunning)
        let title = timeline.headerTitle()
        XCTAssertTrue(title.hasPrefix("已思考 "), title)
        XCTAssertTrue(title.hasSuffix("· 1 步"), title)
    }

    /// 摘要取最新一段思考的最后一行；没有思考时退化成工具名序列。
    func testHeaderSummaryPrefersLatestThinkingLine() {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("# 标题\n先检查协议探查\n再看模型列表")
        XCTAssertEqual(timeline.headerSummary, "再看模型列表")

        var toolsOnly = AppAgentActivityTimeline()
        toolsOnly.startTool(id: "1", name: "file_read", argumentsPreview: "")
        toolsOnly.startTool(id: "2", name: "file_write", argumentsPreview: "")
        XCTAssertEqual(toolsOnly.headerSummary, "file_read → file_write")
    }

    func testFinishClosesRunningStepsOnce() {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("思考")
        timeline.startTool(id: "c1", name: "t", argumentsPreview: "")
        timeline.finish()
        XCTAssertTrue(timeline.items.allSatisfy { $0.state != .running })
        let finishedAt = timeline.finishedAt
        timeline.finish()
        XCTAssertEqual(timeline.finishedAt, finishedAt, "重复 finish 不刷新时间")
    }

    /// cell 能渲染过程区并把折叠点击回调出去；列表侧切换展开态。
    func testCellExposesToggleAndListFlipsExpandedState() {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("分析中")

        let cell = ChatMessageCell(style: .default, reuseIdentifier: ChatMessageCell.reuseIdentifier)
        var toggled = false
        cell.onToggleActivity = { toggled = true }
        cell.configure(with: ChatMessage(
            role: .assistant, text: "", status: .streaming, activity: timeline, isActivityExpanded: true
        ))
        cell.onToggleActivity?()
        XCTAssertTrue(toggled)

        let list = AppAgentChatMessageListView()
        let message = ChatMessage(
            role: .assistant, text: "结果", activity: timeline, isActivityExpanded: false
        )
        list.setMessages([message])
        list.toggleActivityExpanded(messageID: message.id)
        XCTAssertEqual(list.messages.first?.isActivityExpanded, true)
        list.toggleActivityExpanded(messageID: message.id)
        XCTAssertEqual(list.messages.first?.isActivityExpanded, false)
    }

    /// 过程区真实出布局：展开后明细行让 cell 变高；进行中的最新一轮即便展开也保留摘要行。
    func testActivityViewLaysOutCollapsedAndExpandedStates() {
        var timeline = AppAgentActivityTimeline(startedAt: Date().addingTimeInterval(-2.5))
        timeline.appendThinking("先确认设置页的探查逻辑\n再看模型可用性实测")
        timeline.startTool(id: "c1", name: "file_read", argumentsPreview: "path=AppAgentModelDiscovery.swift")
        timeline.finishTool(id: "c1", resultPreview: "读到 214 行")
        timeline.appendThinking("准备汇总结论")

        func height(expanded: Bool) -> CGFloat {
            let cell = ChatMessageCell(style: .default, reuseIdentifier: ChatMessageCell.reuseIdentifier)
            cell.configure(with: ChatMessage(
                role: .assistant, text: "", status: .streaming,
                activity: timeline, isActivityExpanded: expanded
            ))
            cell.bounds = CGRect(x: 0, y: 0, width: 390, height: 400)
            cell.contentView.bounds = cell.bounds
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            return cell.contentView.systemLayoutSizeFitting(
                CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }

        let collapsed = height(expanded: false)
        let expanded = height(expanded: true)
        XCTAssertGreaterThan(collapsed, 0)
        XCTAssertGreaterThan(expanded, collapsed, "展开明细必须比折叠更高（collapsed=\(collapsed) expanded=\(expanded)）")

        // 进行中 + 展开：摘要行仍然可见（“最新一轮默认展开且有摘要”）。
        let view = AppAgentActivityView()
        view.configure(with: timeline, expanded: true)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: timeline.headerSummary),
                      "进行中的过程区展开时应保留摘要行")

        // 结束后折叠：标题变成汇总，摘要仍作为一行提示保留。
        timeline.finish()
        view.configure(with: timeline, expanded: false)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: timeline.headerTitle()))
        XCTAssertFalse(timeline.isRunning)
    }

    private static func hasVisibleLabel(in root: UIView, text: String?) -> Bool {
        guard let text = text else { return false }
        if let label = root as? UILabel, label.isHidden == false, label.text == text { return true }
        return root.subviews.contains { hasVisibleLabel(in: $0, text: text) }
    }
}
#endif
