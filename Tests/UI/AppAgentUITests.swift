#if canImport(UIKit)
import XCTest
@testable import AppAgent

/// 整类跑在主 actor：用例直接构造并测量 `AppAgentInputBar` 等 UIView（frame / isHidden / center /
/// layoutIfNeeded / gestureRecognizerShouldBegin），Swift 6 下这些都是主 actor 隔离的。
/// 剩下几条 async 决策用例也留在主 actor 上，`await` 跨隔离域照常合法。
@MainActor
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
        XCTAssertTrue(inputBar.textView.isUserInteractionEnabled)

        inputBar.frame = CGRect(x: 0, y: 0, width: AppAgentInputBarMetrics.collapsedMinWidth, height: 56)
        inputBar.layoutIfNeeded()
        XCTAssertFalse(inputBar.textView.isUserInteractionEnabled)
    }

    /// 语音按钮因草稿让位时，那一格归输入区：输入区右边界扩到动作槽前，不留空白。
    func testInputBarInputAreaExtendsWhenVoiceButtonHides() {
        let inputBar = AppAgentInputBar(frame: CGRect(x: 0, y: 0, width: 360, height: AppAgentInputBarMetrics.barHeight))
        inputBar.layoutIfNeeded()
        let emptyWidth = inputBar.inputAreaContainer.frame.width

        inputBar.text = "draft"
        XCTAssertTrue(inputBar.inputSourceButton.isHidden)
        XCTAssertEqual(
            inputBar.inputAreaContainer.frame.width,
            emptyWidth + AppAgentInputBarMetrics.buttonSize + AppAgentInputBarMetrics.innerPadding,
            accuracy: 0.5
        )
        XCTAssertEqual(
            inputBar.inputAreaContainer.frame.maxX + AppAgentInputBarMetrics.innerPadding,
            inputBar.plusButton.frame.minX,
            accuracy: 0.5
        )

        inputBar.clearText()
        XCTAssertEqual(inputBar.inputAreaContainer.frame.width, emptyWidth, accuracy: 0.5)
    }

    /// 草稿变长时展开高度逐行长高，到最大可见行数封顶；语音模式恒为单行。
    func testInputBarExpandedHeightGrowsWithDraftAndCaps() {
        let width: CGFloat = 360
        let inputBar = AppAgentInputBar(frame: CGRect(x: 0, y: 0, width: width, height: AppAgentInputBarMetrics.barHeight))
        inputBar.layoutIfNeeded()
        XCTAssertEqual(inputBar.expandedHeight(forWidth: width), AppAgentInputBarMetrics.barHeight, accuracy: 0.5)

        // 一至两行文字放得进与按钮等高的输入区，bar 不长高。
        inputBar.text = "第一行\n第二行"
        XCTAssertEqual(inputBar.expandedHeight(forWidth: width), AppAgentInputBarMetrics.barHeight, accuracy: 0.5)

        // 放不下时 = 文字高度 + 上下各 8；折行按输入区实际宽度算（有草稿后输入源按钮让位，输入区变宽）。
        inputBar.text = Array(repeating: "很长的一段草稿内容", count: 5).joined()
        inputBar.layoutIfNeeded()
        let areaWidth = inputBar.inputAreaContainer.frame.width
        let multiLine = inputBar.expandedHeight(forWidth: width)
        XCTAssertEqual(
            multiLine,
            inputBar.textView.fittingHeight(forWidth: areaWidth) + 16,
            accuracy: 1
        )
        XCTAssertGreaterThan(multiLine, AppAgentInputBarMetrics.barHeight)

        // 到最大可见行数封顶（7 行，参考地图 LUI 输入栏并放宽）。
        inputBar.text = Array(repeating: "很长的一段草稿", count: 40).joined()
        let capped = inputBar.expandedHeight(forWidth: width)
        XCTAssertEqual(capped, inputBar.textView.maximumHeight + 16, accuracy: 0.5)
        XCTAssertGreaterThan(capped, multiLine)
        XCTAssertEqual(capped, inputBar.textView.lineHeight * 7 + 16, accuracy: 1)

        // 输入区上下与 bar 始终相距 8；文字区与文字等高，没有额外留白。
        inputBar.frame.size.height = capped
        inputBar.layoutIfNeeded()
        XCTAssertEqual(inputBar.inputAreaContainer.frame.minY, 8, accuracy: 0.5)
        XCTAssertEqual(inputBar.bounds.height - inputBar.inputAreaContainer.frame.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(inputBar.textView.frame.height, inputBar.inputAreaContainer.frame.height, accuracy: 0.5)

        inputBar.setInputSource(.voice, animated: false)
        XCTAssertEqual(inputBar.expandedHeight(forWidth: width), AppAgentInputBarMetrics.barHeight, accuracy: 0.5)
    }

    /// 展开态贴底向上长高；收窄到收起宽度时高度回到单行，与胶囊等高不跳变。
    func testFramePolicyExpandedHeightAnchorsBottomAndShrinksTowardCapsule() {
        var context = AppAgentInputBarFramePolicy.Context(
            bounds: CGRect(x: 0, y: 0, width: 393, height: 852),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
            keyboardHeight: 0,
            storedExpandedWidth: nil,
            storedCollapsedPlacement: nil
        )
        let singleLine = AppAgentInputBarFramePolicy.preferredExpandedFrame(context)
        context.expandedBarHeight = 92
        let multiLine = AppAgentInputBarFramePolicy.preferredExpandedFrame(context)
        XCTAssertEqual(multiLine.height, 92, accuracy: 0.001)
        XCTAssertEqual(multiLine.maxY, singleLine.maxY, accuracy: 0.001)

        let collapsedWidthFrame = AppAgentInputBarFramePolicy.constrainedExpandedFrame(
            CGRect(x: 0, y: 0, width: AppAgentInputBarMetrics.collapsedMinWidth, height: 92),
            context: context
        )
        XCTAssertEqual(collapsedWidthFrame.height, AppAgentInputBarMetrics.barHeight, accuracy: 0.001)
    }

    /// 宿主挂上 overlay 后立刻要求收起：视图已加载、但还没做第一次布局。首帧布局不能把它改回展开。
    func testCollapseRequestedBeforeFirstLayoutSurvivesFirstLayout() {
        let viewController = AppAgentViewController()
        viewController.loadViewIfNeeded()
        viewController.setInputBarCollapsed(true, animated: false)

        viewController.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        viewController.view.layoutIfNeeded()

        XCTAssertTrue(viewController.inputBar.isCollapsed)
    }

    func testInputBarKeyboardModeLongPressRequiresEmptyText() throws {
        let inputBar = AppAgentInputBar(frame: CGRect(
            x: 0,
            y: 0,
            width: AppAgentInputBarMetrics.minimumExpandedWidth,
            height: AppAgentInputBarMetrics.barHeight
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

    /// 撞并行上限必须有可见反馈：文案要说清「几个在运行」，而不是点了发送没反应。
    func testConcurrencyLimitAlertNamesRunningCount() {
        let alert = AppAgentViewController().makeConcurrencyLimitAlert(runningCount: 9)
        XCTAssertEqual(alert.title, "暂时无法执行更多")
        XCTAssertTrue(alert.message?.contains("9 个会话在运行") == true, alert.message ?? "nil message")
        // 只有一个「好」：这是纯告知，没有可执行的分支。
        XCTAssertEqual(alert.actions.count, 1)
        XCTAssertEqual(alert.actions.first?.style, .cancel)
    }

    /// 右侧动作槽圆里挂着的图标层：只取**真的带图**的 image view，
    /// 这样即使 UIKit 顺手给按钮建了个空的自带 imageView 也不会被算进来。
    private func trailingActionGlyphs(of inputBar: AppAgentInputBar) -> [UIImageView] {
        inputBar.trailingActionButton.subviews
            .compactMap { $0 as? UIImageView }
            .filter { $0.image != nil }
    }

    /// 右侧动作槽三态：有草稿发送、loop 运行中停止、其余加号。
    /// 有草稿时语音按钮一起让位；运行中输入框为空则语音照常可用。
    func testInputBarTrailingActionFollowsDraftAndRunState() {
        let inputBar = AppAgentInputBar(frame: CGRect(
            x: 0,
            y: 0,
            width: AppAgentInputBarMetrics.minimumExpandedWidth,
            height: AppAgentInputBarMetrics.barHeight
        ))
        inputBar.layoutIfNeeded()

        XCTAssertEqual(inputBar.trailingAction, .plus)
        XCTAssertFalse(inputBar.plusButton.isHidden)
        XCTAssertTrue(inputBar.trailingActionButton.isHidden)
        XCTAssertFalse(inputBar.inputSourceButton.isHidden)

        inputBar.setRunActive(true)
        XCTAssertEqual(inputBar.trailingAction, .stop)
        XCTAssertTrue(inputBar.plusButton.isHidden)
        XCTAssertFalse(inputBar.trailingActionButton.isHidden)
        XCTAssertFalse(inputBar.inputSourceButton.isHidden)
        let stopGlyph = trailingActionGlyphs(of: inputBar)
        XCTAssertEqual(stopGlyph.count, 1, "停止形态圆里应当正好有一个图标")
        // 存的是**图片**而不是 image view：换形态时复用的是同一个 view，
        // 抓着 view 事后读 `image` 只会读到当前形态，比不出「图标真的换了」。
        let stopIconImage = stopGlyph.first?.image

        inputBar.text = "几点了"
        XCTAssertEqual(inputBar.trailingAction, .send)
        XCTAssertTrue(inputBar.plusButton.isHidden)
        XCTAssertTrue(inputBar.inputSourceButton.isHidden)
        // 圆比加号里的圆再大一圈（24 + 8 = 32pt），居中在加号那一格里。
        XCTAssertEqual(inputBar.trailingActionButton.bounds.width, 32, accuracy: 0.001)
        XCTAssertEqual(inputBar.trailingActionButton.bounds.height, 32, accuracy: 0.001)
        XCTAssertEqual(
            inputBar.trailingActionButton.center.x, inputBar.plusButton.center.x, accuracy: 0.001
        )
        XCTAssertEqual(
            inputBar.trailingActionButton.center.y, inputBar.plusButton.center.y, accuracy: 0.001
        )
        // 圆比整格小，但点按范围仍外扩回整格：加号格子的角上也算命中。
        XCTAssertTrue(inputBar.trailingActionButton.point(inside: CGPoint(x: -3, y: -3), with: nil))
        // 图标挂在按钮的子 image view 上，不用按钮自带的 image —— 按钮自带图标会被 UIKit 在按下时
        // 调暗，而关掉这个行为的 `adjustsImageWhenHighlighted` 已废弃。锁住三件事：按钮本体不带
        // image、圆里正好一个图标、图标铺满整圆（居中靠 contentMode）。换形态时图标要真的换掉。
        let sendGlyph = trailingActionGlyphs(of: inputBar)
        XCTAssertEqual(sendGlyph.count, 1, "发送形态圆里应当正好有一个图标")
        XCTAssertNil(inputBar.trailingActionButton.image(for: .normal))
        XCTAssertFalse(sendGlyph[0].image === stopIconImage, "发送与停止必须是两个不同的图标")
        XCTAssertEqual(sendGlyph[0].frame, inputBar.trailingActionButton.bounds)

        inputBar.clearText()
        XCTAssertEqual(inputBar.trailingAction, .stop)
        XCTAssertFalse(inputBar.inputSourceButton.isHidden)

        inputBar.setRunActive(false)
        XCTAssertEqual(inputBar.trailingAction, .plus)
        XCTAssertFalse(inputBar.plusButton.isHidden)
        XCTAssertTrue(inputBar.trailingActionButton.isHidden)
    }

    /// 等卡片期间 run 被取消（用户按停止 / 切走）：等待必须被唤醒并撤下卡片，
    /// 否则那张卡片会一直挂着等一个已经死掉的回合，executor 的 Task 也回不来。
    func testDecisionWaitUnblocksAndDismissesOnCancellation() async {
        let dismissed = expectation(description: "卡片被撤下")
        let presenter = AppAgentDecisionPresenter()
        let surface = NSObject()
        presenter.attach(
            surface,
            present: { _, _, _, _ in
                true   // 假装贴出来了，但永远不回调
            },
            dismiss: { _ in
                dismissed.fulfill()
            }
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

    /// 进程里从没有面板 attach 过（纯 headless 集成）：没人能回答，立刻交回责任链。
    func testDecisionReturnsNilWithoutAnySurface() async {
        let presenter = AppAgentDecisionPresenter()
        let outcome = await presenter.respond(
            to: .clarification(question: "选哪个？", choices: []),
            session: AISession(id: "no-surface")
        )
        XCTAssertNil(outcome)
    }

    /// 展示卡片的面板被释放：请求不结束、不替用户拍板，会话一直挂起；
    /// 下一个面板 attach 进来时把它重新贴出来，用户在那里作答。
    func testPendingDecisionSurvivesPanelReleaseAndReappears() async throws {
        let presenter = AppAgentDecisionPresenter()
        var firstPanel: NSObject? = NSObject()
        presenter.attach(
            try XCTUnwrap(firstPanel),
            present: { _, _, _, _ in
                true   // 贴出来了，但用户没选
            },
            dismiss: { _ in
            }
        )
        let session = AISession(id: "panel-released-while-waiting")
        let task = Task {
            await presenter.respond(
                to: .toolAuthorization(tool: "app_hotfix", safetyLevel: .dangerous, detail: nil),
                session: session
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        firstPanel = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(presenter.pendingCount, 1, "面板没了，请求必须继续等用户")

        var presentedSession: String?
        let secondPanel = NSObject()
        presenter.attach(
            secondPanel,
            present: { _, sessionId, _, complete in
                presentedSession = sessionId
                complete(.allowOnce)
                return true
            },
            dismiss: { _ in
            }
        )
        let outcome = await task.value
        XCTAssertEqual(presentedSession, session.id)
        XCTAssertEqual(outcome, .allowOnce)
        XCTAssertEqual(presenter.pendingCount, 0)
    }
}
#endif
