#if canImport(UIKit)
import XCTest
@testable import AppAgent

@MainActor
final class AppAgentViewControllerLifecycleTests: XCTestCase {
    private final class WeakReference<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    func testDecisionQueueAcceptsOnlySessionsOwnedByBoundAgent() async {
        let own = await AppAgentFailureDemo.make()
        let other = await AppAgentFailureDemo.make()
        let backgroundSession = await own.agent.createSession(title: "后台会话")
        let controller = AppAgentViewController()
        controller.agent = own.agent
        controller.switchSession(to: own.session.id)
        let request = DecisionRequest.privateNetworkAccess(host: "localhost", url: "http://localhost/")

        XCTAssertFalse(controller.enqueueDecision(
            request, sessionId: other.session.id, requestId: UUID(), complete: { _ in }
        ), "其它 agent 的请求必须交给责任链中的下一个面板")
        XCTAssertNil(controller.pendingDecisions[other.session.id])
        XCTAssertTrue(controller.enqueueDecision(
            request, sessionId: backgroundSession.id, requestId: UUID(), complete: { _ in }
        ), "当前 agent 的后台会话仍应排队等待切回")
        XCTAssertEqual(controller.pendingDecisions[backgroundSession.id]?.count, 1)
    }

    func testNewSessionCompletionDoesNotSwitchReboundAgent() async throws {
        let own = await AppAgentFailureDemo.make()
        let replacement = await AppAgentFailureDemo.make()
        let controller = AppAgentViewController()
        controller.agent = own.agent
        controller.switchSession(to: own.session.id)
        controller.startNewSession()
        controller.agent = replacement.agent
        controller.switchSession(to: replacement.session.id)
        for _ in 0..<200 {
            if own.agent.allSessions.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(own.agent.allSessions.count, 2)
        XCTAssertTrue(controller.currentSession === replacement.session,
                      "旧 agent 的新建结果不能把换绑后的面板切回去")
    }

    func testReleasingChatDuringRequestDoesNotRetainController() async throws {
        let demo = await AppAgentFailureDemo.make(stepDelay: 10_000_000_000)
        await demo.prepare(.firstRequest)
        var controller: AppAgentViewController? = AppAgentViewController()
        let weakController = WeakReference(try XCTUnwrap(controller))
        controller?.agent = demo.agent
        controller?.switchSession(to: demo.session.id)
        controller?.loadViewIfNeeded()
        controller?.sendMessage(text: "等待模型")
        let consumer = try XCTUnwrap(controller?.currentStreamTask)
        defer { demo.session.cancel() }
        for _ in 0..<200 {
            if demo.provider.requestCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(demo.provider.requestCount, 0)
        controller = nil
        XCTAssertNil(weakController.value, "等待流事件的消费者不能强持有面板")
        XCTAssertFalse(consumer.isCancelled, "面板释放不能顺带取消这一轮")
        XCTAssertTrue(demo.session.isRunning, "面板释放后会话继续跑")
        demo.session.cancel()
        await consumer.value
    }

    /// 换绑 agent 不替用户拍板：旧会话的授权继续挂起，换绑回来时卡片重新贴出。
    func testRebindingAgentKeepsPreviousDecisionWaiting() async throws {
        let own = await AppAgentFailureDemo.make()
        let replacement = await AppAgentFailureDemo.make()
        let controller = AppAgentViewController()
        controller.agent = own.agent
        controller.switchSession(to: own.session.id)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let answer = Task {
            await own.session.requestDecision(.privateNetworkAccess(
                host: "localhost", url: "http://localhost/"
            ))
        }
        defer {
            answer.cancel()
        }
        for _ in 0..<200 {
            if controller.pendingDecisions[own.session.id]?.isEmpty == false {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.pendingDecisions[own.session.id]?.isEmpty ?? true)

        controller.agent = replacement.agent
        XCTAssertTrue(controller.pendingDecisions.isEmpty)
        XCTAssertTrue(controller.chatPanelView.decisionCard.isHidden)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(controller.decisionPresenter.pendingCount, 0, "换绑后请求必须继续等用户")

        controller.agent = own.agent
        controller.switchSession(to: own.session.id)
        XCTAssertEqual(controller.pendingDecisions[own.session.id]?.count, 1, "换绑回来要重新拿到这张卡")
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.chatPanelView.decisionCard.isHidden)

        answer.cancel()
        let outcome = await answer.value
        XCTAssertNotEqual(outcome, .allowOnce, "取消后不能被当成用户同意")
    }

    func testRebindingAgentDetachesPreviousSessionObservationAndConsumer() async throws {
        let demo = await AppAgentFailureDemo.make(stepDelay: 10_000_000_000)
        await demo.prepare(.firstRequest)
        let replacement = await AppAgentFailureDemo.make()
        let controller = AppAgentViewController()
        controller.agent = demo.agent
        controller.switchSession(to: demo.session.id)
        controller.loadViewIfNeeded()
        controller.sendMessage(text: "旧会话")
        let consumer = try XCTUnwrap(controller.currentStreamTask)
        defer { demo.session.cancel() }
        XCTAssertNotNil(demo.session.uiState.onChange)

        controller.agent = replacement.agent
        XCTAssertNil(demo.session.uiState.onChange)
        XCTAssertFalse(consumer.isCancelled, "换绑只是不再展示，不能停掉旧会话的这一轮")
        XCTAssertTrue(demo.session.isRunning)
        XCTAssertNil(controller.currentStreamTask)
        controller.switchSession(to: replacement.session.id)
        demo.session.cancel()
        await consumer.value
        XCTAssertTrue(controller.currentSession === replacement.session)
    }
}
#endif
