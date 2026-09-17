#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

/// 响应区域调试窗口的几何换算，以及消息正文可选中/可复制的配置。
final class AppAgentRegionDebugTests: XCTestCase {

    func testRegionsHaveDistinctTitlesAndColors() {
        let regions = AppAgentInteractionRegion.allCases
        XCTAssertEqual(regions.count, 4)
        XCTAssertEqual(Set(regions.map { $0.title }).count, 4)
        XCTAssertEqual(Set(regions.map { $0.accessibilityIdentifier }).count, 4)
        XCTAssertEqual(AppAgentInteractionRegion.inputTap.color, .systemRed)
        XCTAssertEqual(AppAgentInteractionRegion.keyboardSwipe.color, .systemYellow)
        XCTAssertEqual(AppAgentInteractionRegion.chatPanelSwipe.color, .systemBlue)
        XCTAssertEqual(AppAgentInteractionRegion.inputBarHit.color, .systemGreen)
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

        let inputRect = AppAgentRegionDebugViewController.outlineRect(
            for: .inputTap, source: inputStandIn, container: container
        )
        // 子视图坐标要被换算到 container 坐标系：12+8 / 400+380。
        XCTAssertEqual(inputRect, CGRect(x: 20, y: 780, width: 300, height: 44))

        // 黄框是红框内缩 3pt，两者同时打开时才不会完全重叠。
        let keyboardRect = AppAgentRegionDebugViewController.outlineRect(
            for: .keyboardSwipe, source: inputStandIn, container: container
        )
        XCTAssertEqual(keyboardRect, inputRect?.insetBy(dx: 3, dy: 3))

        let panelRect = AppAgentRegionDebugViewController.outlineRect(
            for: .chatPanelSwipe, source: panelStandIn, container: container
        )
        XCTAssertEqual(panelRect, panelStandIn.frame)
    }

    func testRectIsNilForHiddenOrTransparentRegion() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        container.addSubview(source)

        source.isHidden = true
        XCTAssertNil(AppAgentRegionDebugViewController.outlineRect(
            for: .inputTap, source: source, container: container
        ))

        source.isHidden = false
        // 面板收起时是靠容器 alpha 归零的，所以祖先透明也必须算不可见。
        container.alpha = 0
        XCTAssertNil(AppAgentRegionDebugViewController.outlineRect(
            for: .inputTap, source: source, container: container
        ))
    }

    func testOutlineViewDoesNotSwallowTouches() {
        let outline = AppAgentRegionOutlineView(region: .chatPanelSwipe)
        XCTAssertFalse(outline.isUserInteractionEnabled)
        XCTAssertEqual(outline.layer.borderWidth, 1)
    }

    func testCollapsedPanelOnlyHitsButtonArea() {
        let panel = AppAgentRegionDebugPanelView()
        panel.bounds = CGRect(origin: .zero, size: AppAgentRegionDebugPanelView.collapsedSize)
        XCTAssertTrue(panel.point(inside: CGPoint(x: 20, y: 20), with: nil))
        XCTAssertFalse(panel.point(inside: CGPoint(x: 120, y: 20), with: nil))
        XCTAssertFalse(panel.isExpanded)
        for region in AppAgentInteractionRegion.allCases {
            XCTAssertFalse(panel.isOn(region), "\(region.title) 默认应关闭")
        }
    }

    /// 点击 / 上滑的输入命中区要纵向撑满整条 bar 的白色背景。
    func testExtendedInputAreaSpansFullBarHeight() {
        let bar = AppAgentInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBar.barHeight)
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
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBar.barHeight)
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
        bar.frame = CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBar.barHeight)
        bar.layoutIfNeeded()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        container.addSubview(bar)
        bar.frame.origin = CGPoint(x: 12, y: 760)

        let inputRect = AppAgentRegionDebugViewController.outlineRect(
            for: .inputTap, source: bar, container: container,
            rectInSource: bar.extendedInputAreaHitRect
        )
        XCTAssertEqual(inputRect?.height, bar.bounds.height, "红框高度 = bar 白色背景高度")

        // 绿框是整条 bar 自身的响应区域。
        let barRect = AppAgentRegionDebugViewController.outlineRect(
            for: .inputBarHit, source: bar, container: container
        )
        XCTAssertEqual(barRect, bar.frame)
        XCTAssertTrue(barRect?.contains(inputRect ?? .null) ?? false, "输入命中区应落在 bar 响应区内")
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
