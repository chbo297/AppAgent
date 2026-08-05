#if canImport(UIKit)
import XCTest
@testable import OpenAPP

/// ChatPanel 业务几何与 BODragScroll 接线测试；运动物理由 BODragScroll 自身测试覆盖。
@MainActor
final class OpenAPPChatPanelGeometryTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    private let safeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    private let inputBarExpandedFrame = CGRect(x: 12, y: 762, width: 369, height: 56)

    func testViewControllerUsesFixedReplyByDefaultDuringUIDebugging() {
        XCTAssertTrue(OpenAPPViewController().usesFixedDebugReply)
    }

    func testFixedDebugReplyIsAppendedImmediately() {
        let viewController = OpenAPPViewController()
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

        XCTAssertEqual(geometry.panelSize.width, 369 + 24, accuracy: 0.5)
        XCTAssertEqual(
            geometry.maximumDisplayHeight,
            bounds.height - safeAreaInsets.top + OpenAPPChatPanelGeometry.dragHandleAreaHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(geometry.panelSize.height, geometry.maximumDisplayHeight, accuracy: 0.5)
        XCTAssertEqual(
            bounds.height - geometry.maximumDisplayHeight
                + OpenAPPChatPanelGeometry.dragHandleAreaHeight,
            safeAreaInsets.top,
            accuracy: 0.5
        )
        XCTAssertEqual(
            geometry.peekHeight,
            34 + OpenAPPInputBar.barHeight + OpenAPPChatPanelGeometry.dragHandleAreaHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(geometry.halfHeight, geometry.maximumDisplayHeight * 0.5, accuracy: 0.5)
        XCTAssertEqual(
            bounds.height - geometry.peekHeight + OpenAPPChatPanelGeometry.dragHandleAreaHeight,
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
            OpenAPPChatPanelGeometry(
                bounds: bounds,
                safeAreaInsets: safeAreaInsets,
                inputBarExpandedFrame: CGRect(x: 0, y: 0, width: 390, height: 56)
            )
        )

        XCTAssertEqual(geometry.panelSize.width, bounds.width, accuracy: 0.5)
    }

    func testCompactHeightClampsAndDeduplicatesOverlappingDetents() throws {
        let geometry = try XCTUnwrap(
            OpenAPPChatPanelGeometry(
                bounds: CGRect(x: 0, y: 0, width: 320, height: 100),
                safeAreaInsets: UIEdgeInsets(top: 20, left: 0, bottom: 34, right: 0),
                inputBarExpandedFrame: CGRect(x: 12, y: 0, width: 296, height: 56)
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

    func testNearestDetentAndClampingUseCurrentGeometry() throws {
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertEqual(geometry.nearestDetent(to: geometry.peekHeight + 2), .peek)
        XCTAssertEqual(geometry.nearestDetent(to: geometry.halfHeight + 2), .half)
        XCTAssertEqual(geometry.nearestDetent(to: geometry.maximumDisplayHeight - 2), .full)
        XCTAssertEqual(geometry.clampedDisplayHeight(-100), geometry.peekHeight)
        XCTAssertEqual(geometry.clampedDisplayHeight(10_000), geometry.maximumDisplayHeight)
    }

    func testListViewportCompensatesForHiddenFixedPanelHeight() {
        let listView = OpenAPPChatMessageListView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 700)
        )

        XCTAssertTrue(
            listView.updateViewport(
                panelHeight: 700,
                displayHeight: 350,
                bottomAvoidingInset: 100
            )
        )
        XCTAssertEqual(listView.participantScrollView.contentInset.bottom, 450, accuracy: 0.5)
        XCTAssertFalse(
            listView.updateViewport(
                panelHeight: 700,
                displayHeight: 350,
                bottomAvoidingInset: 100
            )
        )

        XCTAssertTrue(
            listView.updateViewport(
                panelHeight: 700,
                displayHeight: 700,
                bottomAvoidingInset: 100
            )
        )
        XCTAssertEqual(listView.participantScrollView.contentInset.bottom, 100, accuracy: 0.5)
    }

    func testCoordinatorInstallsFixedPanelAndStartsAtHalfDetent() throws {
        let coordinator = OpenAPPChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame,
            bottomAvoidingInset: 102
        )
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertTrue(coordinator.dragScrollView.panelView === coordinator.panelView)
        XCTAssertFalse(coordinator.dragScrollView.clipsToBounds)
        XCTAssertFalse(coordinator.dragScrollView.configuration.bounce.allowsPanelTopBounce)
        XCTAssertFalse(coordinator.dragScrollView.configuration.bounce.allowsPanelBottomBounce)
        XCTAssertEqual(coordinator.dragScrollView.minimumDisplayHeight ?? -1, geometry.peekHeight, accuracy: 0.5)
        XCTAssertEqual(coordinator.dragScrollView.detentHeights, geometry.detentHeights)
        XCTAssertEqual(coordinator.panelView.bounds.size.width, geometry.panelSize.width, accuracy: 0.5)
        XCTAssertEqual(coordinator.panelView.bounds.size.height, geometry.panelSize.height, accuracy: 0.5)
        XCTAssertEqual(coordinator.dragScrollView.displayHeight, geometry.halfHeight, accuracy: 0.5)
        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.contentInset.bottom,
            102 + geometry.maximumDisplayHeight - geometry.halfHeight,
            accuracy: 0.5
        )
    }

    func testCoordinatorProgrammaticMoveUsesBusinessDetent() async throws {
        let coordinator = OpenAPPChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame,
            bottomAvoidingInset: 102
        )
        let geometry = try XCTUnwrap(makeGeometry())
        let halfDetentBottomInset = coordinator.panelView.listView.participantScrollView.contentInset.bottom

        coordinator.move(to: .peek, animated: false)
        coordinator.updateBottomAvoidingInset(103)
        await Task.yield()

        XCTAssertEqual(coordinator.dragScrollView.displayHeight, geometry.peekHeight, accuracy: 0.5)
        XCTAssertEqual(coordinator.panelView.viewportView.frame, CGRect(x: 12, y: 0, width: 369, height: 56))
        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.contentInset.bottom,
            halfDetentBottomInset + 1,
            accuracy: 0.5
        )
    }

    func testCoordinatorUpdatesMetricsWithoutWaitingForIdleAfterTransactionlessDrag() async {
        let coordinator = OpenAPPChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame,
            bottomAvoidingInset: 102
        )
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
        let initialBottomInset = coordinator.panelView.listView.participantScrollView
            .contentInset.bottom

        coordinator.dragScrollView.scrollViewWillBeginDragging(coordinator.dragScrollView)
        coordinator.updateBottomAvoidingInset(110)

        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.contentInset.bottom,
            initialBottomInset + 8,
            accuracy: 0.5
        )

        coordinator.dragScrollView.scrollViewDidEndDragging(
            coordinator.dragScrollView,
            willDecelerate: false
        )
        let nextMainTurn = expectation(description: "no delayed idle settlement is required")
        DispatchQueue.main.async { nextMainTurn.fulfill() }
        await fulfillment(of: [nextMainTurn], timeout: 1)

        XCTAssertEqual(
            coordinator.panelView.listView.participantScrollView.contentInset.bottom,
            initialBottomInset + 8,
            accuracy: 0.5
        )
    }

    func testCoordinatorPreservesMoveRequestedBeforeFirstLayout() throws {
        let coordinator = OpenAPPChatPanelCoordinator()
        coordinator.move(to: .full, animated: false)
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame,
            bottomAvoidingInset: 102
        )
        let geometry = try XCTUnwrap(makeGeometry())

        XCTAssertEqual(
            coordinator.dragScrollView.displayHeight,
            geometry.maximumDisplayHeight,
            accuracy: 0.5
        )
    }

    func testCoordinatorGeometryChangePreservesLiveHeightInsteadOfSnappingToDetent() throws {
        let coordinator = OpenAPPChatPanelCoordinator()
        coordinator.updateLayout(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame,
            bottomAvoidingInset: 102
        )
        let initialGeometry = try XCTUnwrap(makeGeometry())
        let liveHeight = initialGeometry.halfHeight + 37
        coordinator.dragScrollView.scroll(toDisplayHeight: liveHeight, animated: false)
        XCTAssertEqual(coordinator.dragScrollView.displayHeight, liveHeight, accuracy: 0.5)

        let updatedBounds = CGRect(x: 0, y: 0, width: 393, height: 900)
        let updatedInputBarFrame = CGRect(x: 12, y: 810, width: 369, height: 56)
        let updatedGeometry = try XCTUnwrap(
            OpenAPPChatPanelGeometry(
                bounds: updatedBounds,
                safeAreaInsets: safeAreaInsets,
                inputBarExpandedFrame: updatedInputBarFrame
            )
        )
        coordinator.updateLayout(
            bounds: updatedBounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: updatedInputBarFrame,
            bottomAvoidingInset: 102
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
        let layout = OpenAPPChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: inputBarExpandedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(OpenAPPChatPanelContainerLayout.horizontalOutset, 12, accuracy: 0.5)
        XCTAssertEqual(layout.containerFrame, bounds)
        XCTAssertEqual(layout.dragScrollFrame, bounds)
        XCTAssertEqual(
            inputBarExpandedFrame.width + OpenAPPChatPanelGeometry.horizontalOutset * 2,
            layout.containerFrame.width,
            accuracy: 0.5
        )
        XCTAssertEqual(layout.panelAlpha, 1, accuracy: 0.001)
    }

    func testViewControllerMovesEntireChatPanelContainerWithKeyboardLiftedInputBar() {
        let viewController = OpenAPPViewController()
        viewController.loadViewIfNeeded()
        viewController.view.frame = bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()

        let restingFrame = OpenAPPInputBarFramePolicy.preferredExpandedFrame(
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
            x: bounds.maxX - OpenAPPInputBar.collapsedMinWidth - 12,
            y: 620,
            width: OpenAPPInputBar.collapsedMinWidth,
            height: OpenAPPInputBar.barHeight
        )
        let layout = OpenAPPChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: collapsedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(
            layout.containerFrame,
            CGRect(
                x: collapsedFrame.minX - OpenAPPChatPanelContainerLayout.horizontalOutset,
                y: 0,
                width: collapsedFrame.width + OpenAPPChatPanelContainerLayout.horizontalOutset * 2,
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
        let intermediateWidth = (inputBarExpandedFrame.width + OpenAPPInputBar.collapsedMinWidth) / 2
        let intermediateFrame = CGRect(
            x: inputBarExpandedFrame.maxX - intermediateWidth,
            y: inputBarExpandedFrame.minY,
            width: intermediateWidth,
            height: inputBarExpandedFrame.height
        )
        let layout = OpenAPPChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: intermediateFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )

        XCTAssertEqual(
            intermediateFrame.minX - layout.containerFrame.minX,
            OpenAPPChatPanelContainerLayout.horizontalOutset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            layout.containerFrame.width,
            intermediateFrame.width + OpenAPPChatPanelContainerLayout.horizontalOutset * 2,
            accuracy: 0.5
        )
        XCTAssertEqual(layout.panelAlpha, 0.0625, accuracy: 0.001)
    }

    func testChatPanelAlphaUsesEaseOutDuringInteractiveCollapse() {
        let collapseTravel = inputBarExpandedFrame.width - OpenAPPInputBar.collapsedMinWidth
        let quarterCollapsedFrame = CGRect(
            x: inputBarExpandedFrame.minX + collapseTravel * 0.25,
            y: inputBarExpandedFrame.minY,
            width: inputBarExpandedFrame.width - collapseTravel * 0.25,
            height: inputBarExpandedFrame.height
        )
        let layout = OpenAPPChatPanelContainerLayout(
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
        let layout = OpenAPPChatPanelContainerLayout(
            bounds: wideBounds,
            inputBarFrame: currentFrame,
            inputBarExpandedFrame: wideExpandedFrame
        )

        XCTAssertEqual(layout.containerFrame, CGRect(x: 500, y: 0, width: 324, height: 768))
        XCTAssertEqual(layout.dragScrollFrame, CGRect(x: -200, y: 0, width: 1_024, height: 768))
    }

    func testChatPanelContainerHasNoOuterMaskAndCollapsedStateIsInactive() {
        let collapsedFrame = CGRect(
            x: bounds.maxX - OpenAPPInputBar.collapsedMinWidth - 12,
            y: 620,
            width: OpenAPPInputBar.collapsedMinWidth,
            height: OpenAPPInputBar.barHeight
        )
        let layout = OpenAPPChatPanelContainerLayout(
            bounds: bounds,
            inputBarFrame: collapsedFrame,
            inputBarExpandedFrame: inputBarExpandedFrame
        )
        let container = OpenAPPChatPanelContainerView()
        let contentView = UIView()

        container.installContentView(contentView)
        container.apply(layout, animation: .immediate)

        XCTAssertNil(container.layer.mask)
        XCTAssertEqual(container.alpha, 0, accuracy: 0.001)
        XCTAssertFalse(container.isUserInteractionEnabled)
        XCTAssertTrue(container.accessibilityElementsHidden)
    }

    func testViewControllerInstallsDragScrollViewInsideChatPanelContainer() {
        let viewController = OpenAPPViewController()
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
        let viewController = OpenAPPViewController()
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
            appliedInputBarFrame.minX - OpenAPPChatPanelContainerLayout.horizontalOutset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            viewController.chatPanelContainer.frame.width,
            appliedInputBarFrame.width + OpenAPPChatPanelContainerLayout.horizontalOutset * 2,
            accuracy: 0.5
        )
        let expectedLayout = OpenAPPChatPanelContainerLayout(
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
            + OpenAPPInputBar.barHeight
            + OpenAPPChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = OpenAPPChatPanelContentLayout(
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

    func testContentLayoutAboveTransitionKeepsFullyExpandedBackgroundAndViewport() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + OpenAPPInputBar.barHeight
            + OpenAPPChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = OpenAPPChatPanelContentLayout(
            bounds: panelBounds,
            displayHeight: halfHeight + 1,
            minimumDisplayHeight: minimumHeight,
            compactTransitionStartDisplayHeight: halfHeight
        )

        XCTAssertEqual(layout.backgroundFrame, CGRect(x: 0, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.viewportFrame, layout.backgroundFrame)
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 0, width: 393, height: 765))
        XCTAssertEqual(layout.navigationBarFrame, CGRect(x: 0, y: 0, width: 393, height: 48))
        XCTAssertEqual(layout.messageListFrame, CGRect(x: 0, y: 48, width: 393, height: 717))
        XCTAssertEqual(layout.topCornerRadius, 20, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, 0, accuracy: 0.001)
        XCTAssertEqual(layout.compactProgress, 0, accuracy: 0.001)
    }

    func testContentLayoutAtPeekMatchesInputBarAndDoesNotResizeActualContent() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + OpenAPPInputBar.barHeight
            + OpenAPPChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = OpenAPPChatPanelContentLayout(
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
        XCTAssertEqual(layout.topCornerRadius, OpenAPPInputBar.expandedCornerRadius, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, OpenAPPInputBar.expandedCornerRadius, accuracy: 0.001)
        XCTAssertEqual(layout.compactProgress, 1, accuracy: 0.001)
    }

    func testContentLayoutInterpolatesBetweenHalfAndPeek() {
        let panelBounds = CGRect(x: 0, y: 0, width: 393, height: 793)
        let minimumHeight = safeAreaInsets.bottom
            + OpenAPPInputBar.barHeight
            + OpenAPPChatPanelGeometry.dragHandleAreaHeight
        let halfHeight = panelBounds.height * 0.5
        let layout = OpenAPPChatPanelContentLayout(
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
        let layout = OpenAPPChatPanelContentLayout(
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

    func testPanelViewInstallsContentInsideMaskedViewport() {
        let panelView = OpenAPPChatPanelView(frame: CGRect(x: 0, y: 0, width: 393, height: 793))
        let minimumHeight = safeAreaInsets.bottom
            + OpenAPPInputBar.barHeight
            + OpenAPPChatPanelGeometry.dragHandleAreaHeight
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
        XCTAssertNotNil(panelView.viewportView.layer.mask)
        XCTAssertEqual(panelView.viewportView.frame, CGRect(x: 12, y: 0, width: 369, height: 56))
        XCTAssertEqual(panelView.navigationBar.frame, CGRect(x: -12, y: 0, width: 393, height: 48))
        XCTAssertEqual(panelView.listView.frame, CGRect(x: -12, y: 48, width: 393, height: 717))
    }

    func testPanelNavigationBarDispatchesSessionListAndCollapseActions() {
        let panelView = OpenAPPChatPanelView()
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
        let sidebar = OpenAPPSessionSidebarView(frame: bounds)
        let item = OpenAPPSessionSidebarItem(
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
        let viewController = OpenAPPViewController()
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

    private func makeGeometry() -> OpenAPPChatPanelGeometry? {
        OpenAPPChatPanelGeometry(
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            inputBarExpandedFrame: inputBarExpandedFrame
        )
    }
}
#endif
