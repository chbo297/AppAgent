#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

/// 响应区域调试窗口的几何换算，以及消息正文可选中/可复制的配置。
@MainActor
final class AppAgentRegionDebugTests: XCTestCase {

    func testRegionsHaveDistinctTitlesAndColors() {
        let regions = AppAgentInteractionRegion.allCases
        XCTAssertEqual(regions.count, 5)
        XCTAssertEqual(Set(regions.map { $0.title }).count, 5)
        XCTAssertEqual(Set(regions.map { $0.accessibilityIdentifier }).count, 5)
        XCTAssertEqual(AppAgentInteractionRegion.inputTap.color, .systemRed)
        XCTAssertEqual(AppAgentInteractionRegion.keyboardSwipe.color, .systemYellow)
        XCTAssertEqual(AppAgentInteractionRegion.chatPanelSwipe.color, .systemBlue)
        XCTAssertEqual(AppAgentInteractionRegion.inputBarHit.color, .systemGreen)
        XCTAssertEqual(AppAgentInteractionRegion.chatListViewport.color, .systemRed)
    }

    /// 红框「对话列表可视区域」画的就是 tableView 跟随展示高度后的 frame。
    func testChatListViewportOutlineTracksVisibleHeight() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let listView = AppAgentChatMessageListView(
            frame: CGRect(x: 12, y: 100, width: 366, height: 700)
        )
        container.addSubview(listView)

        listView.updateVisibleArea(visibleHeight: 280, bottomInset: 100)
        let rect = AppAgentRegionDebugViewController.outlineRect(
            source: listView.participantScrollView, container: container
        )
        XCTAssertEqual(rect, CGRect(x: 12, y: 100, width: 366, height: 280))

        listView.updateVisibleArea(visibleHeight: 640, bottomInset: 100)
        let expandedRect = AppAgentRegionDebugViewController.outlineRect(
            source: listView.participantScrollView, container: container
        )
        XCTAssertEqual(expandedRect, CGRect(x: 12, y: 100, width: 366, height: 640))
    }

    func testRectIsNilWithoutTarget() {
        let controller = AppAgentRegionDebugViewController()
        controller.loadViewIfNeeded()
        for region in AppAgentInteractionRegion.allCases {
            XCTAssertNil(controller.rect(for: region), "\(region.title) 无 target 时不应有矩形")
        }
    }

    func testRectsResolveInDebugWindowCoordinates() {
        // 不建 UIWindow（Catalyst xctest 下没有 NSApplication），只验纯几何换算。
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let panelStandIn = UIView(frame: CGRect(x: 12, y: 400, width: 366, height: 440))
        container.addSubview(panelStandIn)
        let inputStandIn = UIView(frame: CGRect(x: 8, y: 380, width: 300, height: 44))
        panelStandIn.addSubview(inputStandIn)

        let inputRect = AppAgentRegionDebugViewController.outlineRect(source: inputStandIn, container: container)
        // 子视图坐标要被换算到 container 坐标系：12+8 / 400+380。
        XCTAssertEqual(inputRect, CGRect(x: 20, y: 780, width: 300, height: 44))

        // 上滑唤键盘区与点击区必须是同一块矩形（调试里靠虚线区分，不靠尺寸）。
        let keyboardRect = AppAgentRegionDebugViewController.outlineRect(source: inputStandIn, container: container)
        XCTAssertEqual(keyboardRect, inputRect)

        let panelRect = AppAgentRegionDebugViewController.outlineRect(source: panelStandIn, container: container)
        XCTAssertEqual(panelRect, panelStandIn.frame)
    }

    func testRectIsNilForHiddenOrTransparentRegion() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        container.addSubview(source)

        source.isHidden = true
        XCTAssertNil(AppAgentRegionDebugViewController.outlineRect(source: source, container: container))

        source.isHidden = false
        // 面板收起时是靠容器 alpha 归零的，所以祖先透明也必须算不可见。
        container.alpha = 0
        XCTAssertNil(AppAgentRegionDebugViewController.outlineRect(source: source, container: container))
    }

    func testOutlineViewDoesNotSwallowTouches() {
        let outline = AppAgentRegionOutlineView(region: .chatPanelSwipe)
        XCTAssertFalse(outline.isUserInteractionEnabled)
        XCTAssertEqual(outline.layer.borderWidth, 1)
    }

    func testCollapsedPanelUsesBOUIKitHitOutsets() {
        let panel = AppAgentRegionDebugPanelView()
        panel.bounds = CGRect(origin: .zero, size: AppAgentRegionDebugPanelView.collapsedSize)

        // 折叠态外扩 2pt（BOUIKit 正值扩大），展开态按实际边界。
        XCTAssertEqual(panel.bo_hitAreaOutsets, UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        XCTAssertTrue(panel.point(inside: CGPoint(x: -1, y: 20), with: nil))
        XCTAssertFalse(panel.point(inside: CGPoint(x: -5, y: 20), with: nil))

        panel.setExpanded(true, notify: false)
        XCTAssertEqual(panel.bo_hitAreaOutsets, .zero)
        panel.setExpanded(false, notify: false)
        XCTAssertFalse(panel.isExpanded)
        for region in AppAgentInteractionRegion.allCases {
            XCTAssertFalse(panel.isOn(region), "\(region.title) 默认应关闭")
        }
    }

    func testDisplayHeightReadoutFormatsPointsAndFitsExpandedPanel() throws {
        let panel = AppAgentRegionDebugPanelView()
        panel.frame = CGRect(origin: .zero, size: AppAgentRegionDebugPanelView.expandedSize)
        panel.setExpanded(true, notify: false)
        let label = try XCTUnwrap(view(
            withIdentifier: "appagent.regionDebug.displayHeight", in: panel
        ) as? UILabel)
        XCTAssertEqual(label.text, "displayHeight: —")

        panel.updateDisplayHeight(410.5)
        XCTAssertEqual(label.text, "displayHeight: 410.5 pt")
        XCTAssertEqual(label.accessibilityValue, "410.5 pt")
        panel.layoutIfNeeded()
        XCTAssertGreaterThan(label.bounds.height, 0)
        XCTAssertTrue(panel.bounds.contains(label.convert(label.bounds, to: panel)))
        XCTAssertLessThanOrEqual(label.intrinsicContentSize.width, label.bounds.width)
        let demoButton = try XCTUnwrap(view(
            withIdentifier: "appagent.regionDebug.failureDemo", in: panel
        ))
        XCTAssertTrue(panel.bounds.contains(demoButton.convert(demoButton.bounds, to: panel)),
                      "增加高度读数后，底部测试按钮仍应完整可见")

        panel.updateDisplayHeight(0)
        XCTAssertEqual(label.text, "displayHeight: 0.0 pt", "零高度不能误报为无目标")
        panel.updateDisplayHeight(nil)
        XCTAssertEqual(label.text, "displayHeight: —")
    }

    func testDebugReadoutTracksActualDragScrollDisplayHeight() throws {
        // 不建 UIWindow，也不加载真实会话，只配置被观测的 coordinator。
        let target = AppAgentViewController()
        let coordinator = target.chatPanelCoordinator
        coordinator.updateLayout(
            bounds: CGRect(x: 0, y: 0, width: 393, height: 852),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        )
        let controller = AppAgentRegionDebugViewController()
        controller.target = target
        controller.loadViewIfNeeded()
        let label = try XCTUnwrap(view(
            withIdentifier: "appagent.regionDebug.displayHeight", in: controller.view
        ) as? UILabel)

        controller.refreshOutlines()
        XCTAssertEqual(coordinator.dragScrollView.displayHeight, 486.5, accuracy: 0.01)
        XCTAssertEqual(label.text, "displayHeight: 486.5 pt")

        // 使用非档位高度，防止读数误用 halfHeight 或固定面板 frame.height。
        coordinator.dragScrollView.scroll(toDisplayHeight: 537.3, animated: false)
        controller.refreshOutlines()
        let actualHeight = coordinator.dragScrollView.displayHeight
        // BODragScroll 可按像素对齐；读数应跟随实际值，而不是传入的目标值。
        let scale = max(1, coordinator.dragScrollView.traitCollection.displayScale)
        XCTAssertEqual(actualHeight, 537.3, accuracy: 1 / scale)
        XCTAssertEqual(label.text, String(format: "displayHeight: %.1f pt", Double(actualHeight)))

        coordinator.move(to: .peek, animated: false)
        controller.refreshOutlines()
        XCTAssertEqual(label.text, "displayHeight: 118.0 pt")

        controller.target = nil
        controller.refreshOutlines()
        XCTAssertEqual(label.text, "displayHeight: —", "目标释放后不能留下旧高度")
    }

    func testExpandedPanelRefreshesWithoutOutlinesAndResumesAfterReappearing() throws {
        let controller = AppAgentRegionDebugViewController()
        controller.loadViewIfNeeded()
        defer { controller.viewDidDisappear(false) }
        let panel = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? AppAgentRegionDebugPanelView }.first
        )
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertTrue(AppAgentInteractionRegion.allCases.allSatisfy { !panel.isOn($0) })

        panel.setExpanded(true)
        XCTAssertTrue(controller.isRefreshing, "只看高度、不画区域框时也需要按帧刷新")
        controller.viewDidDisappear(false)
        XCTAssertFalse(controller.isRefreshing)
        controller.viewDidAppear(false)
        XCTAssertTrue(controller.isRefreshing, "调试窗口再次显示后要恢复实时读数")
        panel.setExpanded(false)
        XCTAssertFalse(controller.isRefreshing, "面板收起且无区域框时停止刷新")

        let toggle = try XCTUnwrap(view(
            withIdentifier: AppAgentInteractionRegion.chatListViewport.accessibilityIdentifier,
            in: panel
        ) as? UISwitch)
        toggle.isOn = true
        try invokeRegisteredAction(toggle, for: .valueChanged)
        XCTAssertTrue(controller.isRefreshing, "折叠时仍保留原有区域框刷新")
        toggle.isOn = false
        try invokeRegisteredAction(toggle, for: .valueChanged)
        XCTAssertFalse(controller.isRefreshing)
    }

    private func view(withIdentifier identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = view(withIdentifier: identifier, in: child) { return match }
        }
        return nil
    }

    /// 点击 / 上滑的输入命中区要纵向撑满整条 bar 的白色背景。
    func testExtendedInputAreaSpansFullBarHeight() {
        let bar = AppAgentInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBarMetrics.barHeight)
        bar.layoutIfNeeded()

        let extended = bar.extendedInputAreaHitRect
        XCTAssertFalse(extended.isNull)
        XCTAssertEqual(extended.minY, bar.bounds.minY)
        XCTAssertEqual(extended.height, bar.bounds.height)
        XCTAssertEqual(extended.minX, bar.inputAreaContainer.frame.minX)
        XCTAssertEqual(extended.width, bar.inputAreaContainer.frame.width)
        XCTAssertLessThan(
            bar.inputAreaContainer.frame.height, extended.height,
            "输入区胶囊本来比 bar 矮，扩大后才覆盖上下留白"
        )
    }

    /// 打在输入区上下留白（原来只命中 bar 背景）的触点要转交给输入区，
    /// 但左侧 menuButton 的命中不能被抢走。
    func testTapAboveInputCapsuleRedirectsIntoInputArea() {
        let bar = AppAgentInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBarMetrics.barHeight)
        bar.layoutIfNeeded()

        let extended = bar.extendedInputAreaHitRect
        let topGapPoint = CGPoint(x: extended.midX, y: extended.minY + 2)
        let hit = bar.hitTest(topGapPoint, with: nil)
        XCTAssertNotNil(hit)
        XCTAssertTrue(
            hit?.isDescendant(of: bar.inputAreaContainer) ?? false,
            "扩大区域内的触点应落到输入区内部控件，实际是 \(String(describing: hit))"
        )

        let menuPoint = CGPoint(x: bar.menuButton.frame.midX, y: bar.menuButton.frame.midY)
        let menuHit = bar.hitTest(menuPoint, with: nil)
        XCTAssertTrue(
            menuHit === bar.menuButton || (menuHit?.isDescendant(of: bar.menuButton) ?? false),
            "menuButton 的命中不能被输入区扩大抢走"
        )
    }

    func testExtendedRectIsUsedForOutline() {
        let bar = AppAgentInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBarMetrics.barHeight)
        bar.layoutIfNeeded()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        container.addSubview(bar)
        bar.frame.origin = CGPoint(x: 12, y: 760)

        let inputRect = AppAgentRegionDebugViewController.outlineRect(
            source: bar, container: container, rectInSource: bar.extendedInputAreaHitRect
        )
        XCTAssertEqual(inputRect?.height, bar.bounds.height, "红框高度 = bar 白色背景高度")

        // 绿框是整条 bar 自身的响应区域。
        let barRect = AppAgentRegionDebugViewController.outlineRect(source: bar, container: container)
        XCTAssertEqual(barRect, bar.frame)
        XCTAssertTrue(barRect?.contains(inputRect ?? .null) ?? false, "输入命中区应落在 bar 响应区内")
    }

    /// 「上滑触发键盘」的起始区域判定必须和「点击输入」用同一块矩形。
    func testKeyboardSwipeRegionMatchesInputTapRegion() {
        let bar = AppAgentInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBarMetrics.barHeight)
        bar.layoutIfNeeded()

        let hit = bar.extendedInputAreaHitRect
        XCTAssertFalse(hit.isNull)
        // 扩大区内任意高度（含上下留白）都应判定为 inputArea 起手，与点击命中区完全一致。
        for y in [hit.minY + 1, hit.midY, hit.maxY - 1] {
            let point = CGPoint(x: hit.midX, y: y)
            XCTAssertEqual(
                bar.panStartRegionForTesting(at: point), .inputArea,
                "扩大区内 y=\(y) 应算输入区起手"
            )
        }
        // 左侧 menuButton 仍然优先，不被输入区吞掉。
        let menuPoint = CGPoint(x: bar.menuButton.frame.midX, y: bar.menuButton.frame.midY)
        XCTAssertEqual(bar.panStartRegionForTesting(at: menuPoint), .menuButton)
    }

    func testMessageTextIsSelectableAndCopyable() {
        let cell = ChatMessageCell(style: .default, reuseIdentifier: ChatMessageCell.reuseIdentifier)
        cell.configure(with: ChatMessage(role: .assistant, text: "可以长按选择这段文案"))

        let textView = cell.messageTextView
        XCTAssertEqual(textView.text, "可以长按选择这段文案")
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable, "只读，长按只出选择/拷贝菜单")
        XCTAssertFalse(textView.isScrollEnabled, "必须关掉滚动，否则会破坏 cell 自适应高度并抢走面板手势")

        // 选中后系统拷贝动作必须可用。
        textView.selectedRange = NSRange(location: 0, length: 3)
        XCTAssertTrue(textView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))

        // 复用时清空选中态。
        cell.prepareForReuse()
        XCTAssertEqual(textView.selectedRange.length, 0)
    }
}
#endif
