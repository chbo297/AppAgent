//
//  AppAgentViewController.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

/// Main view controller for AppAgent chat interface.
/// Hosts a draggable ChatPanel and an input bar (AppAgentInputBar).
/// All layout is done via manual frames in `viewDidLayoutSubviews`.
///
/// **只能作为 `AppAgentWindow` 的 rootViewController 使用**（由 `AppAgentOverlay` 装配）。
/// 不支持宿主把它塞进自己的 VC 层级：面板几何、键盘联动、决策卡片定位都按「独占一个穿透
/// window」推导，嵌进宿主容器后这些前提都不成立。宿主要自定义 UI 就直接对着 `AISession` 写。
public class AppAgentViewController: UIViewController {

    // MARK: - Public API

    /// 是否打印 inputBar delegate 调试日志；默认关闭，避免拖拽和语音手势 changed 阶段产生高频控制台 I/O。
    public static var isInputBarDelegateDebugLoggingEnabled = false

    /// The agent powering this chat.
    public var agent: AIAgent? {
        didSet {
            if oldValue !== agent {
                if let currentSessionId {
                    oldValue?.session(id: currentSessionId)?.uiState.onChange = nil
                }
                detachStreamConsumer()
                // 旧 agent 的请求不结束、不替用户拍板：只是不再由这块面板展示，回到 presenter 挂着，
                // 等能展示那个会话的面板（或换绑回来）再贴出来。
                pendingDecisions.removeAll()
                if isViewLoaded { dismissDecisionCard() }
                if decisionPresenterAttached {
                    decisionPresenter.releaseDecisions(of: self)
                }
                // 不等旧归档 await 返回就解除 UI 锁；旧 completion 必须匹配自己的 token。
                archiveOperationToken = nil
                sessionSidebarView.sessionListView.finishArchiving()
            }
            // 绑定了真实 agent 就走真实 session/模型；未绑定时回落到本地固定回复，
            // 让纯 UI 调试无需模型配置也能跑。
            usesFixedDebugReply = (agent == nil)
            // 让 session 的 'switch' 能真正切换当前展示的会话（核心不认识 current session）。
            oldValue?.activateSessionHandler = nil
            agent?.activateSessionHandler = { [weak self] sessionId in
                DispatchQueue.main.async { self?.switchSession(to: sessionId) }
                return true
            }
            guard isViewLoaded else { return }
            reloadSessionSidebarItems()
        }
    }

    /// UI 层展示事件（会话切换、面板显隐、展示几何与遮挡区域）的宿主回调。与核心 `AIAgentDelegate`
    /// 分离：「当前展示的是哪个会话 / 面板是否可见 / 挡住了什么」是纯 UI 概念，核心 `AIAgent` 不应依赖 UI 层。
    public weak var uiDelegate: AppAgentUIDelegate? {
        didSet {
            if oldValue !== uiDelegate {
                lastReportedUIState = nil
            }
            invalidateHostReservedBottomHeight()
            notifyUIStateChangeIfNeeded(reason: .layout)
        }
    }

    /// 绑定了本控制器的工作区（`AppAgentWorkspace.install` 时设置）；会话切换、展示状态、面板隐藏直接送过去。
    weak var workspace: AppAgentWorkspace?

    /// 上一次报出去的展示状态，用来判等去重。
    var lastReportedUIState: AppAgentUIState?

    /// 当前正在应用的变化原因：面板可见区的变化由面板侧冒泡回来，需要沿用这一次的原因
    /// 而不是一律记成竖向拖拽。
    var currentUIChangeReason: AppAgentUIChangeReason?

    /// 键盘驱动布局时的动画参数。键盘那条路是把 `layoutInputBar` 包在键盘自己的动画块里跑的，
    /// inputBar 侧拿到的是 `.immediate`，真正的时长曲线只有这里记得住。
    var ambientKeyboardAnimation: AppAgentUIAnimation?

    /// The currently displayed session ID.
    public private(set) var currentSessionId: String?

    /// Convenience: the current session object.
    public var currentSession: AISession? {
        guard let id = currentSessionId else { return nil }
        return agent?.session(id: id)
    }

    /// Switch to a different session.
    public func switchSession(to sessionId: String) {
        let old = currentSessionId
        detachStreamConsumer()
        currentSession?.uiState.onChange = nil
        currentSessionId = sessionId
        // 展开态是「这个会话里用户点开了哪些轮」，换会话就不再适用。
        expandedActivityTurnIDs.removeAll()
        collapsedActivityTurnIDs.removeAll()
        // reload 会保留当前轮尚未落库的内容；换会话先清空，不能按相同 turnID 串轮。
        chatMessages.removeAll()
        // 卡片是面板全局的一张：先撤掉上一个会话的，再贴新会话正在等的那张（如果有）。
        if isViewLoaded {
            dismissDecisionCard()
            // 一并清除已分配高度和过程阅读位置，避免相同 turn/start 跨会话继承。
            chatPanelView.listView.setMessages([])
        }
        // 换会话要回到最新一条。
        reloadFromSession(forceScrollToBottom: true, reason: .browsing)
        bindUIState()
        if let session = currentSession {
            applySessionChatPanel(session.chatPanel, animated: true)
        }
        if isViewLoaded {
            presentPendingDecision(for: sessionId)
        }
        if isViewLoaded {
            reloadSessionSidebarItems()
        }
        uiDelegate?.appAgent(didSwitchSessionFrom: old, to: sessionId)
        workspace?.chatViewController(self, didSwitchSessionTo: sessionId)
    }

    /// 宿主主动展开 / 收起输入栏（收起态即那颗悬浮球胶囊）。
    ///
    /// 输入栏还没做过第一次布局时（视图未加载，或已加载但尚未布局）先记到 `startsInputBarCollapsed`，
    /// 由首帧布局按它落位；否则首帧布局会按默认的展开态覆盖掉这次请求。已布局过则即时切换。
    /// 供「常驻悬浮入口」形态下从收起态显式展开成完整面板（如分享回流唤起）用。
    public func setInputBarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard hasLaidOutInputBar else {
            startsInputBarCollapsed = collapsed
            return
        }
        if collapsed {
            collapseInputBar(animated: animated)
        } else {
            expandInputBar(animated: animated)
        }
    }

    // MARK: - Subviews

    public let inputBar = AppAgentInputBar()
    let voiceInputOverlayView = AppAgentVoiceInputOverlayView()
    let chatPanelContainer = AppAgentChatPanelContainerView()
    let chatPanelCoordinator = AppAgentChatPanelCoordinator()

    /// 决策请求的登记处。进程内一份（`.shared`），等待挂在它那里，面板只负责展示；
    /// 面板释放后请求继续等，下一个面板 attach 时接着展示。测试可注入独立实例。
    var decisionPresenter: AppAgentDecisionPresenter = .shared
    private(set) var decisionPresenterAttached = false
    /// 独立诊断页面在加载视图前关闭注册，不能抢走宿主会话的授权请求。
    var registersDecisionPresenter = true
    let sessionSidebarView = AppAgentSessionSidebarView()

    /// ChatPanel 的固定内容视图；拖拽容器与状态由 coordinator 统一持有。
    var chatPanelView: AppAgentChatPanelView { chatPanelCoordinator.panelView }

    // MARK: - Data

    var chatMessages: [ChatMessage] = []
    /// 用户手动展开过过程区的轮次号集合。列表每轮结束都会 `reloadFromSession`
    /// 重建，只有把这个状态记在 VC 层、再传给 assembler，才能让用户点开的过程区
    /// 在重建后保持展开。切换会话时清空。
    var expandedActivityTurnIDs: Set<Int> = []
    /// 显式收起与“没点过”不同：运行中阶段刷新也必须尊重收起选择。
    var collapsedActivityTurnIDs: Set<Int> = []
    /// 还在等用户拍板的请求，按 session 排队。
    ///
    /// 卡片是面板全局的一张（`AppAgentChatPanelView.decisionCard`），但请求属于某个
    /// 会话：不属于当前会话的先记着，等用户切回去再贴出来——AGENTS.md 承诺的
    /// 「不影响别的 session / 切回来卡片还在等」。同一会话并发来的第二个请求排在
    /// 后面，不能覆盖掉前一个（那会把它的 continuation 永远挂住）。
    var pendingDecisions: [String: [AppAgentPendingDecision]] = [:]
    var currentStreamTask: Task<Void, Never>?
    /// 当前消费者的身份。面板不再展示那一轮时只换掉它，旧消费者在下一个事件上自己退出。
    var streamConsumerToken: UUID?
    /// 用户已经按过停止的那一轮（会话 id + turnID）。
    ///
    /// executor 可能还卡在工具里没走到取消检查点，`turnRecord` 也就还没关；按钮不该
    /// 因此又变回停止邀请用户点第二次。新一轮 turnID 一变、或换会话，这条自然失效。
    var stoppedRunTurn: (sessionId: String, turnID: Int)?
    /// 当前归档 UI 操作的 generation；agent 换绑立即失效，不取消已进入存储的写入。
    var archiveOperationToken: UUID?
    var observedKeyboardHeight: CGFloat = 0
    var hasLaidOutInputBar = false
    var isDraggingExpandedInputBar = false
    var isDraggingCollapsedInputBar = false
    var expandedResizeTracking: AppAgentExpandedInputBarResizeTracking?
    /// 展开 resize 期间，当前位置以零速度抬手是否会收起；仅在结果翻转时触发反馈。
    var expandedResizeWouldCollapseAtZeroVelocity: Bool?
    var collapsedMoveTracking: AppAgentCollapsedInputBarMoveTracking?
    var storedExpandedInputBarWidth: CGFloat?
    var storedCollapsedInputBarPlacement: CGPoint?
    var expandedResizeStableWidth: CGFloat?
    var expandedResizeStableStartTime: TimeInterval?
    var keyboardObserver: AppAgentKeyboardObserver?

    /// 消息发送是否走本地固定回复（仅供 UI 调试脱离真实模型时用）。
    /// 生产默认 false：走真实 session → agent → 模型，保证配置 key 后能真正收发消息。
    /// 需要脱离模型联调 UI 时，宿主可将其显式置为 true（`agent` 绑定时仍会按是否有 agent 自动纠正）。
    public var usesFixedDebugReply = false

    /// 首帧是否以**收起态**（那颗悬浮球胶囊）落位，而不是默认的展开态。
    ///
    /// 宿主把 overlay 当作「常驻悬浮入口」时置 true：窗口一挂上就是一颗可拖拽的收起胶囊，
    /// 点它或点 menu 才展开成完整输入栏 + 面板。只在**第一次布局**时被读；之后收/展由手势与
    /// delegate 决定，改这个值不会二次生效。
    public var startsInputBarCollapsed = false

    /// 宿主底部预留高度（pt）：宿主在屏幕底部有自己的控件（如 tab 栏、工具条）会盖住这一段，
    /// 要求输入栏在对话面板收起时让出来。
    ///
    /// 值来自 `uiDelegate.appAgentHostReservedBottomHeight()`：设置 delegate 时取一次，
    /// 之后宿主页面切换导致底部遮挡变化时调用 `invalidateHostReservedBottomHeight()` 重新取。
    /// SDK 不感知任何具体页面概念。配套页面展开（`navigationAccessory.isActive`）期间输入栏不让出这段高度，
    /// 收起后恢复，见 `effectiveHostReservedBottomHeight`。
    ///
    /// 这不是安全区：系统底部安全区（`view.safeAreaInsets.bottom`）由 SDK 自己避让，本值叠加在它之上，
    /// 只表达宿主的遮挡需求。只在对话面板收在 peek 时完整生效；面板向半屏展开的过程中，输入栏随面板底部
    /// 延伸同步回到安全区位置，半屏及以上面板铺到屏幕底部、不再让出。键盘弹起时输入栏仍贴键盘，不叠加此值；
    /// 收起态胶囊不受影响。默认 0。负值、非有限值按 0 处理。
    public internal(set) var hostReservedBottomHeight: CGFloat = 0 {
        didSet {
            guard hostReservedBottomHeight != oldValue else {
                return
            }
            relayoutForHostReservedBottomChange()
        }
    }

    /// 宿主底部遮挡变了（页面切换、底栏显隐）时调用：SDK 向 `uiDelegate` 重新取预留高度，
    /// 值有变化才重排输入栏，宿主不必自己判等。没有 delegate 时按 0 处理。
    public func invalidateHostReservedBottomHeight() {
        let height = uiDelegate?.appAgentHostReservedBottomHeight() ?? 0
        hostReservedBottomHeight = height.isFinite ? max(0, height) : 0
    }

    /// 最近一次输入栏布局所用的预留高度让出量；面板收起进度变化导致它变了，才需要重排输入栏。
    var appliedHostReservedBottomLift: CGFloat = 0

    /// 宿主挂在对话面板顶栏（会话设置按钮左侧）的配套页面开关，例如展开 / 收起宿主为当前会话生成的页面。
    /// 状态由宿主维护：切会话或页面展开 / 收起后重新赋值；nil 隐藏按钮。点按回调见 `onNavigationAccessoryTapped`。
    /// `isActive` 为 true 表示配套页面正盖在宿主页面上，此时输入栏不做宿主底部预留。
    public var navigationAccessory: AppAgentNavigationAccessory? {
        didSet {
            chatPanelView.navigationBar.accessory = navigationAccessory
            if navigationAccessory?.isActive != oldValue?.isActive {
                relayoutForHostReservedBottomChange()
            }
        }
    }

    /// 用户点了 `navigationAccessory` 按钮。SDK 不改按钮状态，由宿主切换页面后再更新 `navigationAccessory`。
    public var onNavigationAccessoryTapped: (() -> Void)?

    /// inputBar 布局偏好的持久化存储；frame 策略本身在 AppAgentInputBarFramePolicy。
    let inputBarLayoutStore: AppAgentInputBarLayoutStoring = AppAgentUserDefaultsInputBarLayoutStore()

    /// 语音输入协调器：一次语音输入的唯一状态主人；AppAgentViewController 只做接线。
    lazy var voiceInputCoordinator = AppAgentVoiceInputCoordinator(
        feedback: AppAgentVoiceInputHapticFeedback(generator: makeVoiceRecognitionHapticGenerator())
    )

    /// 展开 resize 跨越最终状态分界线时使用的触觉发生器。
    lazy var expandedResizeDecisionHapticGenerator = makeExpandedResizeDecisionHapticGenerator()

    /// 加号面板「图片 / 文件」背后的系统选择器，选完放回输入栏。
    lazy var attachmentPicker = makeAttachmentPicker()

    /// 打开选择器时所在的会话；异步读完回来时会话变了就丢弃，不放进别的会话。
    var attachmentPickSessionId: String?

    var effectiveKeyboardHeight: CGFloat {
        shouldInputBarAvoidKeyboard ? observedKeyboardHeight : 0
    }

    var shouldInputBarAvoidKeyboard: Bool {
        inputBar.inputSource == .keyboard && inputBar.textView.isFirstResponder
    }

    /// 是否允许展开态 resize 自定义宽度：开启后左侧触边仍可向右扩展，并可持久化新的首选展开宽度。
    static let allowsExpandedResizeWidthCustomization = false

    /// 启用展开宽度更新后，手指在某个宽度附近停留超过该时长，才可将该宽度记为用户偏好。
    static let expandedResizeHoldDuration: TimeInterval = 0

    /// 启用展开宽度更新后，宽度变化不超过该值时，认为仍停留在同一个目标宽度附近。
    static let expandedResizeWidthStabilityThreshold: CGFloat = 4

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        loadPersistedInputBarLayout()
        setupInputBar()
        setupChatPanel()
        setupSessionSidebar()
        setupVoiceInputOverlay()
        setupKeyboardObservers()

        reloadFromSession(forceScrollToBottom: true, reason: .browsing)
        bindUIState()
        registerDecisionPresenter()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        prepareChatForPresentation()
    }

    deinit {
        // 不结清在等的授权/澄清请求：它们挂在 presenter 上继续等用户，presenter 只弱引用面板，
        // 面板没了它们自动回到「没人展示」，下一个面板 attach 时再贴出来。→ docs/Decisions.md
        // 也不取消流消费者（见 `detachStreamConsumer`）：它只弱引用面板，下一个事件到达时自己退出。
        NotificationCenter.default.removeObserver(self)
    }

    /// 面板不再展示正在跑的那一轮（切会话、换绑 agent）。
    ///
    /// 不取消消费者 Task：取消会顺着流的 `onTermination` 把这一轮停掉，等用户拍板的卡片也跟着
    /// 被结清。这一轮继续在 Core 里跑（或挂起等用户），停止只走 `stopCurrentRun()`。
    func detachStreamConsumer() {
        currentStreamTask = nil
        streamConsumerToken = nil
    }

    /// 把「等用户拍板」的呈现权拿到 AppAgent 自己手上：卡片在对话面板内弹，
    /// 宿主 app 不需要实现任何异步回调。
    private func registerDecisionPresenter() {
        guard registersDecisionPresenter else { return }
        decisionPresenterAttached = true
        decisionPresenter.attach(
            self,
            present: { [weak self] request, sessionId, requestId, complete in
                guard let self else { return false }
                return self.enqueueDecision(request, sessionId: sessionId,
                                            requestId: requestId, complete: complete)
            },
            dismiss: { [weak self] requestId in
                // 请求方放弃等待（run 被取消）：把这一条从队列里摘掉，卡片跟着换下一张。
                self?.cancelDecision(requestId: requestId)
            }
        )
    }

#if DEBUG
    /// 调试用：展开面板 → 真的发一次决策请求（走完整责任链）→ 若 `autoTapOptionId`
    /// 非空则在 `after` 秒后模拟点击该按钮。给 demo 的 `-show-decision-card` 截图验观感用。
    public func debugPresentDecision(_ request: DecisionRequest,
                                     on session: AISession,
                                     autoTapOptionId: String? = nil,
                                     after seconds: TimeInterval = 2) {
        chatPanelCoordinator.move(to: .half, animated: false)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        Task { @MainActor in
            let outcome = await session.requestDecision(request)
            NSLog("DECISIONCARD| outcome=%@", String(describing: outcome))
        }

        guard let optionId = autoTapOptionId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let card = self.chatPanelView.decisionCard
            NSLog("DECISIONCARD| visible=%@ frame=%@ superBounds=%@",
                  card.isHidden ? "false" : "true",
                  NSCoder.string(for: card.frame),
                  NSCoder.string(for: card.superview?.bounds ?? .zero))
            card.debugTapOption(id: optionId)
        }
    }
#endif

    // MARK: - Manual Frame Layout

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutInputBar(reason: .layout)
        layoutChatPanel()
        sessionSidebarView.bo_setFrame(view.bounds)
        voiceInputOverlayView.bo_setFrame(view.bounds)
        view.bringSubviewToFront(voiceInputOverlayView)
        // 收下请求时视图可能还没布局好（面板刚创建、刚 attach 就接到挂着的请求）：布局好了补贴。
        if chatPanelView.decisionCard.isHidden, let sessionId = currentSessionId,
           pendingDecisions[sessionId]?.isEmpty == false {
            presentPendingDecision(for: sessionId)
        }
    }
}

#endif
