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

    func testCompletedEventWithErrorOutputIsStillFailure() {
        var timeline = AppAgentActivityTimeline()
        timeline.startTool(id: "bad", name: "web_fetch", argumentsPreview: "")
        timeline.completeTool(id: "bad", result: .error("拒绝访问\n原因完整保留"))
        timeline.startTool(id: "ok", name: "file_read", argumentsPreview: "")
        timeline.completeTool(id: "ok", result: .text("Error: 这是读取到的日志，不是工具失败"))
        timeline.finish()

        XCTAssertEqual(timeline.items[0].state, .failed)
        XCTAssertEqual(timeline.items[1].state, .done)
        XCTAssertEqual(timeline.failedToolCount, 1)
        XCTAssertEqual(timeline.displayedFailedStage, .tooling)
        XCTAssertTrue(timeline.showsStageStrip)
        XCTAssertTrue(timeline.displayedErrorText?.contains("原因完整保留") == true)
    }

    /// 进行中标题跟随动作；有过程的结束轮次保留入口，不显示耗时或轮数。
    func testHeaderTitleTracksRunningStateThenSummarises() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var timeline = AppAgentActivityTimeline(startedAt: startedAt, roundCount: 2)
        timeline.appendThinking("分析")
        XCTAssertEqual(timeline.headerTitle(), "思考中…")

        timeline.startTool(id: "c1", name: "app_runtime_inspect", argumentsPreview: "")
        XCTAssertEqual(timeline.headerTitle(), "执行 app_runtime_inspect…")

        timeline.finishTool(id: "c1", resultPreview: "ok")
        XCTAssertEqual(timeline.headerTitle(), "已完成 app_runtime_inspect，继续思考…")

        timeline.finish(at: startedAt.addingTimeInterval(3))
        XCTAssertFalse(timeline.isRunning)
        let title = timeline.headerTitle()
        XCTAssertEqual(title, "处理过程")
        XCTAssertEqual(timeline.roundCount, 2)
        XCTAssertEqual(timeline.elapsed(), 3)
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

    func testDisplayedContentMergeKeepsOrderAndIsIdempotent() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var live = AppAgentActivityTimeline(startedAt: startedAt)
        live.appendThinking("先分析")
        live.startTool(id: "a", name: "file_read", argumentsPreview: "")
        live.appendThinking("再分析")
        live.startTool(id: "b", name: "file_search", argumentsPreview: "")
        live.appendThinking("总结")

        var recorded = AppAgentActivityTimeline(startedAt: startedAt, roundCount: 3)
        recorded.appendRecordedThinking("先读文件", id: "message-1")
        recorded.startTool(id: "a", name: "file_read", argumentsPreview: "")
        recorded.finishTool(id: "a", resultPreview: "文件全文")
        recorded.appendRecordedThinking("再查引用", id: "message-2")
        recorded.startTool(id: "b", name: "file_search", argumentsPreview: "")
        recorded.failTool(id: "b", name: "file_search", message: "查询失败")
        recorded.finish(at: startedAt.addingTimeInterval(5))

        var merged = recorded
        merged.preserveDisplayedItems(from: live)
        XCTAssertEqual(merged.items.map(\.detail), [
            "先分析", "先读文件", "结果：文件全文", "再分析", "再查引用", "失败：查询失败", "总结"
        ])
        XCTAssertEqual(merged.failedToolCount, 1)
        XCTAssertEqual(merged.headerTitle(), "1 次工具失败")
        XCTAssertFalse(merged.items.contains { $0.state == .running })
        for _ in 0..<3 {
            var reloaded = recorded
            reloaded.preserveDisplayedItems(from: merged)
            XCTAssertEqual(reloaded, merged)
            merged = reloaded
        }
    }

    func testToolUseWithoutResultDoesNotEraseDisplayedOutput() {
        let startedAt = Date(timeIntervalSince1970: 100)
        for output in [Tool.Output.text("完整结果\n最后一行"), .text(""), .error("完整错误\n最后一行")] {
            var displayed = AppAgentActivityTimeline(startedAt: startedAt)
            displayed.startTool(id: "read", name: "file_read", argumentsPreview: "")
            displayed.completeTool(id: "read", result: output)

            var callOnly = AppAgentActivityTimeline(startedAt: startedAt)
            callOnly.startTool(id: "read", name: "file_read", argumentsPreview: "")
            for isFinished in [false, true] {
                var rebuilt = callOnly
                if isFinished { rebuilt.finish(at: startedAt.addingTimeInterval(2)) }
                rebuilt.preserveDisplayedItems(from: displayed)
                XCTAssertEqual(rebuilt.items, displayed.items)
                XCTAssertEqual(rebuilt.isRunning, !isFinished)
            }

            // 之后真正的 wire 结果仍然优先，不能被已保留的实时失败钉住。
            var final = callOnly
            final.finishTool(id: "read", resultPreview: "最终记录的结果")
            final.finish(at: startedAt.addingTimeInterval(2))
            final.preserveDisplayedItems(from: displayed)
            XCTAssertEqual(final.items.first?.detail, "结果：最终记录的结果")
            XCTAssertEqual(final.items.first?.state, .done)
            XCTAssertEqual(final.failedToolCount, 0)
        }
    }

    /// cell 能渲染真实过程区并把折叠点击回调出去；列表侧切换展开态。
    @MainActor
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

    func testActivityAndCellClipDuringCollapse() {
        var timeline = AppAgentActivityTimeline(startedAt: Date(timeIntervalSince1970: 100), roundCount: 2)
        timeline.appendThinking(String(repeating: "长过程\n", count: 30))
        timeline.finish(at: Date(timeIntervalSince1970: 103))

        let cell = ChatMessageCell(style: .default, reuseIdentifier: ChatMessageCell.reuseIdentifier)
        let expanded = ChatMessage(
            role: .assistant,
            text: "答案",
            status: .complete,
            activity: timeline,
            isActivityExpanded: true
        )
        cell.configure(with: expanded)
        cell.bounds = CGRect(x: 0, y: 0, width: 390, height: 600)
        cell.contentView.bounds = cell.bounds
        cell.layoutIfNeeded()

        let collapsed = ChatMessage(
            role: .assistant,
            text: "答案",
            status: .complete,
            activity: timeline,
            isActivityExpanded: false
        )
        cell.configure(with: collapsed)
        let collapsedHeight = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        cell.bounds.size.height = collapsedHeight
        cell.contentView.bounds = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        XCTAssertTrue(cell.clipsToBounds)
        XCTAssertTrue(cell.contentView.clipsToBounds)
        let activityView = Self.descendant(AppAgentActivityView.self, in: cell)
        XCTAssertTrue(activityView?.clipsToBounds == true)
        XCTAssertTrue(
            cell.contentView.subviews.allSatisfy {
                $0.frame.maxY <= cell.contentView.bounds.maxY + 1
            },
            "收起后直接子视图不应越过 contentView 边界"
        )
    }

    @MainActor
    func testCompletedPlainAnswerHidesActivityEntry() throws {
        var timeline = AppAgentActivityTimeline(
            startedAt: Date(timeIntervalSince1970: 100), roundCount: 1
        )
        timeline.finish(at: Date(timeIntervalSince1970: 102))
        let message = ChatMessage(role: .assistant, text: "答案", activity: timeline)
        let list = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        list.setMessages([message, ChatMessage(role: .user, text: "下一问")])
        list.updateVisibleArea(visibleHeight: 600, bottomInset: 0)
        list.layoutIfNeeded()
        let table = try XCTUnwrap(list.participantScrollView as? UITableView)
        let path = IndexPath(row: 0, section: 0)
        table.layoutIfNeeded()
        let cell = try XCTUnwrap(table.cellForRow(at: path) as? ChatMessageCell)
        let activityView = Self.descendant(AppAgentActivityView.self, in: cell)
        XCTAssertTrue(activityView?.isHidden == true)
        XCTAssertFalse(Self.hasVisibleLabel(in: cell, text: "本轮未记录思考或工具明细。"))
        XCTAssertFalse(Self.hasVisibleLabel(in: cell, text: "处理过程"))
    }

    @MainActor
    func testExpandedEmptyRunningActivityDisappearsWhenPlainAnswerFinishes() throws {
        let list = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        var running = AppAgentActivityTimeline()
        let message = ChatMessage(
            role: .assistant,
            text: "",
            status: .streaming,
            activity: running,
            isActivityExpanded: true
        )
        list.setMessages([message], forceScrollToBottom: false)
        list.updateVisibleArea(visibleHeight: 600, bottomInset: 0)
        list.layoutIfNeeded()

        let table = try XCTUnwrap(list.participantScrollView as? UITableView)
        let path = IndexPath(row: 0, section: 0)
        let cell = try XCTUnwrap(table.cellForRow(at: path) as? ChatMessageCell)
        let activityView = try XCTUnwrap(Self.descendant(AppAgentActivityView.self, in: cell))
        XCTAssertFalse(activityView.isHidden)

        running.finish()
        list.updateActivity(running, expanded: true, messageID: message.id)
        list.updateMessage(text: "最终答案", status: .complete, messageID: message.id)
        table.layoutIfNeeded()

        XCTAssertTrue(activityView.isHidden)
        XCTAssertEqual(cell.messageTextView.text, "最终答案")
        XCTAssertFalse(Self.hasVisibleLabel(in: cell, text: "本轮未记录思考或工具明细。"))
        XCTAssertFalse(Self.hasVisibleLabel(in: cell, text: "处理过程"))
    }

    @MainActor
    func testCellReuseHidesFinishedPlainAnswerActivityWithoutLeavingEmptyHeight() {
        var withActivity = AppAgentActivityTimeline()
        withActivity.appendThinking("真实过程")
        withActivity.finish()
        var plainAnswer = AppAgentActivityTimeline()
        plainAnswer.finish()
        var message = ChatMessage(
            role: .assistant,
            text: "答案",
            activity: withActivity,
            isActivityExpanded: true
        )
        let cell = ChatMessageCell(style: .default, reuseIdentifier: nil)
        cell.bounds = CGRect(x: 0, y: 0, width: 390, height: 600)
        cell.contentView.bounds = cell.bounds
        cell.configure(with: message)
        cell.layoutIfNeeded()
        let activityHeight = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        message.activity = plainAnswer
        message.isActivityExpanded = true
        cell.configure(with: message)
        cell.layoutIfNeeded()
        let plainHeight = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        let activityView = Self.descendant(AppAgentActivityView.self, in: cell)
        XCTAssertTrue(activityView?.isHidden == true)
        XCTAssertLessThan(plainHeight, activityHeight)
        XCTAssertEqual(cell.messageTextView.text, "答案")
        XCTAssertFalse(Self.hasVisibleLabel(in: cell, text: "处理过程"))
        XCTAssertFalse(Self.hasVisibleLabel(in: cell, text: "本轮未记录思考或工具明细。"))
    }

    func testEmptyFinishedTimelineDoesNotNeedActivityEntryButRunningOneDoes() {
        var finished = AppAgentActivityTimeline()
        finished.finish()
        XCTAssertFalse(finished.shouldDisplayActivity)

        let running = AppAgentActivityTimeline()
        XCTAssertTrue(running.shouldDisplayActivity)

        var withThinking = AppAgentActivityTimeline()
        withThinking.appendThinking("分析")
        withThinking.finish()
        XCTAssertTrue(withThinking.shouldDisplayActivity)
    }

    /// 过程区真实出布局：展开看全文，折叠看最新动作预览，成功只保留摘要。
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

        // 进行中 + 展开：正文只显示一次，不再重复摘要。
        let view = AppAgentActivityView()
        view.configure(with: timeline, expanded: true)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: "• 思考\n  └ 准备汇总结论"))

        // 结束后折叠：标题变成汇总，摘要仍作为一行提示保留。
        timeline.finish()
        view.configure(with: timeline, expanded: false)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: timeline.headerTitle()))
        XCTAssertFalse(timeline.isRunning)
    }

    /// 阶段：`furthestStage` 只增不减（一轮里工具往返会让 stage 在 streaming/tooling 来回）。
    func testFurthestStageOnlyMovesForward() {
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.preparing)
        XCTAssertEqual(timeline.furthestStage, .preparing)

        timeline.setStage(.tooling)
        XCTAssertEqual(timeline.furthestStage, .tooling)

        timeline.setStage(.streaming)
        XCTAssertEqual(timeline.stage, .streaming, "当前步可以回退")
        XCTAssertEqual(timeline.furthestStage, .tooling, "最远一步不回退")

        timeline.setStage(nil)
        XCTAssertNil(timeline.stage)
        XCTAssertEqual(timeline.furthestStage, .tooling, "清当前步不清最远一步")
    }

    /// 失败的一轮：`finish()` 不能把 stage 冲成 `.finished`，错误详情要留着。
    func testMarkFailedSurvivesFinish() {
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.requesting)
        timeline.markFailed(stage: .requesting, message: "No provider configured")
        timeline.finish()

        XCTAssertEqual(timeline.stage, .requesting)
        XCTAssertEqual(timeline.failedStage, .requesting)
        XCTAssertEqual(timeline.errorText, "No provider configured")
        XCTAssertTrue(timeline.headerTitle().hasPrefix("执行失败 · "), timeline.headerTitle())
        XCTAssertFalse(timeline.headerTitle().contains("耗时"))
        XCTAssertFalse(timeline.headerTitle().contains("轮"))

        var ok = AppAgentActivityTimeline()
        ok.setStage(.streaming)
        ok.finish()
        XCTAssertEqual(ok.stage, .finished, "没失败的轮次正常结束推到 finished")
        XCTAssertEqual(ok.furthestStage, .finished)
    }

    /// 指示条的图标映射对五个阶段都得给得出来（写错符号名 UIKit 只会静默给 nil 图）。
    func testStageStripIconNamesAreNonEmpty() {
        for stage in AIAgentRunStage.allCases {
            XCTAssertFalse(AppAgentRunStageStripView.iconName(for: stage).isEmpty, stage.rawValue)
            XCTAssertFalse(AppAgentRunStageStripView.title(for: stage).isEmpty, stage.rawValue)
        }
    }

    /// `.finished` 就是「本轮结束」：设完阶段这条时间线必须已收尾，
    /// 否则折叠行会一边显示「完成」一边转圈说「思考中…」。
    func testSettingFinishedStageAlsoFinishesTimeline() {
        var timeline = AppAgentActivityTimeline()
        XCTAssertTrue(timeline.isRunning)

        timeline.setStage(.finished)

        XCTAssertFalse(timeline.isRunning)
        XCTAssertFalse(timeline.headerTitle().contains("思考中"))
    }

    func testTranscriptUsesBulletAndIndentedOutputWithoutDestroyingFullText() {
        let item = AppAgentActivityItem(id: "1", kind: .tool, title: "file_read", state: .done)
        XCTAssertEqual(AppAgentActivityTranscript.heading(for: item), "• 已调用 file_read")
        let text = "第一行\n第二行\n第三行\n第四行\n" + String(repeating: "说明🙂", count: 300) + "错误尾部"
        let preview = AppAgentActivityTranscript.detail(text, expanded: false)
        XCTAssertFalse(preview.contains("第一行"))
        XCTAssertTrue(preview.contains("└ 第三行"))
        XCTAssertTrue(preview.contains("…"))
        let full = AppAgentActivityTranscript.detail(text, expanded: true)
        XCTAssertTrue(full.contains("└ 第一行"))
        XCTAssertTrue(full.hasSuffix("错误尾部"))
        XCTAssertGreaterThan(full.count, 600)
    }

    @MainActor
    func testStageStripHidesOnSuccessButRemainsForFailureEvenCollapsed() throws {
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.requesting)
        let view = AppAgentActivityView()
        view.configure(with: timeline, expanded: false)
        let strip = try XCTUnwrap(Self.descendant(AppAgentRunStageStripView.self, in: view))
        XCTAssertFalse(strip.isHidden)

        timeline.finish()
        view.configure(with: timeline, expanded: true)
        XCTAssertTrue(strip.isHidden, "成功展开时也不显示冗余流程图标")

        timeline.markFailed(stage: .requesting, message: "请求失败\nHTTP 503\n请稍后再试")
        view.configure(with: timeline, expanded: false)
        XCTAssertFalse(strip.isHidden)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: timeline.headerTitle()))
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: "请求"))
        XCTAssertFalse(Self.hasVisibleText(in: view, containing: "请求失败"))
        var toggled = false
        view.onToggle = { toggled = true }
        let root = try XCTUnwrap(strip.subviews.first as? UIStackView)
        XCTAssertEqual(root.arrangedSubviews.count, 9, "只有五个阶段和四条连线，末尾不追加警告")
        XCTAssertNil(Self.descendant(UIButton.self, in: strip))
        let failedCell = try XCTUnwrap(root.arrangedSubviews.compactMap { $0 as? UIControl }.first {
            $0.accessibilityIdentifier == "appagent.runStage.requesting"
        })
        XCTAssertTrue(failedCell.isEnabled)
        strip.frame = CGRect(x: 0, y: 0, width: 330, height: 18)
        strip.layoutIfNeeded()
        XCTAssertGreaterThan(failedCell.bounds.width, 14)
        XCTAssertGreaterThan(failedCell.bounds.height, 0)
        let center = failedCell.convert(
            CGPoint(x: failedCell.bounds.midX, y: failedCell.bounds.midY), to: strip
        )
        XCTAssertTrue(strip.hitTest(center, with: nil) === failedCell,
                      "图标和文字的点击应命中失败阶段控件")
        try invokeRegisteredAction(failedCell)
        XCTAssertTrue(toggled, "失败阶段格必须走列表的展开/高度重算回调")
        toggled = false
        let header = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first?
            .arrangedSubviews.compactMap { $0 as? UIControl }.first)
        try invokeRegisteredAction(header)
        XCTAssertTrue(toggled, "过程摘要仍可展开")
    }

    func testRecoveredToolFailureKeepsDiagnosticStageAndFullError() {
        var timeline = AppAgentActivityTimeline()
        let error = String(repeating: "详细失败原因\n", count: 100) + "原始错误尾部"
        timeline.startTool(id: "1", name: "web_fetch", argumentsPreview: "")
        timeline.failTool(id: "1", name: "web_fetch", message: error)
        timeline.finish()
        XCTAssertEqual(timeline.failedToolCount, 1)
        XCTAssertEqual(timeline.displayedFailedStage, .tooling)
        XCTAssertTrue(timeline.showsStageStrip)
        XCTAssertTrue(timeline.headerTitle().contains("1 次工具失败"))

        let view = AppAgentActivityView()
        view.configure(with: timeline, expanded: false)
        view.configure(with: timeline, expanded: true)
        XCTAssertTrue(Self.hasVisibleText(
            in: view,
            containing: AppAgentActivityTranscript.detail("失败：" + error, expanded: true)
        ))
    }

    @MainActor
    func testExpandedTranscriptUsesSelectableNonScrollingTextViews() throws {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("可复制的思考内容")
        timeline.startTool(id: "1", name: "file_read", argumentsPreview: "path=a.swift")
        timeline.finishTool(id: "1", resultPreview: "可复制的工具结果")

        let view = AppAgentActivityView()
        view.configure(with: timeline, expanded: true)
        let textView = try XCTUnwrap(Self.descendant(UITextView.self, in: view))

        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertTrue(Self.hasVisibleText(in: view, containing: "可复制的思考内容"))
        XCTAssertTrue(Self.hasVisibleText(in: view, containing: "可复制的工具结果"))
    }

    func testCollapseExpandAndReuseDoNotLoseTranscriptRows() {
        var timeline = AppAgentActivityTimeline()
        timeline.appendThinking("原来的思考")
        let view = AppAgentActivityView()
        view.configure(with: timeline, expanded: true)
        view.configure(with: timeline, expanded: false)
        timeline.appendThinking("，新增内容")
        view.configure(with: timeline, expanded: false)
        view.configure(with: timeline, expanded: true)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: "• 思考\n  └ 原来的思考，新增内容"))
        view.configure(with: AppAgentActivityTimeline(), expanded: true)
        view.configure(with: timeline, expanded: true)
        XCTAssertTrue(Self.hasVisibleLabel(in: view, text: "• 思考\n  └ 原来的思考，新增内容"))
    }

    private static func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private static func hasVisibleLabel(in root: UIView, text: String?) -> Bool {
        guard !root.isHidden, let text = text else { return false }
        if let label = root as? UILabel, label.isHidden == false, label.text == text { return true }
        if let textView = root as? UITextView, textView.isHidden == false, textView.text == text {
            return true
        }
        return root.subviews.contains { hasVisibleLabel(in: $0, text: text) }
    }

    private static func hasVisibleText(in root: UIView, containing text: String) -> Bool {
        guard !root.isHidden else { return false }
        if let label = root as? UILabel, !label.isHidden, label.text?.contains(text) == true {
            return true
        }
        if let textView = root as? UITextView, !textView.isHidden, textView.text.contains(text) {
            return true
        }
        return root.subviews.contains { hasVisibleText(in: $0, containing: text) }
    }
}
#endif
