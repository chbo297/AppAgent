#if canImport(UIKit)
import XCTest
@testable import AppAgent

/// 输入栏「+」：附件条把 bar 撑高并排在最上面一行、附件也算可发送内容、面板方格按列排开。
@MainActor
final class AppAgentInputBarAttachmentTests: XCTestCase {

    private func image(_ id: String) -> AIAgentMessage.Attachment {
        .image(jpegData: Data([0xFF, 0xD8]), id: id)
    }

    private func file(_ id: String) -> AIAgentMessage.Attachment {
        AIAgentMessage.Attachment(id: id, kind: .file, name: "\(id).pdf", mediaType: "application/pdf", byteCount: 10)
    }

    func testAttachmentsGrowBarAboveInputAreaAndEnableSend() throws {
        let width: CGFloat = 360
        let inputBar = AppAgentInputBar(frame: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: AppAgentInputBarMetrics.barHeight
        ))
        inputBar.layoutIfNeeded()
        let singleLineHeight = inputBar.expandedHeight(forWidth: width)
        XCTAssertEqual(inputBar.trailingAction, .plus)

        inputBar.addAttachments([image("a"), image("b"), image("c"), image("d"), image("e"), file("f1")])
        XCTAssertEqual(inputBar.attachments.map(\.id), ["a", "b", "c", "d", "f1"], "最多 4 张图")
        XCTAssertEqual(inputBar.remainingImageAttachmentSlots, 0)
        inputBar.addAttachments([file("f2")])
        XCTAssertEqual(inputBar.attachments.map(\.id), ["a", "b", "c", "d", "f2"], "文件只留一个，后选的替换前一个")

        // 只有附件、没写字也能发送。
        XCTAssertEqual(inputBar.trailingAction, .send)

        // 单行草稿也长高：多出来的一行在最上面放缩略图，输入区排在它下面。
        let grownHeight = inputBar.expandedHeight(forWidth: width)
        XCTAssertGreaterThan(grownHeight, singleLineHeight + AppAgentAttachmentThumbnailView.side)
        inputBar.frame.size.height = grownHeight
        inputBar.layoutIfNeeded()
        XCTAssertFalse(inputBar.attachmentStrip.isHidden)
        XCTAssertEqual(inputBar.attachmentStrip.thumbnails.count, 5)
        XCTAssertTrue(inputBar.attachmentStrip.addButton.isHidden, "图片选满 4 张后不再显示加号格")
        XCTAssertLessThanOrEqual(inputBar.attachmentStrip.frame.maxY, inputBar.inputAreaContainer.frame.minY)
        XCTAssertEqual(inputBar.attachmentStrip.frame.minX, inputBar.menuButton.frame.minX, accuracy: 0.001, "缩略图左边与最左侧圆形按钮对齐")
        XCTAssertEqual(inputBar.attachmentStrip.frame.maxX, width - AppAgentInputBarMetrics.innerPadding, accuracy: 0.001)
        XCTAssertEqual(inputBar.plusButton.frame.maxY, grownHeight - 8, accuracy: 0.001, "按钮仍贴底")

        // 右上角的叉移除单个附件；全部移除后回到单行高度和加号。
        let first = inputBar.attachmentStrip.thumbnails[0]
        XCTAssertFalse(first.removeButton.isHidden)
        try invokeRegisteredAction(first.removeButton)
        XCTAssertEqual(inputBar.attachments.map(\.id), ["b", "c", "d", "f2"])
        inputBar.attachmentStrip.layoutIfNeeded()
        let addButton = inputBar.attachmentStrip.addButton
        XCTAssertFalse(addButton.isHidden, "删掉一张后加号格回来")
        let lastThumbnail = inputBar.attachmentStrip.thumbnails[3]
        XCTAssertGreaterThan(addButton.frame.minX, lastThumbnail.frame.maxX, "加号格排在最后一张右边")
        XCTAssertEqual(addButton.frame.maxY, lastThumbnail.frame.maxY, accuracy: 0.001)
        inputBar.removeAllAttachments()
        XCTAssertEqual(inputBar.expandedHeight(forWidth: width), singleLineHeight, accuracy: 0.001)
        XCTAssertEqual(inputBar.trailingAction, .plus)
    }

    /// 面板展开时加号变成叉，再点一次收起、变回加号。
    func testPlusButtonTurnsIntoCloseWhilePanelIsShown() {
        let inputBar = AppAgentInputBar(frame: CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBarMetrics.barHeight))
        XCTAssertEqual(inputBar.plusButton.accessibilityLabel, "更多")
        inputBar.showAttachmentPanel()
        XCTAssertTrue(inputBar.isShowingAttachmentPanel)
        XCTAssertEqual(inputBar.plusButton.accessibilityLabel, "收起")
        inputBar.toggleAttachmentPanel()
        XCTAssertFalse(inputBar.isShowingAttachmentPanel)
        XCTAssertEqual(inputBar.plusButton.accessibilityLabel, "更多")
    }

    func testPanelLaysOutIconTilesInColumns() {
        let panel = AppAgentAttachmentPanelView(sources: AppAgentInputBarAttachmentSource.allCases)
        panel.layoutTiles(in: 390)
        XCTAssertEqual(panel.tiles.map(\.titleLabel.text), ["图片", "文件"])
        let first = panel.tiles[0].frame
        let second = panel.tiles[1].frame
        XCTAssertEqual(first.minY, second.minY, "同一行")
        XCTAssertEqual(second.minX - first.minX, (390 - 48) / CGFloat(AppAgentAttachmentPanelView.columnCount), accuracy: 0.001)
        XCTAssertEqual(first.size, AppAgentAttachmentPanelTile.size)
    }

    func testAttachmentOnlyUserBubbleShowsThumbnailsWithoutTextBubble() {
        let cell = ChatMessageCell(style: .default, reuseIdentifier: nil)
        cell.configure(with: ChatMessage(role: .user, text: "", attachments: [image("x"), file("y")]))
        XCTAssertFalse(cell.attachmentRow.isHidden)
        XCTAssertEqual(cell.attachmentRow.thumbnails.count, 2)
        XCTAssertTrue(cell.attachmentRow.thumbnails.allSatisfy { thumbnail in
            thumbnail.removeButton.isHidden
        }, "气泡里的缩略图不带叉")

        cell.configure(with: ChatMessage(role: .user, text: "hi"))
        XCTAssertTrue(cell.attachmentRow.isHidden)
    }
}
#endif
