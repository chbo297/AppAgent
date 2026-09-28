#if canImport(UIKit)
import BOUIKit
import UIKit
import XCTest
@testable import AppAgent

@MainActor
final class AppAgentChatScrollTraceTests: XCTestCase {
    func testSnapshotIncludesBottomInsetWithoutMutatingScrollView() {
        withLogCapture { lines in
            let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 110, right: 0)
            scrollView.contentSize = CGSize(width: 320, height: 1760)
            scrollView.contentOffset.y = 1370
            let originalBounds = scrollView.bounds
            let trace = AppAgentChatScrollTrace()
            let snapshot = trace.capture(scrollView)

            XCTAssertEqual(snapshot?.strictGap, 20)
            XCTAssertEqual(snapshot?.contentGap, -90)
            trace.record("snapshot", on: scrollView, force: true)
            XCTAssertEqual(scrollView.bounds, originalBounds)
            XCTAssertTrue(lines().last?.contains("strictGap=20.0") == true)
            XCTAssertTrue(lines().last?.contains("adjustedTB=4.0,110.0") == true)
        }
    }

    func testObservedActionExecutesExactlyOnceWithAndWithoutLogging() {
        withLogCapture { lines in
            let scrollView = UIScrollView()
            let trace = AppAgentChatScrollTrace()
            var calls = 0
            trace.observe("action", on: scrollView, force: true, details: "calls=\(calls)") {
                calls += 1
            }
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(lines().last?.contains("calls=1") == true)
            let count = lines().count

            Logger.isEnabled = false
            trace.observe("action", on: scrollView, force: true) { calls += 1 }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(lines().count, count)
            XCTAssertNil(trace.capture(scrollView))
        }
    }

    func testForcedEventBypassesSamplingAndDefaultSourceIsCaller() {
        withLogCapture { lines in
            let trace = AppAgentChatScrollTrace()
            let scrollView = UIScrollView()
            trace.record("sample", on: scrollView)
            trace.record("sample", on: scrollView)
            trace.record("sample", on: scrollView, force: true)
            XCTAssertEqual(lines().count, 2)
            XCTAssertTrue(lines().allSatisfy {
                $0.contains("source=testForcedEventBypassesSamplingAndDefaultSourceIsCaller()")
            })
        }
    }

    func testViewportChangeDoesNotFollowContentOnlyBottom() {
        withLogCapture { lines in
            @MainActor func exercise(enabled: Bool) -> (CGFloat, CGFloat) {
                Logger.isEnabled = enabled
                let list = AppAgentChatMessageListView(
                    frame: CGRect(x: 0, y: 0, width: 320, height: 700)
                )
                list.setMessages((0..<40).map { ChatMessage(role: .user, text: "private-message-\($0)") })
                list.updateVisibleArea(visibleHeight: 480, bottomInset: 90)
                list.layoutIfNeeded()
                let table = list.participantScrollView
                table.layoutIfNeeded()
                table.contentOffset.y = table.bo_maximumContentOffsetY - 20
                list.updateVisibleArea(visibleHeight: 482, bottomInset: 90)
                return (table.contentOffset.y, table.bo_maximumContentOffsetY)
            }
            let disabled = exercise(enabled: false)
            let enabled = exercise(enabled: true)
            XCTAssertEqual(disabled.0, enabled.0, accuracy: 0.0001)
            XCTAssertEqual(disabled.1, enabled.1, accuracy: 0.0001)
            XCTAssertLessThan(disabled.0, disabled.1 - 1)
            let output = lines()
            XCTAssertTrue(output.contains {
                $0.contains("event=follow ") && $0.contains("source=updateVisibleArea")
                    && $0.contains("follow=false contentVisible=true")
            })
            XCTAssertFalse(output.contains {
                $0.contains("event=bottom.write ") && $0.contains("source=updateVisibleArea")
                    && $0.contains("dy=18.0")
            })
            XCTAssertFalse(output.contains { $0.contains("private-message-") })
        }
    }

    func testTrackingUsesStrictToleranceWhileNormalUsesOnePixel() {
        @MainActor
        func exercise(
            mode: AppAgentChatMessageListView.VisibleAreaSyncMode,
            gap: CGFloat
        ) -> CGFloat {
            let list = AppAgentChatMessageListView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 700)
            )
            list.setMessages((0..<40).map {
                ChatMessage(role: .user, text: "message-\($0)")
            })
            list.updateVisibleArea(visibleHeight: 480, bottomInset: 90)
            list.layoutIfNeeded()

            let table = list.participantScrollView
            table.layoutIfNeeded()
            table.contentOffset.y = table.bo_maximumContentOffsetY - gap
            XCTAssertEqual(
                table.bo_maximumContentOffsetY - table.contentOffset.y,
                gap,
                accuracy: 0.001
            )
            XCTAssertFalse(table.bo_isScrolledToBottom(tolerance: 0.001))

            // 视口变矮会让真实最大 offset 增大；不跟底时，原 offset 应保持不变。
            list.updateVisibleArea(
                visibleHeight: 479,
                bottomInset: 90,
                syncMode: mode
            )
            return table.bo_maximumContentOffsetY - table.contentOffset.y
        }

        let scale = max(UIScreen.main.scale, 1)
        let onePixel = 1 / scale
        // 用一个完整物理像素，避免 Catalyst 未入层级的 UITableView 把亚像素 offset 夹回最大值。
        let nearBottomGap = onePixel
        let normalGap = exercise(mode: .normal, gap: nearBottomGap)
        let trackingGap = exercise(mode: .tracking, gap: nearBottomGap)

        XCTAssertLessThanOrEqual(normalGap, 0.001)
        XCTAssertGreaterThan(trackingGap, nearBottomGap + 0.5)
    }

    func testViewControllerForwardsCallerToBottomRequest() {
        withLogCapture { lines in
            let viewController = AppAgentViewController()
            viewController.chatPanelView.listView.setMessages([ChatMessage(role: .user, text: "private-text")])
            viewController.scrollToBottom(animated: false)
            XCTAssertTrue(lines().contains {
                $0.contains("event=bottom.request ")
                    && $0.contains("source=VC.testViewControllerForwardsCallerToBottomRequest()")
            })
        }
    }

    func testNonBottomJumpAndReturnBypassSampling() {
        withLogCapture { lines in
            let trace = AppAgentChatScrollTrace()
            let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            scrollView.contentSize = CGSize(width: 320, height: 1480)
            for offset in [CGFloat(200), CGFloat(600), CGFloat(200)] {
                scrollView.contentOffset.y = offset
                trace.didScroll(scrollView)
            }
            XCTAssertEqual(lines().count, 3)
            XCTAssertTrue(lines()[1].contains("dy=400.0"))
            XCTAssertTrue(lines()[2].contains("dy=-400.0"))
        }
    }

    func testViewControllerForwardsCallerToPanelMove() {
        withLogCapture { lines in
            AppAgentViewController().setChatPanelDetent(.half, animated: false)
            XCTAssertTrue(lines().contains {
                $0.contains("event=outer.move ")
                    && $0.contains("source=VC.testViewControllerForwardsCallerToPanelMove()")
            })
        }
    }

    private func withLogCapture(_ body: (_ lines: () -> [String]) -> Void) {
        let savedEnabled = Logger.isEnabled
        let savedLevel = Logger.minimumLevel
        let savedHandler = Logger.handler
        defer {
            Logger.isEnabled = savedEnabled
            Logger.minimumLevel = savedLevel
            Logger.handler = savedHandler
        }
        var captured: [String] = []
        Logger.isEnabled = true
        Logger.minimumLevel = .info
        Logger.handler = { _, line in
            if line.contains("[ChatScrollTrace]") { captured.append(line) }
        }
        body { captured }
    }
}
#endif
