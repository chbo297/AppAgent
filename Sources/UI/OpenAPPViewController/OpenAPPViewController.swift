//
//  OpenAPPViewController.swift
//  OpenAPPUI
//

#if canImport(UIKit)
import UIKit

/// OpenAPPViewController 实际应用 inputBar frame 变化的原因。
public enum OpenAPPInputBarFrameChangeReason {
    /// 场景：`viewDidLayoutSubviews` 或容器尺寸变化时，OpenAPPViewController 主动重新计算并应用 inputBar frame。
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

/// OpenAPPViewController 完成 inputBar frame 应用后对外通知的上下文。
public struct OpenAPPInputBarFrameChangeContext {
    public let reason: OpenAPPInputBarFrameChangeReason
    public let oldFrame: CGRect
    public let newFrame: CGRect
    public let animated: Bool

    public init(
        reason: OpenAPPInputBarFrameChangeReason,
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

/// Main view controller for OpenAPP chat interface.
/// Hosts a draggable ChatPanel and an input bar (OpenAPPInputBar).
/// Intended to be used as the rootViewController of an `OpenAPPWindow`.
/// All layout is done via manual frames in `viewDidLayoutSubviews`.
open class OpenAPPViewController: UIViewController {

    // MARK: - Public API

    /// 是否打印 inputBar delegate 调试日志；默认关闭，避免拖拽和语音手势 changed 阶段产生高频控制台 I/O。
    public static var isInputBarDelegateDebugLoggingEnabled = false

    /// The agent powering this chat.
    public var agent: AIAgent? {
        didSet {
            guard isViewLoaded else { return }
            reloadSessionSidebarItems()
        }
    }

    /// inputBar frame 被 OpenAPPViewController 实际应用后触发，宿主可用它观察键盘、展开、收起和拖拽导致的位置变化。
    public var onInputBarFrameChange: ((OpenAPPInputBarFrameChangeContext) -> Void)?

    /// The currently displayed session ID.
    public private(set) var currentSessionId: String?

    /// Convenience: the current session object.
    public var currentSession: AISession? {
        guard let id = currentSessionId else { return nil }
        return agent?.session(id: id)
    }

    /// Switch to a different session.
    public func switchSession(to sessionId: String) {
        currentStreamTask?.cancel()
        currentStreamTask = nil
        currentSession?.uiState.onChange = nil
        currentSessionId = sessionId
        reloadFromSession()
        bindUIState()
        if isViewLoaded {
            reloadSessionSidebarItems()
        }
    }

    /// 子类可 override 观察 inputBar frame 变化。
    open func inputBarFrameDidChange(_ context: OpenAPPInputBarFrameChangeContext) {}

    // MARK: - Subviews

    public let inputBar = OpenAPPInputBar()
    let voiceInputOverlayView = OpenAPPVoiceInputOverlayView()
    let chatPanelContainer = OpenAPPChatPanelContainerView()
    let chatPanelCoordinator = OpenAPPChatPanelCoordinator()
    let sessionSidebarView = OpenAPPSessionSidebarView()

    /// ChatPanel 的固定内容视图；拖拽容器与状态由 coordinator 统一持有。
    var chatPanelView: OpenAPPChatPanelView { chatPanelCoordinator.panelView }

    // MARK: - Data

    var chatMessages: [ChatMessage] = []
    var currentStreamTask: Task<Void, Never>?
    var observedKeyboardHeight: CGFloat = 0
    var hasLaidOutInputBar = false
    var isDraggingExpandedInputBar = false
    var isDraggingCollapsedInputBar = false
    var expandedResizeTracking: OpenAPPExpandedInputBarResizeTracking?
    /// 展开 resize 期间，当前位置以零速度抬手是否会收起；仅在结果翻转时触发反馈。
    var expandedResizeWouldCollapseAtZeroVelocity: Bool?
    var collapsedMoveTracking: OpenAPPCollapsedInputBarMoveTracking?
    var storedExpandedInputBarWidth: CGFloat?
    var storedCollapsedInputBarPlacement: CGPoint?
    var expandedResizeStableWidth: CGFloat?
    var expandedResizeStableStartTime: TimeInterval?
    var keyboardObserver: OpenAPPKeyboardObserver?

    /// 当前 UI 调试阶段默认使用本地固定回复，避免依赖真实模型配置。
    var usesFixedDebugReply = true

    /// inputBar 布局偏好的持久化存储；frame 策略本身在 OpenAPPInputBarFramePolicy。
    let inputBarLayoutStore: OpenAPPInputBarLayoutStoring = OpenAPPUserDefaultsInputBarLayoutStore()

    /// 语音输入协调器：一次语音输入的唯一状态主人；OpenAPPViewController 只做接线。
    lazy var voiceInputCoordinator = OpenAPPVoiceInputCoordinator(
        feedback: OpenAPPVoiceInputHapticFeedback(generator: makeVoiceRecognitionHapticGenerator())
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

        reloadFromSession()
        bindUIState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        currentSession?.uiState.onChange = nil
    }

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
