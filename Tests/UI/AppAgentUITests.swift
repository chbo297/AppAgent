#if canImport(UIKit)
import XCTest
@testable import AppAgent

final class AppAgentUITests: XCTestCase {

    func testChatMessageCreation() {
        let msg = ChatMessage(role: .user, text: "Hello")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "Hello")
        XCTAssertEqual(msg.status, .complete)
        XCTAssertNotNil(msg.id)
        XCTAssertNotNil(msg.timestamp)
    }

    func testChatMessageStreamingStatus() {
        let msg = ChatMessage(role: .assistant, text: "", status: .streaming)
        XCTAssertEqual(msg.status, .streaming)
        XCTAssertEqual(msg.role, .assistant)
    }

    func testInputBarInputAreaAlphaFadesWhileCollapsingBelowMinimumExpandedWidth() {
        let inputBar = AppAgentInputBar()

        inputBar.frame = CGRect(x: 0, y: 0, width: 240, height: 56)
        inputBar.layoutIfNeeded()
        XCTAssertEqual(inputBar.inputAreaContainer.alpha, 1, accuracy: 0.001)

        inputBar.frame = CGRect(x: 0, y: 0, width: 200, height: 56)
        inputBar.layoutIfNeeded()
        XCTAssertEqual(inputBar.inputAreaContainer.alpha, 0.5, accuracy: 0.001)

        inputBar.frame = CGRect(x: 0, y: 0, width: 160, height: 56)
        inputBar.layoutIfNeeded()
        XCTAssertEqual(inputBar.inputAreaContainer.alpha, 0, accuracy: 0.001)
        XCTAssertTrue(inputBar.textField.isUserInteractionEnabled)

        inputBar.frame = CGRect(x: 0, y: 0, width: AppAgentInputBar.collapsedMinWidth, height: 56)
        inputBar.layoutIfNeeded()
        XCTAssertFalse(inputBar.textField.isUserInteractionEnabled)
    }

    func testInputBarKeyboardModeLongPressRequiresEmptyText() throws {
        let inputBar = AppAgentInputBar(frame: CGRect(
            x: 0,
            y: 0,
            width: AppAgentInputBar.minimumExpandedWidth,
            height: AppAgentInputBar.barHeight
        ))
        inputBar.layoutIfNeeded()

        let longPress = try XCTUnwrap(
            inputBar.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first
        )

        XCTAssertTrue(inputBar.gestureRecognizerShouldBegin(longPress))

        inputBar.text = "draft"
        XCTAssertFalse(inputBar.gestureRecognizerShouldBegin(longPress))

        inputBar.text = " "
        XCTAssertFalse(inputBar.gestureRecognizerShouldBegin(longPress))

        inputBar.clearText()
        XCTAssertTrue(inputBar.gestureRecognizerShouldBegin(longPress))
    }

    /// 等卡片期间 run 被取消（用户按停止 / 切走）：等待必须被唤醒并撤下卡片，
    /// 否则那张卡片会一直挂着等一个已经死掉的回合，executor 的 Task 也回不来。
    func testDecisionWaitUnblocksAndDismissesOnCancellation() async {
        let dismissed = expectation(description: "卡片被撤下")
        let presenter = AppAgentDecisionPresenter(
            present: { _, _, _, _ in true },   // 假装贴出来了，但永远不回调
            dismiss: { _ in dismissed.fulfill() }
        )
        let session = AISession(id: "cancel-while-waiting")

        let task = Task {
            await presenter.respond(
                to: .toolAuthorization(tool: "app_hotfix", safetyLevel: .dangerous, detail: nil),
                session: session
            )
        }
        // 让 respond 真的进到「已呈现、正在等」的状态。
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let outcome = await task.value
        XCTAssertNil(outcome, "取消后应交回责任链兜底，而不是替用户拍板")
        await fulfillment(of: [dismissed], timeout: 2)
    }

    /// 呈现不了（面板没挂载）时立刻返回 nil，让责任链往下走。
    func testDecisionReturnsNilWhenPresentationFails() async {
        let presenter = AppAgentDecisionPresenter(
            present: { _, _, _, _ in false },
            dismiss: { _ in }
        )
        let outcome = await presenter.respond(
            to: .clarification(question: "选哪个？", choices: []),
            session: AISession(id: "cannot-present")
        )
        XCTAssertNil(outcome)
    }
}
#endif
