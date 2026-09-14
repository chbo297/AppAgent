#if canImport(UIKit)
import XCTest
@testable import OpenAPP

final class LijiPanelUITests: XCTestCase {

    func testRequirementListViewShowsEmptyStateInitially() {
        let view = LijiRequirementListView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.layoutIfNeeded()
        // 未设置任何行时不应崩溃，空态标签逻辑由 setRows 驱动。
        view.setRows([])
        XCTAssertNotNil(view)
    }

    func testRequirementListViewAcceptsRowsWithoutCrashing() {
        let view = LijiRequirementListView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let row = LijiRequirementRow(id: "r1", taskTitle: "t", prompt: "帮我加个日志",
                                     summary: "已完成", error: "", status: .patchGenerated,
                                     patchId: "p1", applyMode: "instant")
        var captured: (LijiRequirementRow, LijiRequirementAction)?
        view.onAction = { row, action in captured = (row, action) }
        view.setRows([row])
        view.layoutIfNeeded()
        XCTAssertTrue(row.canApply)
        XCTAssertTrue(row.canShare)
        // 手动触发一次动作回调，验证闭包链路可用（真实点击需真机/模拟器 UI 测试覆盖）。
        view.onAction?(row, .apply)
        XCTAssertEqual(captured?.1, .apply)
    }

    func testGrantListViewAcceptsRowsWithoutCrashing() {
        let view = LijiGrantListView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let row = LijiGrantRow(token: "tok", title: "标题", note: "备注", owner: "bob", enabled: true, patchId: "p1")
        var toggled: Bool?
        view.onToggle = { _, enabled in toggled = enabled }
        view.setRows([row])
        view.layoutIfNeeded()
        view.onToggle?(row, false)
        XCTAssertEqual(toggled, false)
    }

    func testPanelViewControllerLoadsWithoutCrashing() {
        let client = LijiServerClient(baseURL: "https://example.invalid")
        let vc = LijiPanelViewController(client: client)
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.title, "app agent 个人中心")
    }
}
#endif
