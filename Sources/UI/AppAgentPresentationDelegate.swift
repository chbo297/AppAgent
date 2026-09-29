//
//  AppAgentPresentationDelegate.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// AppAgent 盖在宿主界面上的一块区域。
///
/// 宿主据此知道自己哪些内容被挡住了。坐标一律是**宿主 window 坐标系**。
public struct AppAgentOccludingArea: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// 输入栏（收起态就是那颗悬浮球）。
        case inputBar
        /// 对话面板的可见区（裁切后的实际范围，不是内容画布）。
        case chatPanel
        /// 会话切换列表侧栏。
        case sessionSidebar
        /// 语音输入浮层。
        case voiceInputOverlay
        /// 等用户拍板的决策卡片。
        case decisionCard
    }

    public let kind: Kind
    public let frame: CGRect
    /// 0…1。面板在收起过渡期间按 ease-out 淡出，别把 0.05 当成还在遮挡。
    public let opacity: CGFloat

    public init(kind: Kind, frame: CGRect, opacity: CGFloat) {
        self.kind = kind
        self.frame = frame
        self.opacity = opacity
    }
}

/// AppAgent 应用这次变化时所用的动画参数。宿主想让自己的界面跟着动，用同一份即可。
public struct AppAgentPresentationAnimation: Equatable, Sendable {
    /// 0 表示立即生效：手势跟手的每一帧、以及纯布局引起的变化。
    public let duration: TimeInterval
    public let options: UIView.AnimationOptions
    /// 非 nil 表示 AppAgent 用的是弹性阻尼曲线（越界回弹），值为 dampingRatio。
    public let springDamping: CGFloat?

    public var isAnimated: Bool { duration > 0 }

    public static let immediate = AppAgentPresentationAnimation(duration: 0, options: [])

    public init(duration: TimeInterval,
                options: UIView.AnimationOptions,
                springDamping: CGFloat? = nil) {
        self.duration = duration
        self.options = options
        self.springDamping = springDamping
    }
}

/// AppAgent 展示状态发生变化的原因。
public enum AppAgentPresentationChangeReason: Equatable, Sendable {
    /// `viewDidLayoutSubviews` 或容器尺寸变化触发的重新布局。
    case layout
    /// 自己的输入框聚焦/失焦或键盘高度变化后的避让。
    case keyboard
    /// 收起态点 menu、手势结算判定为展开，或外部主动请求展开。
    case expand
    /// 展开态点 menu、手势结算判定为收起，或外部主动请求收起。
    case collapse
    /// 展开态从 menu 按钮起手横向拖拽 resize，跟手逐帧。
    case expandedResizePan
    /// 收起态从 menu 按钮起手拖拽移动，跟手逐帧。
    case collapsedMovePan
    /// 收起态拖拽结束后的吸附落点。
    case collapsedMoveResolution
    /// 竖向拖拽改变对话面板展示高度，跟手逐帧。
    case chatPanelHeightPan
    /// overlay window 显示/隐藏。
    case visibility
}

/// AppAgent 当前的展示状态快照。
///
/// `areas` 是唯一真相，具体某一块的位置靠 `frame(of:)` 取；不要另存一份拷贝。
public struct AppAgentPresentationState: Equatable, Sendable {
    public let reason: AppAgentPresentationChangeReason
    public let animation: AppAgentPresentationAnimation
    /// overlay window 是否可见。为 false 时 `areas` 必然为空。
    public let isWindowVisible: Bool
    public let isInputBarCollapsed: Bool
    /// 参与避让的键盘高度（只有 AppAgent 自己的输入框拉起的键盘才非 0）。
    public let keyboardHeight: CGFloat
    public let areas: [AppAgentOccludingArea]

    public init(reason: AppAgentPresentationChangeReason,
                animation: AppAgentPresentationAnimation,
                isWindowVisible: Bool,
                isInputBarCollapsed: Bool,
                keyboardHeight: CGFloat,
                areas: [AppAgentOccludingArea]) {
        self.reason = reason
        self.animation = animation
        self.isWindowVisible = isWindowVisible
        self.isInputBarCollapsed = isInputBarCollapsed
        self.keyboardHeight = keyboardHeight
        self.areas = areas
    }

    public func frame(of kind: AppAgentOccludingArea.Kind) -> CGRect? {
        areas.first { $0.kind == kind }?.frame
    }

    /// 输入栏位置（收起态即悬浮球位置）。
    public var inputBarFrame: CGRect? { frame(of: .inputBar) }

    /// 对话面板可见区的位置与高度。面板不可见时为 nil。
    public var chatPanelFrame: CGRect? { frame(of: .chatPanel) }

    /// 所有区域的并集，方便宿主一次性判断「我这块内容是否被碰到」。
    public var occludedUnion: CGRect {
        areas.reduce(.null) { $0.union($1.frame) }
    }
}

/// UI-layer presentation events emitted by the AppAgent chat surface.
///
/// Split out from `AIAgentDelegate` on purpose: run start/stop/complete are *core*
/// concepts (they live alongside `didCompleteRun` on the agent), whereas "which session
/// is currently displayed" and "is the chat panel visible" are purely UI concepts. The
/// core `AIAgent` has no notion of a current session or panel visibility and must not
/// depend on the UI layer, so these events get their own `@MainActor` protocol driven by
/// `AppAgentViewController` / `AppAgentOverlay`.
///
/// The host (e.g. the bound-page coordinator) adopts this to show/hide/refresh the page
/// bound to the active session.
@MainActor
public protocol AppAgentPresentationDelegate: AnyObject {
    /// The displayed session changed. `old` is the previously bound session id (nil on first bind),
    /// `new` is the now-current session id (nil if unbound).
    func appAgent(didSwitchSessionFrom old: String?, to new: String?)

    /// The chat panel (overlay window) is about to become visible.
    func appAgentChatPanelWillShow()

    /// The chat panel (overlay window) has been hidden.
    func appAgentChatPanelDidHide()

    /// AppAgent 的展示状态变了：输入栏展开/收起/位置、对话面板的位置与高度、
    /// 键盘避让，以及当前盖住宿主的所有区域。
    ///
    /// 状态判等去重后才发，同一份状态不会重复回调；手势跟手期间
    /// `animation.duration == 0`，宿主可据此选择只处理落位（`isAnimated == true`）。
    func appAgentPresentationDidChange(_ state: AppAgentPresentationState)
}

// Default no-op implementations so adopters implement only what they need.
public extension AppAgentPresentationDelegate {
    func appAgent(didSwitchSessionFrom old: String?, to new: String?) {}
    func appAgentChatPanelWillShow() {}
    func appAgentChatPanelDidHide() {}
    func appAgentPresentationDidChange(_ state: AppAgentPresentationState) {}
}

#endif
