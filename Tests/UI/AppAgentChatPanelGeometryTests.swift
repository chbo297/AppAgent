#if canImport(UIKit)
import XCTest
import BOUIKit
@testable import AppAgent

/// ChatPanel 业务几何与 BODragScroll 接线测试；运动物理由 BODragScroll 自身测试覆盖。
@MainActor
final class AppAgentChatPanelGeometryTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    private let safeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    private let inputBarExpandedFrame = CGRect(x: 12, y: 762, width: 369, height: 56)

    /// 生产默认走真实 session → agent → 模型（77ec512 起关闭了固定假回复）。
    func testViewControllerUsesRealSessionByDefault() {
        XCTAssertFalse(AppAgentViewController().usesFixedDebugReply)
    }

    /// 固定假回复只在宿主显式打开时生效（脱离模型联调 UI 用）。
    func testFixedDebugReplyIsAppendedImmediatelyWhenExplicitlyEnabled() {
        let viewController = AppAgentViewController()
        viewController.usesFixedDebugReply = true
        viewController.loadViewIfNeeded()

        viewController.dispatchOutgoingMessage(text: "测试消息")

        XCTAssertEqual(viewController.chatMessages.count, 2)
        XCTAssertEqual(viewController.chatMessages[0].role, .user)
        XCTAssertEqual(viewController.chatMessages[0].text, "测试消息")
        XCTAssertEqual(viewController.chatMessages[1].role, .assistant)
        XCTAssertEqual(viewController.chatMessages[1].text, "收到了")
        XCTAssertEqual(viewController.chatMessages[1].status, .complete)
    }


    func testRegularGeometryProducesExpectedPanelAndDetents() throws {
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertEqual(geometry.panelSize.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(
            geometry.maximumDisplayHeight,
            bounds.height - safeAreaInsets.top + AppAgentChatPanelGeometry.dragHandleAreaHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(geometry.panelSize.height, geometry.maximumDisplayHeight, accuracy: 0.5)
        XCTAssertEqual(
            bounds.height - geometry.maximumDisplayHeight
                + AppAgentChatPanelGeometry.dragHandleAreaHeight,
            safeAreaInsets.top,
            accuracy: 0.5
        )
        XCTAssertEqual(
            geometry.peekHeight,
            34 + AppAgentInputBar.barHeight + AppAgentChatPanelGeometry.dragHandleAreaHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(
            geometry.halfHeight,
            geometry.maximumDisplayHeight * 0.5
                + AppAgentChatPanelGeometry.dragHandleAreaHeight
                + AppAgentChatPanelNavigationBar.height,
            accuracy: 0.5
        )
        XCTAssertEqual(geometry.halfHeight, 486.5, accuracy: 0.001)
        XCTAssertEqual(
            bounds.height - geometry.peekHeight + AppAgentChatPanelGeometry.dragHandleAreaHeight,
            inputBarExpandedFrame.minY,
            accuracy: 0.5
        )
        XCTAssertEqual(
            geometry.detentHeights,
            [geometry.peekHeight, geometry.halfHeight, geometry.maximumDisplayHeight]
        )
    }

    func testPanelWidthNeverExceedsViewport() throws {
        let geometry = try XCTUnwrap(
            AppAgentChatPanelGeometry(
                bounds: bounds,
                safeAreaInsets: safeAreaInsets
            )
        )

        XCTAssertEqual(geometry.panelSize.width, bounds.width, accuracy: 0.5)
    }

    func testCompactHeightClampsAndDeduplicatesOverlappingDetents() throws {
        let geometry = try XCTUnwrap(
            AppAgentChatPanelGeometry(
                bounds: CGRect(x: 0, y: 0, width: 320, height: 100),
                safeAreaInsets: UIEdgeInsets(top: 20, left: 0, bottom: 34, right: 0)
            )
        )

        XCTAssertEqual(geometry.peekHeight, 100, accuracy: 0.5)
        XCTAssertEqual(geometry.halfHeight, 100, accuracy: 0.5)
        XCTAssertEqual(geometry.maximumDisplayHeight, 100, accuracy: 0.5)
        XCTAssertEqual(geometry.detentHeights, [100])
        XCTAssertEqual(
            geometry.nearestDetent(to: 100, preferredDetent: .half),
            .half
        )
        XCTAssertEqual(
            geometry.nearestDetent(to: 100, preferredDetent: .full),
            .full
        )
    }

    func testHalfHeightAddsTopAreasToPeekLimitedBaseHeight() throws {
        let geometry = try XCTUnwrap(
            AppAgentChatPanelGeometry(
                bounds: CGRect(x: 0, y: 0, width: 320, height: 200),
                safeAreaInsets: UIEdgeInsets(top: 20, left: 0, bottom: 34, right: 0)
            )
        )

        // 原 half 被 peek 托到 118，增加的是手柄区 28 + 标题栏 48。
        XCTAssertEqual(geometry.peekHeight, 118, accuracy: 0.001)
        XCTAssertEqual(geometry.halfHeight, 194, accuracy: 0.001)
        XCTAssertEqual(geometry.maximumDisplayHeight, 200, accuracy: 0.001)
        XCTAssertEqual(geometry.detentHeights, [118, 194, 200])
    }

    func testHalfHeightWithTopAreasClampsToFullAndDeduplicates() throws {
        let geometry = try XCTUnwrap(
            AppAgentChatPanelGeometry(
                bounds: CGRect(x: 0, y: 0, width: 320, height: 140),
                safeAreaInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
            )
        )

        XCTAssertEqual(geometry.peekHeight, 84, accuracy: 0.001)
        XCTAssertEqual(geometry.halfHeight, 140, accuracy: 0.001)
        XCTAssertEqual(geometry.maximumDisplayHeight, 140, accuracy: 0.001)
        XCTAssertEqual(geometry.detentHeights, [84, 140])
        XCTAssertEqual(geometry.nearestDetent(to: 140, preferredDetent: .half), .half)
    }

    func testNearestDetentAndClampingUseCurrentGeometry() throws {
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertEqual(geometry.nearestDetent(to: geometry.peekHeight + 2), .peek)
        XCTAssertEqual(geometry.nearestDetent(to: geometry.halfHeight + 2), .half)
        XCTAssertEqual(geometry.nearestDetent(to: geometry.maximumDisplayHeight - 2), .full)
        XCTAssertEqual(geometry.clampedDisplayHeight(-100), geometry.peekHeight)
        XCTAssertEqual(geometry.clampedDisplayHeight(10_000), geometry.maximumDisplayHeight)
    }

    func testListViewportFollowsVisibleDisplayHeight() {
        let listView = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )

        XCTAssertTrue(
            listView.updateVisibleArea(visibleHeight: 350, bottomInset: 100)
        )
        // 视口与展示区等高；被裁掉的面板高度不再折进 inset。
        XCTAssertEqual(listView.participantScrollView.bounds.height, 350, accuracy: 0.5)
        XCTAssertFalse(
            listView.updateVisibleArea(visibleHeight: 350, bottomInset: 100)
        )

        XCTAssertTrue(
            listView.updateVisibleArea(visibleHeight: 700, bottomInset: 100)
        )
        XCTAssertEqual(listView.participantScrollView.bounds.height, 700, accuracy: 0.5)
    }

    func testFirstLoadAlignsContentBottomEvenWithEstimatedRowHeights() throws {
        let listView = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )
        // 长短不一的消息：自动行高下首屏 contentSize 只是按 estimatedRowHeight 估的，
        // 只对齐一趟会停在离底几百 pt 的位置（启动时看到的就是这个）。
        listView.setMessages(
            // 尾行用用户消息，验证无 assistant 占位空白时仍对齐真实底部。
            (0..<41).map { index in
                ChatMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: String(repeating: "内容 \(index) ", count: index % 7 + 1)
                )
            }
        )
        listView.updateVisibleArea(visibleHeight: 480, bottomInset: 90)
        listView.layoutIfNeeded()

        let tableView = listView.participantScrollView
        tableView.layoutIfNeeded()
        try XCTSkipIf(
            tableView.contentSize.height < 1_200,
            "行高未展开，本用例依赖 tableView 已算出内容高度"
        )
        XCTAssertEqual(
            tableView.contentOffset.y,
            tableView.bo_maximumContentOffsetY,
            accuracy: 0.5,
            "首屏必须对齐到内容底部"
        )
    }

    func testContentHeightEqualsSumOfSelfMeasuredRowHeights() throws {
        let listView = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )
        let messages = (0..<25).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: String(repeating: "长度不一的内容 \(index) ", count: index % 5 + 1)
            )
        }
        listView.setMessages(messages)
        listView.updateVisibleArea(visibleHeight: 480, bottomInset: 90)
        listView.layoutIfNeeded()

        let tableView = listView.participantScrollView
        tableView.layoutIfNeeded()
        try XCTSkipIf(
            tableView.contentSize.height < 400,
            "行高未展开，本用例依赖 tableView 已算出内容高度"
        )

        // 关掉估算之后 contentSize 必须等于逐行精确高度之和；有估算参与就会对不上。
        let table = try XCTUnwrap(tableView as? UITableView)
        let delegate = try XCTUnwrap(table.delegate)
        let summedHeight = (0..<messages.count).reduce(into: CGFloat(0)) { total, row in
            total += delegate.tableView?(table, heightForRowAt: IndexPath(row: row, section: 0)) ?? 0
        }
        XCTAssertEqual(table.contentSize.height, summedHeight, accuracy: 0.5)
    }

    func testLatestReplyStartsAt400GrowsBy70AndKeepsHeightWhenDone() throws {
        let listView = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )
        let step = AppAgentChatMessageListView.latestReplyHeightStep
        var streaming = ChatMessage(role: .assistant, text: "开始", status: .streaming)
        installLegacy400LatestReplyFixture(on: listView)
        listView.setMessages([ChatMessage(role: .user, text: "问题"), streaming])
        listView.updateVisibleArea(visibleHeight: 480, bottomInset: 90)
        listView.layoutIfNeeded()

        let table = try XCTUnwrap(listView.participantScrollView as? UITableView)
        let delegate = try XCTUnwrap(table.delegate)
        let tailIndexPath = IndexPath(row: 1, section: 0)
        func tailHeight() -> CGFloat {
            delegate.tableView?(table, heightForRowAt: tailIndexPath) ?? 0
        }

        // 基准是 400，不是向上取整到 70 的倍数（420）。
        let shortHeight = tailHeight()
        XCTAssertEqual(shortHeight, 400)

        // 同一个台阶里继续吐字：行高不变（宿主据此跳过 reloadRows）。
        streaming.text = "开始，再多两个字"
        listView.updateMessage(text: streaming.text, status: .streaming, messageID: listView.messages[1].id)
        XCTAssertEqual(tailHeight(), shortHeight, accuracy: 0.5)

        // 文本长到跨过台阶：行高抬一格以上，且仍是台阶整数倍。
        let longText = String(repeating: "很长的流式内容，用来把回复撑过一个台阶。\n\n", count: 30)
        listView.updateMessage(text: longText, status: .streaming, messageID: listView.messages[1].id)
        let grownHeight = tailHeight()
        XCTAssertGreaterThan(grownHeight, shortHeight)
        XCTAssertEqual((grownHeight - 400).truncatingRemainder(dividingBy: step), 0, accuracy: 0.5)
        let precise = ChatMessageHeightCache().height(for: listView.messages[1], width: table.bounds.width)
        XCTAssertGreaterThanOrEqual(grownHeight, precise)
        XCTAssertLessThan(grownHeight - precise, step)

        // 成功、失败及内容缩短均不能让最新回复缩高。
        listView.updateMessage(text: longText, status: .complete, messageID: listView.messages[1].id)
        XCTAssertEqual(tailHeight(), grownHeight)
        listView.updateMessage(text: "失败", status: .error, messageID: listView.messages[1].id)
        XCTAssertEqual(tailHeight(), grownHeight)
        listView.append(ChatMessage(role: .user, text: "下一问"), followLatest: false)
        XCTAssertEqual(tailHeight(), ChatMessageHeightCache().height(
            for: listView.messages[1], width: table.bounds.width
        ))
        XCTAssertLessThan(tailHeight(), 400)
        listView.append(ChatMessage(role: .assistant, text: "", status: .streaming), followLatest: false)
        XCTAssertEqual(delegate.tableView?(table, heightForRowAt: IndexPath(row: 3, section: 0)), 400)
    }

    func testStreamingActivityUsesSameHeightStepsAndKeepsVisibleCellWithinStep() throws {
        let list = AppAgentChatMessageListView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        var timeline = AppAgentActivityTimeline()
        timeline.setStage(.streaming)
        timeline.appendThinking("分析")
        let message = ChatMessage(role: .assistant, text: "", status: .streaming,
                                  activity: timeline, isActivityExpanded: true)
        installLegacy400LatestReplyFixture(on: list)
        list.setMessages([message])
        list.layoutIfNeeded()
        let table = try XCTUnwrap(list.participantScrollView as? UITableView)
        table.layoutIfNeeded()
        let path = IndexPath(row: 0, section: 0)
        let delegate = try XCTUnwrap(table.delegate)
        func height() -> CGFloat { delegate.tableView?(table, heightForRowAt: path) ?? 0 }
        let initialHeight = height()
        let cell = table.cellForRow(at: path)
        let size = table.contentSize
        let offset = table.contentOffset
        timeline.appendThinking("中")
        list.updateActivity(timeline, messageID: message.id)
        XCTAssertEqual(height(), initialHeight)
        XCTAssertEqual(table.contentSize, size)
        XCTAssertEqual(table.contentOffset, offset)
        if let cell {
            XCTAssertTrue(table.cellForRow(at: path) === cell, "同台阶只重配原 cell，不 reloadRows")
        }

        timeline.appendThinking(String(repeating: "\n继续分析新的细节", count: 15))
        list.updateActivity(timeline, messageID: message.id)
        let grown = height()
        XCTAssertEqual(initialHeight, 400)
        XCTAssertEqual(grown, initialHeight, "过程区超高后内部滚动，不撑高整行")
        timeline.finish()
        list.updateActivity(timeline, expanded: false, messageID: message.id)
        list.updateMessage(text: "处理完成", status: .complete, messageID: message.id)
        let precise = ChatMessageHeightCache().height(for: list.messages[0], width: table.bounds.width)
        XCTAssertEqual(height(), grown)
        XCTAssertGreaterThan(height(), precise)
    }

    func testViewportHeightChangeNeverRewritesContentOffset() throws {
        let listView = AppAgentChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )
        listView.setMessages((0..<40).map { ChatMessage(role: .user, text: "消息 \($0)") })
        listView.updateVisibleArea(visibleHeight: 700, bottomInset: 90)
        listView.layoutIfNeeded()
        let tableView = listView.participantScrollView
        tableView.layoutIfNeeded()
        try XCTSkipIf(
            tableView.contentSize.height < 1_200,
            "行高未展开，本用例依赖 tableView 已算出内容高度"
        )

        // 停在中间（不贴底），排除「贴底跟随」这一路的写入。
        tableView.contentOffset.y = 300

        // 写权在宿主：只改视口高度，不做任何 offset 校正。
        listView.updateVisibleArea(visibleHeight: 500, bottomInset: 90)

        XCTAssertEqual(tableView.bounds.height, 500, accuracy: 0.5)
        XCTAssertEqual(tableView.contentOffset.y, 300, accuracy: 0.5)

        // 再变一次高度同样一个字节都不写：组合轴自己已经把面板位移折进内部 offset。
        listView.updateVisibleArea(visibleHeight: 380, bottomInset: 90)

        XCTAssertEqual(tableView.bounds.height, 380, accuracy: 0.5)
        XCTAssertEqual(tableView.contentOffset.y, 300, accuracy: 0.5)
    }

    func testKeyboardLiftDoesNotChangePanelGeometry() throws {
        let coordinator = AppAgentChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
        coordinator.move(to: .full, animated: false)
        let restingGeometry = try XCTUnwrap(makeGeometry())
        let restingDisplayHeight = coordinator.dragScrollView.displayHeight

        // 键盘顶起：宿主只把整个容器上移（inputBar 展开态跟着上移），面板几何与展示高度都不参与。
        let liftedInputBarFrame = inputBarExpandedFrame.offsetBy(dx: 0, dy: -320)
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )

        XCTAssertEqual(
            coordinator.panelView.bounds.height,
            restingGeometry.panelSize.height,
            accuracy: 0.5
        )
        XCTAssertEqual(
            coordinator.dragScrollView.displayHeight,
            restingDisplayHeight,
            accuracy: 0.5
        )
    }

    func testCoordinatorInstallsFixedPanelAndStartsAtHalfDetent() throws {
        let coordinator = AppAgentChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertTrue(coordinator.dragScrollView.panelView === coordinator.panelView)
        XCTAssertFalse(coordinator.dragScrollView.clipsToBounds)
        // 内部优先：手指落在列表里就由列表自己滚，面板不参与联动，列表 offset 永远归宿主；
        // 上下橡皮筋都归内部列表，卡片自身不外拉。
        XCTAssertEqual(coordinator.dragScrollView.configuration.handoff.mode, .innerFirst)
        XCTAssertFalse(coordinator.dragScrollView.configuration.bounce.allowsPanelTopBounce)
        XCTAssertFalse(coordinator.dragScrollView.configuration.bounce.allowsPanelBottomBounce)
        XCTAssertEqual(coordinator.dragScrollView.configuration.bounce.preferredTopOwner, .innerScrollView)
        XCTAssertEqual(coordinator.dragScrollView.configuration.bounce.preferredBottomOwner, .innerScrollView)
        // 滑动列表与拖动面板都不联动收键盘。
        XCTAssertEqual(coordinator.panelView.listView.participantScrollView.keyboardDismissMode, .none)
        XCTAssertEqual(coordinator.dragScrollView.keyboardDismissMode, .none)
        XCTAssertEqual(coordinator.dragScrollView.minimumDisplayHeight ?? -1, geometry.peekHeight, accuracy: 0.5)
        XCTAssertEqual(coordinator.dragScrollView.detentHeights, geometry.detentHeights)
        XCTAssertEqual(coordinator.panelView.bounds.size.width, geometry.panelSize.width, accuracy: 0.5)
        XCTAssertEqual(coordinator.panelView.bounds.size.height, geometry.panelSize.height, accuracy: 0.5)
        XCTAssertEqual(coordinator.dragScrollView.displayHeight, geometry.halfHeight, accuracy: 0.5)
        XCTAssertEqual(coordinator.dragScrollView.displayHeight, 486.5, accuracy: 0.5)
        // 底部 inset 固定等于展开态 inputBar 白色背景顶部到屏幕底部的高度。
        XCTAssertEqual(
            geometry.listBottomInset,
            bounds.maxY - inputBarExpandedFrame.minY,
            accuracy: 0.5
        )
        // 列表视口高度 = 当前展示高度减去拖拽手柄区与导航栏。
        // 新 half 补足两块顶部区域后，列表视口达到原半屏高度 410.5。
        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.bounds.height,
            410.5,
            accuracy: 0.5
        )
        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.bounds.height,
            geometry.halfHeight
                - AppAgentChatPanelGeometry.dragHandleAreaHeight
                - AppAgentChatPanelNavigationBar.height,
            accuracy: 0.5
        )
    }

    func testCoordinatorProgrammaticMoveUsesBusinessDetent() async throws {
        let coordinator = AppAgentChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
        let geometry = try XCTUnwrap(makeGeometry())
        let halfDetentBottomInset = coordinator.panelView.listView.participantScrollView.contentInset.bottom

        coordinator.move(to: .peek, animated: false)
        await Task.yield()

        XCTAssertEqual(coordinator.dragScrollView.displayHeight, geometry.peekHeight, accuracy: 0.5)
        XCTAssertEqual(coordinator.panelView.viewportView.frame, CGRect(x: 12, y: 0, width: 369, height: 56))
        // 档位变化不动底部 inset。
        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.contentInset.bottom,
            halfDetentBottomInset,
            accuracy: 0.5
        )
        // 视口下限是 half 档可视高度：收到 peek 也不再继续压缩 tableView。
        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.bounds.height,
            geometry.halfHeight
                - AppAgentChatPanelGeometry.dragHandleAreaHeight
                - AppAgentChatPanelNavigationBar.height,
            accuracy: 0.5
        )
    }

    func testCoordinatorUpdatesMetricsWithoutWaitingForIdleAfterTransactionlessDrag() async throws {
        let coordinator = AppAgentChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
        let geometry = try XCTUnwrap(makeGeometry())
        // iOS 下挂到 window 可让 tableView 完成正常布局；Catalyst 的 package test 尚未创建
        // NSApplication，此时提前构造 UIWindow 会触发 UIKit 的一致性异常，且本测试不依赖 window。
        var testWindow: UIWindow?
#if !targetEnvironment(macCatalyst)
        let window = UIWindow(frame: bounds)
        window.addSubview(coordinator.dragScrollView)
        window.isHidden = false
        testWindow = window
#endif
        defer { testWindow?.isHidden = true }
        let fixedBottomInset = geometry.listBottomInset
        let fixedTopAreaHeight = AppAgentChatPanelGeometry.dragHandleAreaHeight
            + AppAgentChatPanelNavigationBar.height

        coordinator.dragScrollView.scrollViewWillBeginDragging(coordinator.dragScrollView)
        let updatedBounds = CGRect(x: 0, y: 0, width: 393, height: 900)
        let updatedInputBarFrame = CGRect(x: 12, y: 810, width: 369, height: 56)
        let updatedGeometry = try XCTUnwrap(
            AppAgentChatPanelGeometry(
                bounds: updatedBounds,
                safeAreaInsets: safeAreaInsets
            )
        )
        coordinator.updateLayout(
            bounds: updatedBounds,
            safeAreaInsets: safeAreaInsets
        )
        let expectedVisibleHeight = max(
            coordinator.dragScrollView.displayHeight,
            updatedGeometry.halfHeight
        ) - fixedTopAreaHeight

        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.bounds.height,
            expectedVisibleHeight,
            accuracy: 0.5
        )
        // 安全区与 bar 高度没变，底部 inset 也就不变：它不参与面板/布局变化。
        XCTAssertEqual(updatedGeometry.listBottomInset, fixedBottomInset, accuracy: 0.5)

        coordinator.dragScrollView.scrollViewDidEndDragging(
            coordinator.dragScrollView,
            willDecelerate: false
        )
        let nextMainTurn = expectation(description: "no delayed idle settlement is required")
        DispatchQueue.main.async { nextMainTurn.fulfill() }
        await fulfillment(of: [nextMainTurn], timeout: 1)

        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.bounds.height,
            expectedVisibleHeight,
            accuracy: 0.5
        )
    }

    func testCoordinatorPreservesMoveRequestedBeforeFirstLayout() throws {
        let coordinator = AppAgentChatPanelCoordinator()
        coordinator.move(to: .full, animated: false)
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertEqual(
            coordinator.dragScrollView.displayHeight,
            geometry.maximumDisplayHeight,
            accuracy: 0.5
        )
    }

    func testCoordinatorGeometryChangePreservesLiveHeightInsteadOfSnappingToDetent() throws {
        let coordinator = AppAgentChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
        let initialGeometry = try XCTUnwrap(makeGeometry())
        let liveHeight = initialGeometry.halfHeight + 37
        coordinator.dragScrollView.scroll(toDisplayHeight: liveHeight, animated: false)
        XCTAssertEqual(coordinator.dragScrollView.displayHeight, liveHeight, accuracy: 0.5)

        let updatedBounds = CGRect(x: 0, y: 0, width: 393, height: 900)
        let updatedInputBarFrame = CGRect(x: 12, y: 810, width: 369, height: 56)
        let updatedGeometry = try XCTUnwrap(
            AppAgentChatPanelGeometry(
                bounds: updatedBounds,
                safeAreaInsets: safeAreaInsets
            )
        )
        coordinator.updateLayout(
            bounds: updatedBounds,
            safeAreaInsets: safeAreaInsets
        )

        XCTAssertEqual(
            coordinator.dragScrollView.displayHeight,
            updatedGeometry.clampedDisplayHeight(liveHeight),
            accuracy: 0.5
        )
        XCTAssertNotEqual(
            coordinator.dragScrollView.displayHeight,
            updatedGeometry.height(
                for: updatedGeometry.nearestDetent(to: liveHeight)
            ),
            accuracy: 0.5
        )
    }

    func testChatPanelContainerLayoutExpandedShowsEntireContainer() {
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: inputBarExpandedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(AppAgentChatPanelContainerLayout.horizontalOutset, 12, accuracy: 0.5)
        XCTAssertEqual(layout.containerFrame, bounds)
        XCTAssertEqual(layout.dragScrollFrame, bounds)
        XCTAssertEqual(
            inputBarExpandedFrame.width + AppAgentChatPanelContainerLayout.horizontalOutset * 2,
            layout.containerFrame.width,
            accuracy: 0.5
        )
        XCTAssertEqual(layout.panelAlpha, 1, accuracy: 0.001)
    }

    /// 画布 frame 的 writer 只能有一个：容器。
    ///
    /// coordinator 曾经也写一次（`origin: .zero`），只在「满宽 inputBar」时与容器目标值恰好相等；
    /// 横屏（左安全区）/ iPad 居中 / 拖窄过 inputBar 时两者相差 47~200pt，于是容器侧判等永远失败
    /// —— 每次布局都停掉在飞的动画，并给 scrollView 多夹一次承载展示高度的 contentOffset。
    func testCoordinatorDoesNotWriteDragScrollFrame() {
        let coordinator = AppAgentChatPanelCoordinator()
        let sentinel = CGRect(x: -123, y: -45, width: 320, height: 640)
        coordinator.dragScrollView.frame = sentinel

        coordinator.updateLayout(bounds: bounds, safeAreaInsets: safeAreaInsets)

        XCTAssertEqual(coordinator.dragScrollView.frame, sentinel)
    }

    /// 展开态 inputBar 不贴着左边时画布必须横向反向偏移，且容器写入的就是 layout 算出的值。
    func testContainerIsTheOnlyWriterOfOffsetDragScrollFrame() {
        let narrowedExpandedFrame = CGRect(
            x: 112,
            y: inputBarExpandedFrame.minY,
            width: 169,
            height: inputBarExpandedFrame.height
        )
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: narrowedExpandedFrame,
            inputBarExpandedFrame: narrowedExpandedFrame
        )
        XCTAssertEqual(
            layout.dragScrollFrame.minX,
            AppAgentChatPanelContainerLayout.horizontalOutset - narrowedExpandedFrame.minX,
            accuracy: 0.5
        )
        // 这种形态下画布目标不可能是 origin .zero —— 正是两个 writer 会打架的地方。
        XCTAssertNotEqual(layout.dragScrollFrame.minX, 0, accuracy: 0.5)

        let container = AppAgentChatPanelContainerView()
        let canvas = UIView()
        container.installContentView(canvas)
        container.apply(layout, animation: .immediate)

        XCTAssertEqual(canvas.frame, layout.dragScrollFrame)

        // 同一份 layout 再提交一次不该改动几何，也不该留下动画（容器侧判等生效）。
        container.apply(layout, animation: .immediate)
        XCTAssertEqual(canvas.frame, layout.dragScrollFrame)
        XCTAssertNil(container.layer.animationKeys())
    }

    /// inputBar 几何尚未就绪时画布仍要拿到正确尺寸：容器是唯一 writer，得自己兜住这一段。
    func testContainerLayoutKeepsCanvasSizeBeforeInputBarGeometryIsReady() {
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: .zero,
            inputBarExpandedFrame: .zero
        )

        XCTAssertEqual(layout.containerFrame, .zero)
        XCTAssertEqual(layout.panelAlpha, 0, accuracy: 0.001)
        XCTAssertEqual(layout.dragScrollFrame, CGRect(origin: .zero, size: bounds.size))
    }

    func testViewControllerMovesEntireChatPanelContainerWithKeyboardLiftedInputBar() {
        let viewController = AppAgentViewController()
        viewController.loadViewIfNeeded()
        viewController.view.frame = bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()

        let restingFrame = AppAgentInputBarFramePolicy.preferredExpandedFrame(
            viewController.inputBarLayoutContext
        )
        let keyboardLift: CGFloat = 240
        let liftedFrame = restingFrame.offsetBy(dx: 0, dy: -keyboardLift)

        viewController.applyChatPanelContainerLayout(
            inputBarFrame: liftedFrame,
            inputBarExpandedFrame: liftedFrame,
            animation: .immediate
        )

        XCTAssertEqual(
            viewController.chatPanelContainer.frame.minY,
            viewController.view.bounds.minY - keyboardLift,
            accuracy: 0.5
        )
        XCTAssertEqual(
            viewController.chatPanelCoordinator.dragScrollView.frame.minY,
            0,
            accuracy: 0.5
        )
    }

    func testChatPanelContainerLayoutCollapsedKeepsTwelvePointOutsetAndFullHeight() {
        let collapsedFrame = CGRect(
            x: bounds.maxX - AppAgentInputBar.collapsedMinWidth - 12,
            y: 620,
            width: AppAgentInputBar.collapsedMinWidth,
            height: AppAgentInputBar.barHeight
        )
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: collapsedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(
            layout.containerFrame,
            CGRect(
                x: collapsedFrame.minX - AppAgentChatPanelContainerLayout.horizontalOutset,
                y: 0,
                width: collapsedFrame.width + AppAgentChatPanelContainerLayout.horizontalOutset * 2,
                height: bounds.height
            )
        )
        XCTAssertEqual(
            layout.dragScrollFrame,
            CGRect(origin: .zero, size: bounds.size)
        )
        XCTAssertEqual(layout.panelAlpha, 0, accuracy: 0.001)
    }

    func testChatPanelContainerLayoutFollowsIntermediateInputBarFrameExactly() {
        let intermediateWidth = (inputBarExpandedFrame.width + AppAgentInputBar.collapsedMinWidth) / 2
        let intermediateFrame = CGRect(
            x: inputBarExpandedFrame.maxX - intermediateWidth,
            y: inputBarExpandedFrame.minY,
            width: intermediateWidth,
            height: inputBarExpandedFrame.height
        )
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: intermediateFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(
            intermediateFrame.minX - layout.containerFrame.minX,
            AppAgentChatPanelContainerLayout.horizontalOutset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            layout.containerFrame.width,
            intermediateFrame.width + AppAgentChatPanelContainerLayout.horizontalOutset * 2,
            accuracy: 0.5
        )
        XCTAssertEqual(layout.panelAlpha, 0.0625, accuracy: 0.001)
    }

    func testChatPanelAlphaUsesEaseOutDuringInteractiveCollapse() {
        let collapseTravel = inputBarExpandedFrame.width - AppAgentInputBar.collapsedMinWidth
        let quarterCollapsedFrame = CGRect(
            x: inputBarExpandedFrame.minX + collapseTravel * 0.25,
            y: inputBarExpandedFrame.minY,
            width: inputBarExpandedFrame.width - collapseTravel * 0.25,
            height: inputBarExpandedFrame.height
        )
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: quarterCollapsedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(layout.panelAlpha, 0.31640625, accuracy: 0.001)
    }

    func testWideChatPanelCanvasKeepsExpandedAlignmentWhileContainerFollowsInputBar() {
        let wideBounds = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        let wideExpandedFrame = CGRect(x: 212, y: 678, width: 600, height: 56)
        let currentFrame = CGRect(x: 512, y: 678, width: 300, height: 56)
        let layout = AppAgentChatPanelContainerLayout(
            bounds: wideBounds,
            inputBarFrame: currentFrame,
            inputBarExpandedFrame: wideExpandedFrame
        )

        XCTAssertEqual(layout.containerFrame, CGRect(x: 500, y: 0, width: 324, height: 768))
        XCTAssertEqual(layout.dragScrollFrame, CGRect(x: -200, y: 0, width: 1_024, height: 768))
    }

    func testChatPanelContainerHasNoOuterMaskAndCollapsedStateIsInactive() {
        let collapsedFrame = CGRect(
            x: bounds.maxX - AppAgentInputBar.collapsedMinWidth - 12,
            y: 620,
            width: AppAgentInputBar.collapsedMinWidth,
            height: AppAgentInputBar.barHeight
        )
        let layout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: collapsedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )
        let container = AppAgentChatPanelContainerView()
        let contentView = UIView()

        container.installContentView(contentView)
        container.apply(layout, animation: .immediate)

        XCTAssertNil(container.layer.mask)
        XCTAssertEqual(container.alpha, 0, accuracy: 0.001)
        XCTAssertFalse(container.isUserInteractionEnabled)
        XCTAssertTrue(container.accessibilityElementsHidden)
    }

    func testViewControllerInstallsDragScrollViewInsideChatPanelContainer() {
        let viewController = AppAgentViewController()
        viewController.loadViewIfNeeded()

        XCTAssertTrue(viewController.chatPanelCoordinator.dragScrollView.superview === viewController.chatPanelContainer)
        XCTAssertTrue(viewController.chatPanelContainer.superview === viewController.view)

        let containerIndex = viewController.view.subviews.firstIndex { $0 === viewController.chatPanelContainer }
        let inputBarIndex = viewController.view.subviews.firstIndex { $0 === viewController.inputBar }
        XCTAssertNotNil(containerIndex)
        XCTAssertNotNil(inputBarIndex)
        XCTAssertLessThan(containerIndex ?? 0, inputBarIndex ?? 0)
    }

    func testExpandedResizePanUpdatesContainerAndAlphaImmediately() {
        let viewController = AppAgentViewController()
        viewController.loadViewIfNeeded()
        viewController.view.frame = bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()

        let startFrame = viewController.inputBar.frame
        let proposedFrame = CGRect(
            x: startFrame.minX + 80,
            y: startFrame.minY,
            width: startFrame.width - 80,
            height: startFrame.height
        )
        viewController.inputBar(
            viewController.inputBar,
            wantsFrame: proposedFrame,
            panKind: .expandedResize
        )

        let appliedInputBarFrame = viewController.inputBar.frame
        XCTAssertFalse(appliedInputBarFrame.isApproximatelyEqual(to: startFrame))
        XCTAssertEqual(
            viewController.chatPanelContainer.frame.minX,
            appliedInputBarFrame.minX - AppAgentChatPanelContainerLayout.horizontalOutset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            viewController.chatPanelContainer.frame.width,
            appliedInputBarFrame.width + AppAgentChatPanelContainerLayout.horizontalOutset * 2,
            accuracy: 0.5
        )
        let expectedLayout = AppAgentChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: appliedInputBarFrame,
            inputBarExpandedFrame: startFrame
        )
        XCTAssertEqual(viewController.chatPanelContainer.alpha, expectedLayout.panelAlpha, accuracy: 0.001)
        XCTAssertNil(viewController.chatPanelContainer.layer.mask)
        XCTAssertNil(viewController.chatPanelContainer.layer.animationKeys())
    }

    func testContentLayoutAtTransitionStartUsesVisibleHeightAndFullContentCoordinates() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + AppAgentInputBar.barHeight
            + AppAgentChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = AppAgentChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: halfHeight,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: halfHeight
        )

        XCTAssertEqual(layout.dragHandleAreaFrame, CGRect(x: 0, y: 0, width: 393, height: 28))
        XCTAssertEqual(layout.grabberFrame.midY, layout.dragHandleAreaFrame.midY, accuracy: 0.001)
        XCTAssertEqual(layout.contentAreaFrame, CGRect(x: 0, y: 28, width: 393, height: 765))
        XCTAssertEqual(layout.backgroundFrame, CGRect(x: 0, y: 0, width: 393, height: 368.5))
        XCTAssertEqual(layout.viewportFrame, layout.backgroundFrame)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.navigationBarFrame, CGRect(x: 0, y: 0, width: 393, height: 48))
        XCTAssertEqual(layout.messageListFrame, CGRect(x: 0, y: 48, width: 393, height: 717))
        XCTAssertEqual(layout.topCornerRadius, 20, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, 20, accuracy: 0.001)
        XCTAssertEqual(layout.compactProgress, 0, accuracy: 0.001)
    }

    func testContentLayoutAboveTransitionTracksDisplayHeightNotPanelHeight() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + AppAgentInputBar.barHeight
            + AppAgentChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = AppAgentChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: halfHeight + 1,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: halfHeight
        )

        // 面板高度恒定，可见区只由展示高度决定：viewport = displayHeight - 拖拽手柄区。
        XCTAssertEqual(layout.backgroundFrame, CGRect(x: 0, y: 0, width: 393, height: 369.5))
        XCTAssertEqual(layout.viewportFrame, layout.backgroundFrame)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.navigationBarFrame, CGRect(x: 0, y: 0, width: 393, height: 48))
        XCTAssertEqual(layout.messageListFrame, CGRect(x: 0, y: 48, width: 393, height: 717))
        XCTAssertEqual(layout.topCornerRadius, 20, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, 0, accuracy: 0.001)
        XCTAssertEqual(layout.compactProgress, 0, accuracy: 0.001)
    }

    func testContentLayoutAtPanelHeightUsesEntireContentArea() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + AppAgentInputBar.barHeight
            + AppAgentChatPanelGeometry.dragHandleAreaHeight
        let layout = AppAgentChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: panelBounds.height,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: panelBounds.height * 0.5
        )

        XCTAssertEqual(layout.backgroundFrame, CGRect(x: 0, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.viewportFrame, layout.backgroundFrame)
    }

    func testContentLayoutAtPeekMatchesInputBarAndDoesNotResizeActualContent() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + AppAgentInputBar.barHeight
            + AppAgentChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = AppAgentChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: minimumHeight,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: halfHeight
        )

        let compactFrame = CGRect(x: 12, y: 0, width: 369, height: 56)
        XCTAssertEqual(layout.backgroundFrame, compactFrame)
        XCTAssertEqual(layout.viewportFrame, compactFrame)
        XCTAssertEqual(layout.contentFrame, CGRect(x: -12, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.navigationBarFrame, CGRect(x: -12, y: 0, width: 393, height: 48))
        XCTAssertEqual(layout.messageListFrame, CGRect(x: -12, y: 48, width: 393, height: 717))
        XCTAssertEqual(layout.topCornerRadius, AppAgentInputBar.expandedCornerRadius, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, AppAgentInputBar.expandedCornerRadius, accuracy: 0.001)
        XCTAssertEqual(layout.compactProgress, 1, accuracy: 0.001)
    }

    func testContentLayoutInterpolatesBetweenHalfAndPeek() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + AppAgentInputBar.barHeight
            + AppAgentChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = AppAgentChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: (minimumHeight + halfHeight) * 0.5,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: halfHeight
        )

        XCTAssertEqual(layout.compactProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(layout.backgroundFrame, CGRect(x: 6, y: 0, width: 381, height: 212.25))
        XCTAssertEqual(layout.viewportFrame, layout.backgroundFrame)
        XCTAssertEqual(layout.contentFrame, CGRect(x: -6, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.navigationBarFrame, CGRect(x: -6, y: 0, width: 393, height: 48))
        XCTAssertEqual(layout.messageListFrame, CGRect(x: -6, y: 48, width: 393, height: 717))
        XCTAssertEqual(layout.topCornerRadius, 18, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, 18, accuracy: 0.001)
    }

    func testContentLayoutHandlesCoincidentHalfAndPeekHeights() {
        let panelBounds = CGRect(x: 0, y: 0, width: 320, height: 80)
        let layout = AppAgentChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: 80,
            minimumDisplayHeight: 80,
            compactTransitionStartDisplayHeight: 80
        )

        XCTAssertEqual(layout.compactProgress, 1, accuracy: 0.001)
        XCTAssertEqual(layout.backgroundFrame, CGRect(x: 12, y: 0, width: 296, height: 52))
        XCTAssertEqual(layout.viewportFrame, layout.backgroundFrame)
        XCTAssertEqual(layout.contentFrame, CGRect(x: -12, y: 0, width: 320, height: 52))
        XCTAssertEqual(layout.navigationBarFrame, CGRect(x: -12, y: 0, width: 320, height: 48))
        XCTAssertEqual(layout.messageListFrame, CGRect(x: -12, y: 48, width: 320, height: 4))
    }

    func testPanelViewInstallsContentInsideClippedViewport() {
        let panelView = AppAgentChatPanelView(frame: CGRect(x: 0, y: 0, width: 393, height: 793))
        let minimumHeight = safeAreaInsets.bottom
            + AppAgentInputBar.barHeight
            + AppAgentChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelView.bounds.height * 0.5

        panelView.updateDisplayHeight(
            minimumHeight,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: halfHeight
        )

        XCTAssertTrue(panelView.dragHandleAreaView.superview === panelView)
        XCTAssertEqual(panelView.dragHandleAreaView.layer.borderWidth, 0, accuracy: 0.001)
        XCTAssertTrue(panelView.contentAreaView.superview === panelView)
        XCTAssertTrue(panelView.viewportView.superview === panelView.contentAreaView)
        XCTAssertTrue(panelView.navigationBar.superview === panelView.viewportView)
        XCTAssertTrue(panelView.listView.superview === panelView.viewportView)
        // 裁切靠 clipsToBounds + cornerRadius，不再挂 shape mask（mask 不吃 UIKit 动画块）。
        XCTAssertNil(panelView.viewportView.layer.mask)
        XCTAssertTrue(panelView.viewportView.clipsToBounds)
        XCTAssertEqual(
            panelView.viewportView.layer.cornerRadius,
            AppAgentInputBar.expandedCornerRadius,
            accuracy: 0.001
        )
        XCTAssertEqual(panelView.viewportView.frame, CGRect(x: 12, y: 0, width: 369, height: 56))
        XCTAssertEqual(panelView.navigationBar.frame, CGRect(x: -12, y: 0, width: 393, height: 48))
        XCTAssertEqual(panelView.listView.frame, CGRect(x: -12, y: 48, width: 393, height: 717))
    }

    func testPanelNavigationBarDispatchesSessionListAndCollapseActions() {
        let panelView = AppAgentChatPanelView()
        var sessionListRequestCount = 0
        var collapseRequestCount = 0
        panelView.onSessionListRequested = { sessionListRequestCount += 1 }
        panelView.onCollapseRequested = { collapseRequestCount += 1 }

        panelView.navigationBar.didTapSessionListButton()
        panelView.navigationBar.didTapCollapseButton()

        XCTAssertEqual(sessionListRequestCount, 1)
        XCTAssertEqual(collapseRequestCount, 1)
    }

    func testSessionSidebarUsesHalfWidthAndSupportsImmediatePresentation() {
        let sidebar = AppAgentSessionSidebarView(frame: bounds)
        let item = AppAgentSessionSidebarItem(
            sessionID: nil,
            title: "演示会话",
            detail: "演示数据",
            isSelected: false
        )
        sidebar.setItems([item])

        sidebar.setPresented(true, animated: false)

        XCTAssertTrue(sidebar.isPresented)
        XCTAssertFalse(sidebar.isHidden)
        XCTAssertEqual(sidebar.sessionListView.frame, CGRect(x: 0, y: 0, width: 196.5, height: 852))
        XCTAssertEqual(sidebar.sessionListView.items, [item])

        sidebar.setPresented(false, animated: false)

        XCTAssertFalse(sidebar.isPresented)
        XCTAssertTrue(sidebar.isHidden)
        XCTAssertEqual(sidebar.sessionListView.frame.minX, -196.5, accuracy: 0.001)
    }

    func testViewControllerSessionListButtonShowsSidebarWithDemoData() {
        let viewController = AppAgentViewController()
        viewController.loadViewIfNeeded()
        viewController.view.frame = bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()

        viewController.chatPanelView.navigationBar.didTapSessionListButton()

        XCTAssertTrue(viewController.sessionSidebarView.isPresented)
        XCTAssertGreaterThanOrEqual(viewController.sessionSidebarView.sessionListView.items.count, 4)
        XCTAssertEqual(viewController.sessionSidebarView.sessionListView.frame.width, bounds.width * 0.5, accuracy: 0.001)
        viewController.hideSessionSidebar(animated: false)
    }

    /// 容器「命中自己就穿透」现在由 BOUIKit 的 bo_skipsSelfInHitTest 提供，
    /// 这条用例同时验证该依赖是否接线成功。
    func testContainerPassesSelfHitsThroughButKeepsSubviews() {
        let container = AppAgentChatPanelContainerView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 200)
        )
        let child = UIView(frame: CGRect(x: 100, y: 100, width: 80, height: 40))
        container.installContentView(child)

        XCTAssertNil(
            container.hitTest(CGPoint(x: 10, y: 10), with: nil),
            "空白区域应穿透给宿主 app"
        )
        XCTAssertTrue(
            container.hitTest(CGPoint(x: 140, y: 120), with: nil) === child,
            "子视图仍要能接住触摸"
        )
    }

    private func makeGeometry() -> AppAgentChatPanelGeometry? {
        AppAgentChatPanelGeometry(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets
        )
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
