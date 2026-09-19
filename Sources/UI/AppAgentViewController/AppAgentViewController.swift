//
//  AppAgentViewController.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// AppAgentViewController 实际应用 inputBar frame 变化的原因。
public enum AppAgentInputBarFrameChangeReason {
    /// 场景：`viewDidLayoutSubviews` 或容器尺寸变化时，AppAgentViewController 主动重新计算并应用 inputBar frame。
    case layout

    /// 场景：inputBar 自己的 textField 激活/失焦，或键盘高度变化后，需要根据键盘避让策略重新应用 inputBar frame。
    case keyboard

    /// 场景：收起态点击 menu 按钮、手势结算判定为展开，或外部主动请求展开 inputBar。
    case expand

    /// 场景：展开态点击 menu 按钮、手势结算判定为收起，或外部主动请求收起 inputBar。
    case collapse

    /// 场景：展开态从 menu 按钮起手横向拖拽 resize，inputBar 跟随手指实时改变宽度。
    case expandedResizePan

    /// 场景：收起态从 menu 按钮起手拖拽移动，inputBar 跟随手指实时改变位置。
    case collapsedMovePan

    /// 场景：收起态拖拽结束后，根据稳定停留、速度和吸附策略计算最终落点并应用 frame。
    case collapsedMoveResolution
}

/// AppAgentViewController 完成 inputBar frame 应用后对外通知的上下文。
public struct AppAgentInputBarFrameChangeContext {
    public let reason: AppAgentInputBarFrameChangeReason
    public let oldFrame: CGRect
    public let newFrame: CGRect
    public let animated: Bool

    public init(
        reason: AppAgentInputBarFrameChangeReason,
        oldFrame: CGRect,
        newFrame: CGRect,
        animated: Bool
    ) {
        self.reason = reason
        self.oldFrame = oldFrame
        self.newFrame = newFrame
        self.animated = animated
    }
}

/// Main view controller for AppAgent chat interface.
/// Hosts a draggable ChatPanel and an input bar (AppAgentInputBar).
/// Intended to be used as the rootViewController of an `AppAgentWindow`.
/// All layout is done via manual frames in `viewDidLayoutSubviews`.
open class AppAgentViewController: UIViewController {

    // MARK: - Public API

    /// 是否打印 inputBar delegate 调试日志；默认关闭，避免拖拽和语音手势 changed 阶段产生高频控制台 I/O。
    public static var isInputBarDelegateDebugLoggingEnabled = false

    /// The agent powering this chat.
    public var agent: AIAgent? {
        didSet {
            // 绑定了真实 agent 就走真实 session/模型；未绑定时回落到本地固定回复，
            // 让纯 UI 调试无需模型配置也能跑。
            usesFixedDebugReply = (agent == nil)
            // 让 session_manage 的 'switch' 能真正切换当前展示的会话（核心不认识 current session）。
            oldValue?.activateSessionHandler = nil
            agent?.activateSessionHandler = { [weak self] sessionId in
                DispatchQueue.main.async { self?.switchSession(to: sessionId) }
                return true
            }
            guard isViewLoaded else { return }
            reloadSessionSidebarItems()
        }
    }

    /// inputBar frame 被 AppAgentViewController 实际应用后触发，宿主可用它观察键盘、展开、收起和拖拽导致的位置变化。
    public var onInputBarFrameChange: ((AppAgentInputBarFrameChangeContext) -> Void)?

    /// UI 层展示事件（会话切换、聊天面板显隐）的宿主回调。与核心 `AIAgentDelegate` 分离：
    /// 「当前展示的是哪个会话 / 面板是否可见」是纯 UI 概念，核心 `AIAgent` 不应依赖 UI 层。
    public weak var presentationDelegate: AppAgentPresentationDelegate?

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
        currentStreamTask?.cancel()
        currentStreamTask = nil
        currentSession?.uiState.onChange = nil
        currentSessionId = sessionId
        // 展开态是「这个会话里用户点开了哪些轮」，换会话就不再适用。
        expandedActivityTurnIDs.removeAll()
        // 卡片是面板全局的一张：先撤掉上一个会话的，再贴新会话正在等的那张（如果有）。
        if isViewLoaded {
            chatPanelView.dismissDecision()
        }
        // 换会话要回到最新一条。
        reloadFromSession(forceScrollToBottom: true)
        bindUIState()
        if isViewLoaded {
            presentPendingDecision(for: sessionId)
        }
        if isViewLoaded {
            reloadSessionSidebarItems()
        }
        presentationDelegate?.appAgent(didSwitchSessionFrom: old, to: sessionId)
    }

    /// 子类可 override 观察 inputBar frame 变化。
    open func inputBarFrameDidChange(_ context: AppAgentInputBarFrameChangeContext) {}

    // MARK: - Subviews

    public let inputBar = AppAgentInputBar()
    let voiceInputOverlayView = AppAgentVoiceInputOverlayView()
    let chatPanelContainer = AppAgentChatPanelContainerView()
    let chatPanelCoordinator = AppAgentChatPanelCoordinator()

    /// 决策卡片的呈现者（强持有；注册表里是弱引用）。
    private var decisionPresenter: AppAgentDecisionPresenter?
    let sessionSidebarView = AppAgentSessionSidebarView()

    /// ChatPanel 的固定内容视图；拖拽容器与状态由 coordinator 统一持有。
    var chatPanelView: AppAgentChatPanelView { chatPanelCoordinator.panelView }

    // MARK: - Data

    var chatMessages: [ChatMessage] = []
    /// 用户手动展开过过程区的轮次号集合。列表每轮结束都会 `reloadFromSession`
    /// 重建，只有把这个状态记在 VC 层、再传给 assembler，才能让用户点开的过程区
    /// 在重建后保持展开。切换会话时清空。
    var expandedActivityTurnIDs: Set<Int> = []
    /// 还在等用户拍板的请求，按 session 排队。
    ///
    /// 卡片是面板全局的一张（`AppAgentChatPanelView.decisionCard`），但请求属于某个
    /// 会话：不属于当前会话的先记着，等用户切回去再贴出来——AGENTS.md 承诺的
    /// 「不影响别的 session / 切回来卡片还在等」。同一会话并发来的第二个请求排在
    /// 后面，不能覆盖掉前一个（那会把它的 continuation 永远挂住）。
    var pendingDecisions: [String: [AppAgentPendingDecision]] = [:]
    var currentStreamTask: Task<Void, Never>?
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

    /// inputBar 布局偏好的持久化存储；frame 策略本身在 AppAgentInputBarFramePolicy。
    let inputBarLayoutStore: AppAgentInputBarLayoutStoring = AppAgentUserDefaultsInputBarLayoutStore()

    /// 语音输入协调器：一次语音输入的唯一状态主人；AppAgentViewController 只做接线。
    lazy var voiceInputCoordinator = AppAgentVoiceInputCoordinator(
        feedback: AppAgentVoiceInputHapticFeedback(generator: makeVoiceRecognitionHapticGenerator())
    )

    /// 展开 resize 跨越最终状态分界线时使用的触觉发生器。
    lazy var expandedResizeDecisionHapticGenerator = makeExpandedResizeDecisionHapticGenerator()

    var effectiveKeyboardHeight: CGFloat {
        shouldInputBarAvoidKeyboard ? observedKeyboardHeight : 0
    }

    var shouldInputBarAvoidKeyboard: Bool {
        inputBar.inputSource == .keyboard && inputBar.textField.isFirstResponder
    }

    /// 是否允许展开态 resize 自定义宽度：开启后左侧触边仍可向右扩展，并可持久化新的首选展开宽度。
    static let allowsExpandedResizeWidthCustomization = false

    /// 启用展开宽度更新后，手指在某个宽度附近停留超过该时长，才可将该宽度记为用户偏好。
    static let expandedResizeHoldDuration: TimeInterval = 0

    /// 启用展开宽度更新后，宽度变化不超过该值时，认为仍停留在同一个目标宽度附近。
    static let expandedResizeWidthStabilityThreshold: CGFloat = 4

    // MARK: - Lifecycle

    override open func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        loadPersistedInputBarLayout()
        setupInputBar()
        setupChatPanel()
        setupSessionSidebar()
        setupVoiceInputOverlay()
        setupKeyboardObservers()

        reloadFromSession(forceScrollToBottom: true)
        bindUIState()
        registerDecisionPresenter()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        currentSession?.uiState.onChange = nil
        if let presenter = decisionPresenter {
            DecisionResponderCentral.default.unregister(presenter)
        }
        // 还在排队等卡片的请求必须就地答复（兜底语义），否则它们的 continuation
        // 带着未恢复状态析构，发起它们的那一轮永远回不来。
        drainPendingDecisions()
    }

    /// 把「等用户拍板」的呈现权拿到 AppAgent 自己手上：卡片在对话面板内弹，
    /// 宿主 app 不需要实现任何异步回调。
    private func registerDecisionPresenter() {
        let presenter = AppAgentDecisionPresenter(
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
        decisionPresenter = presenter
        DecisionResponderCentral.default.register(presenter)
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

    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutInputBar(reason: .layout)
        layoutChatPanel()
        sessionSidebarView.frame = view.bounds
        voiceInputOverlayView.frame = view.bounds
        view.bringSubviewToFront(voiceInputOverlayView)
    }
}

#endif
