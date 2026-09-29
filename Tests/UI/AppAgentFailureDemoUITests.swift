#if canImport(UIKit)
import XCTest
import UIKit
@testable import AppAgent

@MainActor
final class AppAgentFailureDemoUITests: XCTestCase {
    func testDebugPanelReplacesHeightControlsWithFailureDemo() throws {
        let panel = AppAgentRegionDebugPanelView()
        panel.setExpanded(true)
        let descendants = allViews(in: panel)
        XCTAssertFalse(descendants.compactMap { ($0 as? UILabel)?.text }.contains("面板最大高度"))
        XCTAssertFalse(descendants.contains {
            $0.accessibilityIdentifier == "appagent.regionDebug.shrinkPanelMaxHeight"
                || $0.accessibilityIdentifier == "appagent.regionDebug.resetPanelMaxHeight"
        })
        let button = try XCTUnwrap(descendants.first {
            $0.accessibilityIdentifier == "appagent.regionDebug.failureDemo"
        } as? UIButton)
        var clicks = 0
        panel.onFailureDemo = { clicks += 1 }
        try invokeRegisteredAction(button)
        XCTAssertEqual(clicks, 1)
    }

    func testPlaybackBuildsSeparateFailedBubblesAndCanReplay() async throws {
        let controller = AppAgentFailureDemoViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.startPlayback(stepDelay: 1_000_000, betweenTurns: 0)
        let playback = try XCTUnwrap(controller.playbackTask)
        await playback.value
        let demo = try XCTUnwrap(controller.demo)
        XCTAssertEqual(demo.session.currentTurnID, 8)
        XCTAssertEqual(controller.chat.chatMessages.filter { $0.role == .user }.count, 8)
        let replies = controller.chat.chatMessages.filter { $0.role == .assistant }
        XCTAssertEqual(replies.count, 8)
        XCTAssertEqual(replies.compactMap { $0.activity?.displayedFailedStage },
                       [.preparing, .requesting, .requesting, .tooling,
                        .streaming, .requesting, .streaming, .tooling])
        XCTAssertEqual(replies.compactMap { $0.activity?.furthestStage },
                       [.preparing, .requesting, .requesting, .tooling,
                        .streaming, .tooling, .streaming, .finished])
        XCTAssertTrue(replies.allSatisfy { $0.activity?.isRunning == false })
        XCTAssertTrue(replies.prefix(7).allSatisfy { $0.text.contains("Error:") })
        let interrupted = try XCTUnwrap(replies.first { $0.turnID == 5 })
        XCTAssertTrue(interrupted.text.hasPrefix("这是一段已经收到的模型输出"))
        XCTAssertTrue(interrupted.text.contains("\n\nError:"))
        XCTAssertFalse(controller.chat.inputBar.isUserInteractionEnabled)
        XCTAssertNil(controller.playbackTask)

        // 重播只创建新的隔离会话；旧消息不会被清空或复用编号。
        controller.startPlayback(stepDelay: 1_000_000, betweenTurns: 0)
        let replay = try XCTUnwrap(controller.playbackTask)
        await replay.value
        let replayDemo = try XCTUnwrap(controller.demo)
        XCTAssertFalse(replayDemo.agent === demo.agent)
        XCTAssertNotEqual(replayDemo.session.id, demo.session.id)
        XCTAssertEqual(replayDemo.session.currentTurnID, 8)
        XCTAssertEqual(controller.chat.chatMessages.count, 16)
        XCTAssertEqual(demo.session.currentTurnID, 8)
        XCTAssertNil(controller.playbackTask)
    }

    func testStopDuringRequestCancelsCurrentTurnAndDoesNotSendNextScenario() async throws {
        let controller = AppAgentFailureDemoViewController()
        controller.loadViewIfNeeded()
        controller.startPlayback(stepDelay: 10_000_000_000, betweenTurns: 0)
        let playback = try XCTUnwrap(controller.playbackTask)
        let demo = try await waitForFirstRequest(in: controller)
        let streamTask = controller.chat.currentStreamTask
        controller.stopPlayback()
        await playback.value
        await streamTask?.value
        XCTAssertEqual(demo.session.currentTurnID, 2)
        XCTAssertEqual(demo.session.turnRecords[2]?.outcome, .cancelled)
        XCTAssertFalse(demo.session.isRunning)
        XCTAssertEqual(controller.chat.chatMessages.filter { $0.role == .user }.count, 2)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "重播")
        XCTAssertNil(controller.playbackTask)
    }

    func testReleasingPageDuringRequestCancelsPlayback() async throws {
        var controller: AppAgentFailureDemoViewController? = AppAgentFailureDemoViewController()
        weak let weakController = controller
        controller?.loadViewIfNeeded()
        controller?.startPlayback(stepDelay: 10_000_000_000, betweenTurns: 0)
        let playback = try XCTUnwrap(controller?.playbackTask)
        let demo = try await waitForFirstRequest(in: XCTUnwrap(controller))
        controller = nil
        XCTAssertNil(weakController, "播放等待不能强持有整个演示页")
        await playback.value
        XCTAssertEqual(demo.session.turnRecords[2]?.outcome, .cancelled)
        XCTAssertFalse(demo.session.isRunning)
    }

    func testStopBeforeSetupCompletesDoesNotStartMessages() async throws {
        let respondersBefore = DecisionResponderCentral.default.responders.map(ObjectIdentifier.init)
        let controller = AppAgentFailureDemoViewController()
        controller.loadViewIfNeeded()
        XCTAssertEqual(DecisionResponderCentral.default.responders.map(ObjectIdentifier.init), respondersBefore,
                       "演示不能注册全局 responder 抢走真实会话的授权")
        controller.startPlayback(stepDelay: 0, betweenTurns: 0)
        let playback = try XCTUnwrap(controller.playbackTask)
        controller.stopPlayback()
        await playback.value
        XCTAssertNil(controller.demo)
        XCTAssertTrue(controller.chat.chatMessages.isEmpty)
    }

    private func waitForFirstRequest(in controller: AppAgentFailureDemoViewController) async throws -> AppAgentFailureDemo {
        for _ in 0..<200 {
            if let demo = controller.demo, demo.provider.requestCount > 0 { return demo }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        controller.stopPlayback()
        XCTFail("演示未在预算内进入首次模型请求")
        return try XCTUnwrap(controller.demo)
    }

    private func allViews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { allViews(in: $0) }
    }
}
#endif
