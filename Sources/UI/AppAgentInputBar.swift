//
//  AppAgentInputBar.swift
//  AppAgentUI
//

#if canImport(UIKit)
import BOUIKit
import UIKit

// MARK: - Delegate Protocol

/// inputBar frame 拖拽的业务类型，用于区分展开态调整宽度和收起态移动位置。
public enum AppAgentInputBarFramePanKind {
    case expandedResize
    case collapsedMove
}

/// inputBar frame 的应用方式：拖拽即时跟手、普通过渡或越界回弹。
public enum AppAgentInputBarFrameAnimation {
    /// 不播放动画，立即应用 frame；用于布局和拖拽 changed 阶段。
    case immediate

    /// 普通 ease-out 过渡；用于展开、收起和常规吸附。
    case standard

    /// 带阻尼的边界回弹；用于展开 resize 或收起 move 越界后的合法 frame 恢复。
    case boundaryRebound

    var isAnimated: Bool { presentation.isAnimated }

    /// 这一档动画的参数。`makeAnimator` 与上报给宿主的 `AppAgentPresentationAnimation`
    /// 共用这一份：宿主要跟着一起动，拿到的必须就是我们真正用的那条曲线，两处常量不许各自漂移。
    var presentation: AppAgentPresentationAnimation {
        switch self {
        case .immediate:
            return .immediate
        case .standard:
            return AppAgentPresentationAnimation(duration: 0.24, options: [.curveEaseOut])
        case .boundaryRebound:
            return AppAgentPresentationAnimation(duration: 0.30, options: [], springDamping: 0.78)
        }
    }

    /// 造 UIKit 动画器：`UIViewPropertyAnimator` 本身是主线程类型，标 `@MainActor` 让调用方
    /// 的主线程前提变成编译期事实（调用点本来全在 inputBar 的布局路径上）。
    @MainActor
    func makeAnimator(animations: @escaping () -> Void) -> UIViewPropertyAnimator? {
        let params = presentation
        guard params.isAnimated else { return nil }
        guard let damping = params.springDamping else {
            return UIViewPropertyAnimator(duration: params.duration, curve: .easeOut, animations: animations)
        }
        let timing = UISpringTimingParameters(dampingRatio: damping)
        let animator = UIViewPropertyAnimator(duration: params.duration, timingParameters: timing)
        animator.addAnimations(animations)
        return animator
    }
}

/// inputBar 当前输入源模式：键盘输入或语音输入。
public enum AppAgentInputBarInputSource {
    case keyboard
    case voice
}

/// inputBar 右侧动作槽（原加号位置）当前的形态。
///
/// 只有三态，且优先级固定：**有草稿 → 发送**，其次 **loop 运行中 → 停止**，否则 **加号**。
/// 有草稿时语音按钮一并让位，界面上只剩「把这段话发出去」这一个动作。
public enum AppAgentInputBarTrailingAction {
    case plus
    case send
    case stop
}

/// 触发语音输入的交互场景，用于区分“语音模式按下”和“键盘模式长按”。
public enum AppAgentInputBarVoiceInputSource {
    /// 语音输入模式下，手指按下中间“按住说话”区域。
    case voiceModePress

    /// 键盘输入模式且键盘未激活时，长按输入区域或输入源切换按钮。
    case keyboardModeLongPress
}

/// 语音输入手势的值上下文：不向宿主暴露 UIKit recognizer，只透传阶段与宿主坐标系中的位置。
public struct AppAgentInputBarVoiceGestureEvent {
    /// 手势阶段：prewarm(touchDown 预热) → began → moved* → ended / cancelled；
    /// 短按未成立时 prewarm 之后直接 abortPrewarm。
    public enum Phase {
        /// touchDown：提前预热语音（面板不展示），仅键盘模式长按候选区触发。
        case prewarm
        /// touchUp 但长按未成立：取消预热。
        case abortPrewarm
        case began
        case moved
        case ended
        case cancelled
    }

    public let source: AppAgentInputBarVoiceInputSource
    public let phase: Phase

    /// 手指在 inputBar 宿主视图（superview）坐标系中的位置。
    public let locationInHost: CGPoint
}

/// 被动触摸探针：永不进入 `.began` / `.recognized`，因此不参与手势竞争、不吞触点，
/// 只把 touchDown / touchUp(或 cancel) 透传给回调，用于语音输入的「预热 / 取消预热」。
/// 必须配 `cancelsTouchesInView = false`、`delaysTouchesBegan/Ended = false` 保持透明。
final class AppAgentTouchProbeGestureRecognizer: UIGestureRecognizer {
    var onTouchDown: ((UITouch) -> Void)?
    var onTouchUp: (() -> Void)?
    private weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        onTouchDown?(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if let tracked = trackedTouch, touches.contains(tracked) {
            finishTracking()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if let tracked = trackedTouch, touches.contains(tracked) {
            finishTracking()
        }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }

    private func finishTracking() {
        trackedTouch = nil
        onTouchUp?()
        // 保持不识别：置 failed 彻底退出本次序列，绝不吞触点。
        state = .failed
    }
}

/// inputBar frame 拖拽结束时传给外部的上下文，外部据此决定最终展开、收起、吸附或自由落位。
public struct AppAgentInputBarFramePanEndContext {
    public let kind: AppAgentInputBarFramePanKind
    public let velocity: CGPoint
    public let frame: CGRect

    /// 收起态 move 结束时，手指是否已经在当前位置附近低速停留足够久；为 true 时外部通常自由落位，不再吸附边缘。
    public let didHoldNearFinalPosition: Bool

    public init(
        kind: AppAgentInputBarFramePanKind,
        velocity: CGPoint,
        frame: CGRect,
        didHoldNearFinalPosition: Bool
    ) {
        self.kind = kind
        self.velocity = velocity
        self.frame = frame
        self.didHoldNearFinalPosition = didHoldNearFinalPosition
    }
}

/// inputBar 对外事件代理：文本发送、输入源变化、语音手势、展开收起 frame 意图都通过这里通知宿主。
@MainActor
public protocol AppAgentInputBarDelegate: AnyObject {
    /// 点发送 / 键盘发送键。带附件时 `text` 可以为空，附件从 `bar.attachments` 读。
    func inputBar(_ bar: AppAgentInputBar, didSendText text: String)
    func inputBarDidTapVoice(_ bar: AppAgentInputBar)
    /// 点了加号。inputBar 自己负责展开 / 收起加号面板，这里只是通知。
    func inputBarDidTapPlus(_ bar: AppAgentInputBar)
    /// 在加号面板里点了一项能力（图片 / 文件）。面板已收起，宿主负责弹出对应的系统选择器，
    /// 选完用 `addAttachments(_:)` 放回输入栏。
    func inputBar(_ bar: AppAgentInputBar, didSelectAttachmentSource source: AppAgentInputBarAttachmentSource)
    /// 用户在发送前移除了附件（点 ×、或再选一个文件把旧的替换掉）。发送后的清空不走这里。
    /// 宿主据此删掉已经拷进工作区的文件。
    func inputBar(_ bar: AppAgentInputBar, didDiscardAttachments attachments: [AIAgentMessage.Attachment])
    /// loop 运行中且输入框为空时，右侧圆形按钮变为停止按钮，点击走这里。
    func inputBarDidTapStop(_ bar: AppAgentInputBar)
    func inputBar(_ bar: AppAgentInputBar, didChangeInputSource source: AppAgentInputBarInputSource)
    func inputBar(_ bar: AppAgentInputBar, didChangeTextInputFocus isFocused: Bool)
    /// 草稿行数、输入源或动作槽变化使展开态应有高度（`expandedHeight(forWidth:)`）变了，宿主据此重排 frame。
    func inputBarDidChangeExpandedHeight(_ bar: AppAgentInputBar)
    func inputBar(_ bar: AppAgentInputBar, didReceiveVoiceInputGesture event: AppAgentInputBarVoiceGestureEvent)
    func inputBarDidRequestExpand(_ bar: AppAgentInputBar)
    func inputBarDidRequestCollapse(_ bar: AppAgentInputBar)
    func inputBar(
        _ bar: AppAgentInputBar,
        wantsFrame frame: CGRect,
        panKind kind: AppAgentInputBarFramePanKind
    )
    func inputBar(
        _ bar: AppAgentInputBar,
        didEndFramePan context: AppAgentInputBarFramePanEndContext
    )
}

/// inputBar 代理默认空实现，让宿主只实现自己关心的事件。
public extension AppAgentInputBarDelegate {
    func inputBar(_ bar: AppAgentInputBar, didSendText text: String) {}
    func inputBarDidTapVoice(_ bar: AppAgentInputBar) {}
    func inputBarDidTapPlus(_ bar: AppAgentInputBar) {}
    func inputBar(_ bar: AppAgentInputBar, didSelectAttachmentSource source: AppAgentInputBarAttachmentSource) {}
    func inputBar(_ bar: AppAgentInputBar, didDiscardAttachments attachments: [AIAgentMessage.Attachment]) {}
    func inputBarDidTapStop(_ bar: AppAgentInputBar) {}
    func inputBar(_ bar: AppAgentInputBar, didChangeInputSource source: AppAgentInputBarInputSource) {}
    func inputBar(_ bar: AppAgentInputBar, didChangeTextInputFocus isFocused: Bool) {}
    func inputBarDidChangeExpandedHeight(_ bar: AppAgentInputBar) {}
    func inputBar(_ bar: AppAgentInputBar, didReceiveVoiceInputGesture event: AppAgentInputBarVoiceGestureEvent) {}
    func inputBarDidRequestExpand(_ bar: AppAgentInputBar) {}
    func inputBarDidRequestCollapse(_ bar: AppAgentInputBar) {}
    func inputBar(
        _ bar: AppAgentInputBar,
        wantsFrame frame: CGRect,
        panKind kind: AppAgentInputBarFramePanKind
    ) {}
    func inputBar(
        _ bar: AppAgentInputBar,
        didEndFramePan context: AppAgentInputBarFramePanEndContext
    ) {}
}

// MARK: - AppAgentInputBar

/// 胶囊输入栏视图：内部负责按钮、输入区、语音输入区布局和手势识别，外部宿主负责最终 frame 约束与落位。
///
/// 草稿较长时输入区按行长高，最多 `AppAgentTextView.maximumVisibleLineCount` 行，超过后框内滚动；
/// 两侧按钮贴底跟着最后一行。展开态应有高度由 `expandedHeight(forWidth:)` 给出，变化时通知宿主重排。
public final class AppAgentInputBar: UIView {

    // MARK: - Layout Constants

    private static let symbolIconPointSize: CGFloat = 24
    private static let keyboardIconPointSize: CGFloat = 17
    /// 发送 / 停止的实心圆直径：比 `plus.circle` 画出来的圆（24pt）再大一圈——半径 +4pt，
    /// 实心圆才压得住这一格的视觉重量。按钮本体就这么大，40pt 的点按范围靠 `bo_hitAreaOutsets` 外扩回来。
    private static let trailingActionCircleSide: CGFloat = symbolIconPointSize + 8
    /// 圆比整格小，命中区就按这个值外扩回 40pt，点按手感和加号完全一致。
    private static var trailingActionHitOutset: CGFloat {
        (AppAgentInputBarMetrics.buttonSize - trailingActionCircleSide) / 2
    }
    /// 上箭头 = 发送；实心方块 = 停止（配上蓝色圆底就是参考图里的「外圆内方」）。
    /// 点数按 32pt 圆的比例给：箭头约占一半，方块约三分之一。
    private static let sendIcon = systemSymbolImage(
        primary: "arrow.up", fallbacks: ["arrow.up.circle"], pointSize: 16, weight: .semibold
    )
    private static let stopIcon = systemSymbolImage(
        primary: "stop.fill", fallbacks: ["square.fill"], pointSize: 12, weight: .semibold
    )
    private static let inactiveTextInputPlaceholder = "发消息或按住说话..."
    private static let activeTextInputPlaceholder = "发消息..."

    private static let normalZeroInputAreaWidth: CGFloat =
        AppAgentInputBarMetrics.innerPadding * 5 + AppAgentInputBarMetrics.buttonSize * 3
    private static let compressedTextGapWidth: CGFloat =
        AppAgentInputBarMetrics.innerPadding * 4 + AppAgentInputBarMetrics.buttonSize * 3
    private static let collapsedPlusVisibleWidth: CGFloat =
        AppAgentInputBarMetrics.innerPadding * 3 + AppAgentInputBarMetrics.buttonSize * 2

    /// 输入区（文字区 / 语音「按住说话」区）与 bar 上下边缘的间距，与两侧按钮一致：(56 - 40) / 2 = 8。
    private static let inputAreaVerticalPadding: CGFloat =
        (AppAgentInputBarMetrics.barHeight - AppAgentInputBarMetrics.buttonSize) / 2

    /// 输入区最小高度，与按钮等高；文字超出后输入区随文字长高，上下间距仍是 8。
    private static let inputAreaMinimumHeight: CGFloat = AppAgentInputBarMetrics.buttonSize

    /// 一次最多带几张图、几个文件。
    public static let maximumImageAttachmentCount = 4
    public static let maximumFileAttachmentCount = 1

    /// 附件条占的顶部区域：上留 4pt，下面直接接输入区原有的 8pt 上边距；高度含叉的外伸。
    private static let attachmentStripTopPadding: CGFloat = 4
    private static var attachmentRegionHeight: CGFloat {
        attachmentStripTopPadding + AppAgentAttachmentThumbnailView.removableSize.height
    }

    private static let panDirectionThreshold: CGFloat = 6
    private static let collapsedHoldPositionThreshold: CGFloat = 4
    private static let collapsedHoldDuration: TimeInterval = 0.3
    private static let collapsedHoldSlowVelocityThreshold: CGFloat = 50
    private static let resizeToCollapsedMoveHoldDuration: TimeInterval = 0.1


    // MARK: - State

    /// pan 手势首次明确后的方向，用于把横向 resize/move 和竖向键盘焦点手势区分开。
    private enum InputBarPanDirection {
        case undecided
        case horizontal
        case vertical
    }

    /// pan 手势的起手区域，用于决定同一组手势位移应该触发 menu resize/move、输入区焦点还是普通 bar 行为。
    enum InputBarPanStartRegion {
        case bar
        case menuButton
        case inputArea
    }

    /// pan 手势在本次交互中锁定的处理模式，锁定后不再根据后续移动重新改判。
    private enum InputBarPanMode {
        case undecided
        case expandedMenuResize
        case collapsedMenuMove
        case textInputFocus
        case ignored
    }

    private var lastLaidOutSize: CGSize = .zero
    /// 上一次布局时文字区排版用的文字高度；草稿变长但 bar 尺寸不变（如一两行在 40pt 输入区内换行）时，
    /// 用它判断文字区 frame 是否需要重排，不能只按 size 短路。
    private var lastLaidOutTextHeight: CGFloat = 0
    private var inputBarPanStartRegion: InputBarPanStartRegion = .bar
    private var inputBarPanMode: InputBarPanMode = .undecided
    private var inputBarPanStartedCollapsed = false
    private var inputBarPanAnchorFrame: CGRect = .zero
    private var inputBarPanAnchorTranslation: CGPoint = .zero
    private var collapsedHoldAnchorCenter: CGPoint = .zero
    private var collapsedHoldStartTime: TimeInterval?
    private var resizeCollapsedHoldStartTime: TimeInterval?
    private var isHoldingVoiceInput = false
    private var activeVoiceInputSource: AppAgentInputBarVoiceInputSource?
    private var lastVoiceInputHostLocation: CGPoint = .zero

    /// 探针已发出预热、且本次触摸尚未转成正式语音输入（用于 touchUp 时决定是否取消预热）。
    private var voiceProbeDidPrewarm = false
    /// 本次触摸自预热以来是否已正式开始语音输入（`beginVoiceInput` 置真）。
    private var voiceInputCommittedSincePrewarm = false
    private var frameAnimator: UIViewPropertyAnimator?

    /// 最近一次测量的文字区宽度与对应的文字高度；草稿变化时作废。
    /// 宿主每次布局都会问一遍展开高度，缓存让文字排版测量只在宽度或草稿真正变化时发生。
    private var textHeightCache: (width: CGFloat, height: CGFloat)?

    // MARK: - Delegate

    public weak var delegate: AppAgentInputBarDelegate?

    // MARK: - Subviews

    public let menuButton = AppAgentMenuButton()
    public let inputAreaContainer = UIView()
    public let textView = AppAgentTextView()
    public let voiceInputHoldButton = UIButton(type: .custom)
    public let inputSourceButton = UIButton(type: .system)
    public let plusButton = UIButton(type: .system)
    /// 右侧动作槽：与 plusButton 同一块矩形，按 `trailingAction` 显示发送或停止。
    public let trailingActionButton = UIButton(type: .custom)
    /// 发送 / 停止的图标单独挂一层 image view，不用按钮自己的 image。
    ///
    /// 按钮自带图标会被 UIKit 在按下时整体调暗，而关掉这个行为的 `adjustsImageWhenHighlighted`
    /// 从 iOS / Mac Catalyst 15 起已废弃（官方口径是改用 `UIButton.Configuration` +
    /// `configurationUpdateHandler`）。这一格是自绘实心圆 + `layer` 背景色，交给 configuration
    /// 等于把背景绘制权让给系统、再补一层 background configuration 还原外观，收益是负的。
    /// 图标既然不属于按钮自身的渲染内容，highlight 就与它无关：不变暗，也不依赖废弃 API。
    private let trailingActionIcon = UIImageView()
    /// 选好的图片 / 文件，排在输入栏最上面一行。
    let attachmentStrip = AppAgentAttachmentStripView()
    /// 加号面板，第一次展开时才创建；展开时挂在 `textView.inputView` 上顶替键盘。
    private var attachmentPanel: AppAgentAttachmentPanelView?

    /// 面板展开时点输入框切回键盘（同微信）：已是第一响应者时点文字区不会再走 begin editing。
    private lazy var attachmentPanelDismissTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleAttachmentPanelDismissTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    private lazy var inputBarPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleInputBarPan(_:)))
        pan.cancelsTouchesInView = true
        pan.delegate = self
        return pan
    }()

    private lazy var voiceModePressGesture: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleVoiceModePress(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = true
        press.delegate = self
        return press
    }()

    private lazy var keyboardModeLongPressGesture: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleKeyboardModeLongPress(_:)))
        press.minimumPressDuration = 0.2
        press.cancelsTouchesInView = true
        press.delegate = self
        return press
    }()

    /// 触摸预热探针：touchDown 就通知宿主提前预热语音（面板不展示），短按未成立时通知取消预热。
    private lazy var voiceInputTouchProbe: AppAgentTouchProbeGestureRecognizer = {
        let probe = AppAgentTouchProbeGestureRecognizer()
        probe.cancelsTouchesInView = false
        probe.delaysTouchesBegan = false
        probe.delaysTouchesEnded = false
        probe.delegate = self
        probe.onTouchDown = { [weak self] touch in self?.handleVoiceProbeTouchDown(touch) }
        probe.onTouchUp = { [weak self] in self?.handleVoiceProbeTouchUp() }
        return probe
    }()

    // MARK: - Public API

    public var text: String {
        get {
            textView.text
        }
        set {
            textView.text = newValue
            draftDidChange()
        }
    }

    public private(set) var inputSource: AppAgentInputBarInputSource = .keyboard

    /// 当前会话是否还在跑 agent loop。由宿主（`AppAgentViewController`）在运行状态变化时写入；
    /// inputBar 自己不猜，只据此决定右侧槽显示加号还是停止。
    public private(set) var isRunActive = false

    /// 右侧动作槽当前形态：草稿（文字或附件）优先，其次运行中，否则加号。
    public var trailingAction: AppAgentInputBarTrailingAction {
        if hasDraftText || !attachments.isEmpty {
            return .send
        }
        return isRunActive ? .stop : .plus
    }

    /// 待发送的图片 / 文件，按选择顺序。发送后由宿主 `removeAllAttachments()` 清空。
    public private(set) var attachments: [AIAgentMessage.Attachment] = []

    /// 还能再选几张图。
    public var remainingImageAttachmentSlots: Int {
        let imageCount = attachments.filter { attachment in
            attachment.kind == .image
        }.count
        return max(0, Self.maximumImageAttachmentCount - imageCount)
    }

    /// 加号面板当前是否顶替键盘显示着。
    public var isShowingAttachmentPanel: Bool {
        attachmentPanel != nil && textView.inputView === attachmentPanel
    }

    /// 输入框里是否有可发送的内容（纯空白不算）。
    private var hasDraftText: Bool {
        !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func setRunActive(_ active: Bool) {
        guard isRunActive != active else { return }
        isRunActive = active
        updateTrailingAction()
    }

    public var isCollapsed: Bool {
        bounds.width <= AppAgentInputBarMetrics.collapsedMinWidth + 0.5
    }

    public func clearText() {
        textView.text = ""
        draftDidChange()
    }

    /// 放进待发送附件。图片超过 `maximumImageAttachmentCount` 的部分丢弃；
    /// 文件一次只带一个，再选一个就替换掉旧的。
    public func addAttachments(_ incoming: [AIAgentMessage.Attachment]) {
        var result = attachments
        for attachment in incoming {
            switch attachment.kind {
            case .image:
                let imageCount = result.filter { item in
                    item.kind == .image
                }.count
                guard imageCount < Self.maximumImageAttachmentCount else {
                    continue
                }
                result.append(attachment)
            case .file:
                result.removeAll { item in
                    item.kind == .file
                }
                result.append(attachment)
            }
        }
        discardAttachments(replacedBy: result)
        setAttachments(result)
    }

    /// 用户移除一个待发送附件；文件附件会通过代理通知宿主删掉暂存文件。
    public func removeAttachment(id: String) {
        let remaining = attachments.filter { item in
            item.id != id
        }
        discardAttachments(replacedBy: remaining)
        setAttachments(remaining)
    }

    /// 发送后清空。附件已经随消息发出，暂存文件要留着给后续轮次读，所以不通知丢弃。
    public func removeAllAttachments() {
        setAttachments([])
    }

    private func discardAttachments(replacedBy remaining: [AIAgentMessage.Attachment]) {
        let keptIDs = Set(remaining.map(\.id))
        let dropped = attachments.filter { item in
            !keptIDs.contains(item.id)
        }
        guard !dropped.isEmpty else {
            return
        }
        delegate?.inputBar(self, didDiscardAttachments: dropped)
    }

    private func setAttachments(_ value: [AIAgentMessage.Attachment]) {
        guard value.map(\.id) != attachments.map(\.id) else {
            return
        }
        attachments = value
        attachmentStrip.showsAddButton = remainingImageAttachmentSlots > 0
        attachmentStrip.setAttachments(value)
        updateTrailingAction()
        // 附件条出现 / 消失时 bar 高度变了，先按当前尺寸摆一遍，再让宿主按新高度重排整条 bar。
        if bounds.width > 0, bounds.height > 0 {
            layoutContent(for: bounds.size)
        }
        notifyExpandedHeightChangeIfNeeded()
    }

    /// 展开态在给定宽度下应有的高度：文字放得进与按钮等高的输入区时是 `barHeight`；
    /// 放不下时 = 文字高度 + 上下各 8，最多到最大可见行数。语音模式或输入区被压没时恒为单行。
    /// 有附件时在最上面再加一行缩略图（单行草稿也因此长高）。
    public func expandedHeight(forWidth width: CGFloat) -> CGFloat {
        let barHeight = AppAgentInputBarMetrics.barHeight
        let areaWidth = inputAreaWidth(forBarWidth: width)
        guard areaWidth > 0 else {
            return barHeight
        }
        let attachmentHeight = attachments.isEmpty ? 0 : Self.attachmentRegionHeight
        guard inputSource == .keyboard else {
            return barHeight + attachmentHeight
        }
        let textHeight = textHeight(forWidth: areaWidth)
        return max(barHeight, textHeight + Self.inputAreaVerticalPadding * 2) + attachmentHeight
    }

    /// 当前 bar 高度下附件条实际占的高度。resize 收窄时高度会线性回落到单行，附件区跟着让出，
    /// 输入区永远保有至少一行。
    private func attachmentRegionHeight(forBarHeight height: CGFloat) -> CGFloat {
        guard !attachments.isEmpty else {
            return 0
        }
        return min(Self.attachmentRegionHeight, max(0, height - AppAgentInputBarMetrics.barHeight))
    }

    /// 文字在给定宽度下排版所需的高度：至少一行，最多到最大可见行数（之后框内滚动）。
    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        if let cache = textHeightCache, abs(cache.width - width) < 0.5 {
            return cache.height
        }
        let height = min(textView.fittingHeight(forWidth: width), textView.maximumHeight)
        textHeightCache = (width, height)
        return height
    }

    public func setInputEnabled(_ enabled: Bool) {
        textView.isEditable = enabled
        menuButton.isEnabled = enabled
        inputSourceButton.isEnabled = enabled
        voiceInputHoldButton.isEnabled = enabled
        plusButton.isEnabled = enabled
        trailingActionButton.isEnabled = enabled
        updateControlInteractionState()
    }

    public func setInputSource(_ source: AppAgentInputBarInputSource, animated: Bool) {
        setInputSource(source, animated: animated, focusKeyboard: false)
    }

    public func setInputBarFrame(_ frame: CGRect, animation: AppAgentInputBarFrameAnimation) {
        stopFrameAnimationAtCurrentFrame()
        guard !self.frame.isApproximatelyEqual(to: frame) else { return }

        let sizeWillChange = !bounds.size.isApproximatelyEqual(to: frame.size)
        let apply = { [weak self] in
            guard let self else { return }
            self.frame = frame
            if sizeWillChange {
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }

        if let animator = animation.makeAnimator(animations: apply) {
            startFrameAnimation(animator)
        } else {
            apply()
        }
    }

    /// 开始并持有 frame animator，使新动画或新手势可以从当前视觉状态接管。
    private func startFrameAnimation(_ animator: UIViewPropertyAnimator) {
        let identifier = ObjectIdentifier(animator)
        frameAnimator = animator
        animator.addCompletion { [weak self] _ in
            guard let self,
                  let currentAnimator = self.frameAnimator,
                  ObjectIdentifier(currentAnimator) == identifier else { return }
            self.frameAnimator = nil
        }
        animator.startAnimation()
    }

    /// 停止进行中的 frame 动画，并把 presentation frame 同步回真实 frame，避免交互接管时跳变。
    private func stopFrameAnimationAtCurrentFrame() {
        guard let animator = frameAnimator else { return }
        let presentationFrame = layer.presentation()?.frame
        frameAnimator = nil
        animator.stopAnimation(true)
        layer.removeAllAnimations()

        guard let presentationFrame else { return }
        frame = presentationFrame
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private static func systemSymbolImage(
        primary: String,
        fallbacks: [String] = [],
        pointSize: CGFloat = symbolIconPointSize,
        weight: UIImage.SymbolWeight = .regular
    ) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        for name in [primary] + fallbacks {
            if let image = UIImage(systemName: name, withConfiguration: config) {
                return image
            }
        }
        return nil
    }

    private func setup() {
        layer.cornerRadius = AppAgentInputBarMetrics.expandedCornerRadius
        layer.masksToBounds = false
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.borderWidth = 1

        updatePlusButtonIcon()
        #if targetEnvironment(macCatalyst)
        // Mac 上没有软键盘，`inputView` 顶替键盘这条路不成立，加号直接弹系统菜单。
        plusButton.menu = makeAttachmentMenu()
        plusButton.showsMenuAsPrimaryAction = true
        #else
        plusButton.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)
        #endif

        attachmentStrip.onRemove = { [weak self] id in
            self?.removeAttachment(id: id)
        }
        // 缩略图右边的加号：直接再选图，不再绕回面板。
        attachmentStrip.onAdd = { [weak self] in
            self?.selectAttachmentSource(.photoLibrary)
        }
        attachmentStrip.isHidden = true

        // 发送 / 停止共用这一个实心圆按钮：圆比加号里的圆再大一圈（半径 +4pt），居中在加号那一格里，
        // 点按范围靠 BOUIKit 外扩回整格 40pt（约定：命中区用 bo_，不手写 hitTest）。
        trailingActionButton.layer.cornerRadius = Self.trailingActionCircleSide / 2
        trailingActionButton.layer.masksToBounds = true
        // 图标居中铺满整圆：`contentMode = .center` 让符号按原始点数居中，不随圆的尺寸缩放；
        // 关掉交互，点按事件照旧落在按钮本体上。
        trailingActionIcon.contentMode = .center
        trailingActionIcon.isUserInteractionEnabled = false
        trailingActionButton.addSubview(trailingActionIcon)
        trailingActionButton.bo_hitAreaOutsets = UIEdgeInsets(
            top: Self.trailingActionHitOutset,
            left: Self.trailingActionHitOutset,
            bottom: Self.trailingActionHitOutset,
            right: Self.trailingActionHitOutset
        )
        trailingActionButton.addTarget(self, action: #selector(trailingActionTapped), for: .touchUpInside)

        inputSourceButton.addTarget(self, action: #selector(inputSourceTapped), for: .touchUpInside)

        inputAreaContainer.clipsToBounds = true

        textView.font = .systemFont(ofSize: 15)
        textView.returnKeyType = .send
        // 草稿变化走 `textViewDidChange`（用户输入）与 `text` / `clearText`（程序化）两条路。
        textView.delegate = self
        textView.addGestureRecognizer(attachmentPanelDismissTap)

        voiceInputHoldButton.setTitle("按住说话", for: .normal)
        voiceInputHoldButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        voiceInputHoldButton.titleLabel?.textAlignment = .center
        voiceInputHoldButton.contentHorizontalAlignment = .center
        voiceInputHoldButton.layer.cornerRadius = Self.inputAreaMinimumHeight / 2
        voiceInputHoldButton.layer.masksToBounds = true
        voiceInputHoldButton.accessibilityLabel = "按住说话"
        voiceInputHoldButton.addGestureRecognizer(voiceModePressGesture)

        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)

        addSubview(plusButton)
        addSubview(inputSourceButton)
        addSubview(inputAreaContainer)
        inputAreaContainer.addSubview(textView)
        inputAreaContainer.addSubview(voiceInputHoldButton)
        addSubview(menuButton)
        addSubview(trailingActionButton)
        addSubview(attachmentStrip)
        addGestureRecognizer(inputBarPan)
        // 键盘模式长按需要同时覆盖输入区域和输入源按钮，因此由 inputBar 统一接收，再由代理过滤起点。
        addGestureRecognizer(keyboardModeLongPressGesture)
        addGestureRecognizer(voiceInputTouchProbe)

        applyAppearance()
        updateInputSourceAppearance(animated: false, notifyDelegate: false)
        updateTrailingAction()
        updateControlInteractionState()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func applyAppearance() {
        backgroundColor = AppAgentAppearance.inputBarBackground
        layer.borderColor = AppAgentAppearance.inputBarBorder.resolvedColor(with: traitCollection).cgColor
        layer.shadowColor = AppAgentAppearance.inputBarShadow.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = AppAgentAppearance.inputBarShadowOpacity(for: traitCollection)

        textView.textColor = AppAgentAppearance.primaryText
        textView.tintColor = AppAgentAppearance.accent
        updatePlaceholder()
        plusButton.tintColor = AppAgentAppearance.icon
        inputSourceButton.tintColor = AppAgentAppearance.icon
        trailingActionButton.backgroundColor = AppAgentAppearance.actionButtonBackground
        trailingActionIcon.tintColor = AppAgentAppearance.actionButtonIcon
        voiceInputHoldButton.setTitleColor(AppAgentAppearance.primaryText, for: .normal)
        setVoiceInputHolding(isHoldingVoiceInput)
        menuButton.setNeedsDisplay()
    }

    // MARK: - Layout

    /// 输入区的实际命中区域：横向仍是输入区本身，竖直方向扩到整条 bar 的白色背景那么高。
    /// 「点击输入框弹键盘」和「上滑唤起键盘」都以此为准，因此 bar 内输入区上下的空白
    /// 也能命中，不用精确戳中 36pt 高的胶囊。
    /// 输入区隐藏或随 bar 收窄淡出时返回 `.null`，表示当前没有可命中的输入区。
    public var extendedInputAreaHitRect: CGRect {
        guard !inputAreaContainer.isHidden,
              inputAreaContainer.alpha > 0.01,
              inputAreaContainer.frame.width > 0,
              bounds.height > 0 else { return .null }
        return CGRect(
            x: inputAreaContainer.frame.minX,
            y: bounds.minY,
            width: inputAreaContainer.frame.width,
            height: bounds.height
        )
    }

    /// 把落在扩大后输入区、但原本只命中 bar 背景的触点，转交给输入区内的真实控件。
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // 只接管「打在 bar 白色背景上」的触点，menuButton / plusButton / inputSourceButton
        // 等控件的命中一律原样返回。
        // 输入区自身（文字区上下的留白）同样转交，点留白也能弹键盘。
        guard hit === self || hit === inputAreaContainer, isUserInteractionEnabled else {
            return hit
        }

        let extended = extendedInputAreaHitRect
        guard !extended.isNull, extended.contains(point) else { return hit }

        // 触点在输入区上下的空白里，先把 y 夹进可交互控件的范围再做一次命中：
        // 键盘模式夹进文字区，语音模式夹进输入区（「按住说话」占满底部那一行）。
        let target = inputSource == .keyboard ? textView.frame : inputAreaContainer.bounds
        var local = convert(point, to: inputAreaContainer)
        local.y = min(max(target.minY, local.y), max(target.minY, target.maxY - 0.5))
        return inputAreaContainer.hitTest(local, with: event) ?? hit
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let textHeight = textHeight(forWidth: inputAreaWidth(forBarWidth: size.width))
        guard size != lastLaidOutSize || abs(textHeight - lastLaidOutTextHeight) > 0.5 else {
            return
        }
        lastLaidOutSize = size
        lastLaidOutTextHeight = textHeight

        layoutContent(for: size)
        updateCapsuleCornerRadius(for: size)
        updateControlInteractionState()
    }

    /// 输入区在给定 bar 宽度下的宽度：两侧按钮之外的剩余；语音按钮让位（有草稿）时向右扩到动作槽前。
    /// bar 窄到放不下输入区时为 0。布局与展开高度测量共用这一份，保证测量宽度就是实际排版宽度。
    private func inputAreaWidth(forBarWidth barWidth: CGFloat) -> CGFloat {
        let width = max(barWidth, AppAgentInputBarMetrics.collapsedMinWidth)
        guard width >= Self.normalZeroInputAreaWidth else {
            return 0
        }
        let sourceSlotWidth = inputSourceButton.isHidden
            ? AppAgentInputBarMetrics.buttonSize + AppAgentInputBarMetrics.innerPadding
            : 0
        return width - Self.normalZeroInputAreaWidth + sourceSlotWidth
    }

    private func layoutContent(for size: CGSize) {
        let width = max(size.width, AppAgentInputBarMetrics.collapsedMinWidth)
        let barHeight = AppAgentInputBarMetrics.barHeight
        let innerPadding = AppAgentInputBarMetrics.innerPadding
        let buttonSize = AppAgentInputBarMetrics.buttonSize
        let minimumAreaHeight = Self.inputAreaMinimumHeight
        // 多行时 bar 向上长高：按钮留在底部那一排，与最后一行文字对齐；输入区上下与 bar 始终相距 8。
        let bottomRowY = max(0, size.height - barHeight)
        let buttonY = bottomRowY + (barHeight - buttonSize) / 2
        // 附件条在最上面一行，输入区与按钮排在它下面的剩余高度里。
        let attachmentHeight = attachmentRegionHeight(forBarHeight: size.height)
        let contentHeight = size.height - attachmentHeight
        let inputAreaHeight = max(minimumAreaHeight, contentHeight - Self.inputAreaVerticalPadding * 2)

        let menuX = innerPadding
        let inputAreaX: CGFloat
        let inputAreaWidth = inputAreaWidth(forBarWidth: width)
        let inputSourceX: CGFloat
        let plusX: CGFloat

        if width >= Self.normalZeroInputAreaWidth {
            inputAreaX = menuX + buttonSize + innerPadding
            plusX = width - innerPadding - buttonSize
            inputSourceX = plusX - innerPadding - buttonSize
        } else if width >= Self.compressedTextGapWidth {
            let compressedMenuTextGap = width - Self.compressedTextGapWidth
            inputAreaX = menuX + buttonSize + compressedMenuTextGap
            inputSourceX = inputAreaX + innerPadding
            plusX = inputSourceX + buttonSize + innerPadding
        } else if width >= Self.collapsedPlusVisibleWidth {
            inputAreaX = menuX + buttonSize
            inputSourceX = width - buttonSize * 2 - innerPadding * 2
            plusX = width - buttonSize - innerPadding
        } else {
            inputAreaX = menuX + buttonSize
            inputSourceX = menuX
            plusX = width - buttonSize - innerPadding
        }

        inputAreaContainer.frame = CGRect(
            x: inputAreaX,
            y: attachmentHeight + (contentHeight - inputAreaHeight) / 2,
            width: inputAreaWidth,
            height: inputAreaHeight
        )
        attachmentStrip.isHidden = attachmentHeight < 1
        // 附件条横跨整条 bar：左边与最左侧的圆形按钮对齐，右边留同样的内边距，不必让出按钮那一列。
        attachmentStrip.frame = CGRect(
            x: menuX,
            y: Self.attachmentStripTopPadding,
            width: max(0, width - innerPadding - menuX),
            height: AppAgentAttachmentThumbnailView.removableSize.height
        )
        // 文字区贴合文字本身的高度并在输入区里垂直居中；文字区外的空白不属于文字区，
        // 滚动时不会从边上露出半行。
        let textHeight = min(textHeight(forWidth: inputAreaWidth), inputAreaHeight)
        textView.frame = CGRect(
            x: 0,
            y: (inputAreaHeight - textHeight) / 2,
            width: inputAreaWidth,
            height: textHeight
        )
        voiceInputHoldButton.frame = CGRect(
            x: 0,
            y: inputAreaHeight - minimumAreaHeight,
            width: inputAreaWidth,
            height: minimumAreaHeight
        )
        alignTextViewContentAfterResize()

        plusButton.frame = CGRect(x: plusX, y: buttonY, width: buttonSize, height: buttonSize)
        inputSourceButton.frame = CGRect(x: inputSourceX, y: buttonY, width: buttonSize, height: buttonSize)
        menuButton.frame = CGRect(x: menuX, y: buttonY, width: buttonSize, height: buttonSize)

        // inputBar 小于最小展开宽度后，输入区会从 80pt 逐步压缩到 0；alpha 同步由 1 线性过渡到 0。
        inputAreaContainer.alpha = AppAgentGeometry.clamp(
            (width - Self.normalZeroInputAreaWidth)
                / (AppAgentInputBarMetrics.minimumExpandedWidth - Self.normalZeroInputAreaWidth),
            0,
            1
        )
        attachmentStrip.alpha = inputAreaContainer.alpha
        inputSourceButton.alpha = AppAgentGeometry.clamp(
            (width - Self.collapsedPlusVisibleWidth)
                / (Self.compressedTextGapWidth - Self.collapsedPlusVisibleWidth),
            0,
            1
        )
        plusButton.alpha = AppAgentGeometry.clamp(
            (width - AppAgentInputBarMetrics.collapsedMinWidth)
                / (Self.collapsedPlusVisibleWidth - AppAgentInputBarMetrics.collapsedMinWidth),
            0,
            1
        )
        // 发送 / 停止占的就是加号那一格，几何与淡出进度跟着它走。
        applyTrailingActionGeometry()
    }

    /// 输入框尺寸变了之后校正滚动位置：放得下全部文字就回到顶部（避免长高后首行被滚出去），
    /// 放不下且正在编辑就把光标滚进可见区。
    private func alignTextViewContentAfterResize() {
        textView.layoutIfNeeded()
        if !textView.isContentScrollable {
            textView.contentOffset = .zero
        } else if textView.isFirstResponder {
            textView.scrollRangeToVisible(textView.selectedRange)
        }
    }

    /// 右侧动作槽与加号共用同一格和同一条淡出进度：布局改了和形态改了都要同步一次。
    /// 圆是 32pt，居中摆在加号那 40pt 的格子里；剩下的 4pt 边距由命中外扩补回点按范围。
    private func applyTrailingActionGeometry() {
        let side = Self.trailingActionCircleSide
        trailingActionButton.frame = CGRect(
            x: plusButton.frame.midX - side / 2,
            y: plusButton.frame.midY - side / 2,
            width: side,
            height: side
        )
        trailingActionButton.alpha = plusButton.alpha
        // 图标跟着圆走：圆的 frame 每次都是重算的，图标直接贴满它，居中由 contentMode 负责。
        trailingActionIcon.frame = trailingActionButton.bounds
    }

    private func updateCapsuleCornerRadius(for size: CGSize) {
        let collapsedMinWidth = AppAgentInputBarMetrics.collapsedMinWidth
        let expandedCornerRadius = AppAgentInputBarMetrics.expandedCornerRadius
        let width = max(size.width, collapsedMinWidth)
        let expandedTravel = AppAgentInputBarMetrics.minimumExpandedWidth - collapsedMinWidth
        let expandedProgress = AppAgentGeometry.clamp((width - collapsedMinWidth) / expandedTravel, 0, 1)
        let cornerRadiusCollapseRatio = 1 - expandedProgress
        let collapsedRadius = min(width, size.height) / 2
        let radius = expandedCornerRadius
            + (collapsedRadius - expandedCornerRadius) * cornerRadiusCollapseRatio

        if abs(layer.cornerRadius - radius) > 0.25 {
            layer.cornerRadius = radius
        }
    }

    /// 根据收起状态、输入源和控件启用状态更新交互；不依赖 alpha 等视觉表现参数。
    private func updateControlInteractionState() {
        let allowsExpandedControls = !isCollapsed
        textView.isUserInteractionEnabled = textView.isEditable
            && allowsExpandedControls
            && inputSource == .keyboard
        voiceInputHoldButton.isUserInteractionEnabled = voiceInputHoldButton.isEnabled
            && allowsExpandedControls
            && inputSource == .voice
        inputSourceButton.isUserInteractionEnabled = inputSourceButton.isEnabled
            && allowsExpandedControls
        plusButton.isUserInteractionEnabled = plusButton.isEnabled
            && allowsExpandedControls
        trailingActionButton.isUserInteractionEnabled = trailingActionButton.isEnabled
            && allowsExpandedControls
    }

    /// 按草稿 / 运行状态切换右侧槽：加号、发送或停止。
    ///
    /// 有草稿时语音按钮一起隐藏（此时长按语音本来也被 `canBeginVoiceInput` 挡着），
    /// loop 运行中输入框为空则只替换加号，语音照常可用。
    private func updateTrailingAction() {
        let action = trailingAction
        let showsPlus = action == .plus
        plusButton.isHidden = !showsPlus
        trailingActionButton.isHidden = showsPlus
        let hidesInputSource = action == .send
        if inputSourceButton.isHidden != hidesInputSource {
            inputSourceButton.isHidden = hidesInputSource
            // 语音按钮让出的那一格归输入区：只在显隐切换时重排一次，不随每次按键布局。
            if bounds.width > 0, bounds.height > 0 {
                layoutContent(for: bounds.size)
            }
        }

        switch action {
        case .plus:
            break
        case .send:
            trailingActionIcon.image = Self.sendIcon
            trailingActionButton.accessibilityLabel = "发送"
        case .stop:
            trailingActionIcon.image = Self.stopIcon
            trailingActionButton.accessibilityLabel = "停止"
        }

        applyTrailingActionGeometry()
        updateControlInteractionState()
    }

    private func setInputSource(
        _ source: AppAgentInputBarInputSource,
        animated: Bool,
        focusKeyboard: Bool
    ) {
        guard inputSource != source else {
            updateInputSourceAppearance(animated: animated, notifyDelegate: false)
            if focusKeyboard, source == .keyboard {
                textView.becomeFirstResponder()
            }
            return
        }

        if inputSource == .voice {
            finishActiveVoiceInput(gestureRecognizer: nil)
        }

        inputSource = source
        if source == .voice {
            textView.resignFirstResponder()
        }
        updateInputSourceAppearance(animated: animated, notifyDelegate: true)
        // 语音模式恒为单行，切回键盘再按草稿行数长高。
        notifyExpandedHeightChangeIfNeeded()
        if focusKeyboard, source == .keyboard {
            textView.becomeFirstResponder()
        }
    }

    private func updateInputSourceAppearance(
        animated: Bool,
        notifyDelegate: Bool
    ) {
        let keyboardMode = inputSource == .keyboard
        let sourceIcon = keyboardMode
            ? Self.systemSymbolImage(primary: "microphone.circle", fallbacks: ["microphone"])
            : Self.systemSymbolImage(
                primary: "keyboard.circle",
                fallbacks: ["keyboard"],
                pointSize: Self.keyboardIconPointSize
            )
        inputSourceButton.setImage(sourceIcon, for: .normal)
        inputSourceButton.accessibilityLabel = keyboardMode ? "切换到语音输入" : "切换到键盘输入"

        textView.isHidden = !keyboardMode
        textView.alpha = 1
        voiceInputHoldButton.isHidden = keyboardMode
        voiceInputHoldButton.alpha = 1
        inputAreaContainer.bringSubviewToFront(voiceInputHoldButton)
        updatePlaceholder()
        updateControlInteractionState()

        if notifyDelegate {
            delegate?.inputBar(self, didChangeInputSource: inputSource)
        }
    }

    private func updatePlaceholder() {
        let text = textView.isFirstResponder
            ? Self.activeTextInputPlaceholder
            : Self.inactiveTextInputPlaceholder
        textView.placeholder = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: AppAgentAppearance.placeholderText,
                .font: textView.font ?? .systemFont(ofSize: 15)
            ]
        )
    }

    /// 草稿变了（用户输入或程序化赋值）：刷新右侧槽，并重排文字区；行数变化时再通知宿主重排高度。
    private func draftDidChange() {
        textHeightCache = nil
        updateTrailingAction()
        // 文字在 40pt 输入区内换行时 bar 高度不变，但文字区 frame 要跟着内容长高，不能等宿主改尺寸。
        setNeedsLayout()
        layoutIfNeeded()
        notifyExpandedHeightChangeIfNeeded()
    }

    /// 当前宽度下的展开高度与实际高度不一致才通知宿主；收起态与胶囊等高，不参与。
    private func notifyExpandedHeightChangeIfNeeded() {
        guard !isCollapsed, bounds.width > 0 else {
            return
        }
        guard abs(expandedHeight(forWidth: bounds.width) - bounds.height) > 0.5 else {
            return
        }
        delegate?.inputBarDidChangeExpandedHeight(self)
    }

    private func setVoiceInputHolding(_ holding: Bool) {
        voiceInputHoldButton.backgroundColor = holding
            ? AppAgentAppearance.voicePressedBackground
            : .clear
        voiceInputHoldButton.setTitleColor(AppAgentAppearance.primaryText, for: .normal)
    }

    // MARK: - Actions

    @objc private func menuTapped() {
        if isCollapsed {
            delegate?.inputBarDidRequestExpand(self)
        } else {
            delegate?.inputBarDidRequestCollapse(self)
        }
    }

    @objc private func inputSourceTapped() {
        switch inputSource {
        case .keyboard:
            setInputSource(.voice, animated: true, focusKeyboard: false)
        case .voice:
            setInputSource(.keyboard, animated: true, focusKeyboard: true)
        }
    }

    @objc private func plusTapped() {
        toggleAttachmentPanel()
        delegate?.inputBarDidTapPlus(self)
    }

    // MARK: - Attachment panel

    /// 加号：面板没展开就展开（顶替键盘），图标随之变成叉；点叉收起面板，键盘也不弹。
    public func toggleAttachmentPanel() {
        if isShowingAttachmentPanel {
            hideAttachmentPanel(showKeyboard: false)
            textView.resignFirstResponder()
        } else {
            showAttachmentPanel()
        }
    }

    /// 加号 / 叉两种形态只看面板是否展开；`inputView` 每次变化后都要同步一次。
    private func updatePlusButtonIcon() {
        let showsClose = isShowingAttachmentPanel
        plusButton.setImage(
            showsClose
                ? Self.systemSymbolImage(primary: "xmark.circle", fallbacks: ["xmark"])
                : Self.systemSymbolImage(primary: "plus.circle", fallbacks: ["plus"]),
            for: .normal
        )
        plusButton.accessibilityLabel = showsClose ? "收起" : "更多"
    }

    public func showAttachmentPanel() {
        guard textView.isEditable else {
            return
        }
        if inputSource == .voice {
            setInputSource(.keyboard, animated: true, focusKeyboard: false)
        }
        let panel = attachmentPanel ?? makeAttachmentPanel()
        attachmentPanel = panel
        textView.inputView = panel
        updatePlusButtonIcon()
        if textView.isFirstResponder {
            textView.reloadInputViews()
        } else {
            textView.becomeFirstResponder()
        }
    }

    /// 收起面板。`showKeyboard` 为真且输入框仍在编辑时换回系统键盘，否则只是摘掉面板。
    public func hideAttachmentPanel(showKeyboard: Bool) {
        guard textView.inputView != nil else {
            return
        }
        textView.inputView = nil
        updatePlusButtonIcon()
        if showKeyboard, textView.isFirstResponder {
            textView.reloadInputViews()
        }
    }

    private func makeAttachmentPanel() -> AppAgentAttachmentPanelView {
        let panel = AppAgentAttachmentPanelView(sources: AppAgentInputBarAttachmentSource.allCases)
        panel.onSelect = { [weak self] source in
            self?.selectAttachmentSource(source)
        }
        return panel
    }

    private func makeAttachmentMenu() -> UIMenu {
        let actions = AppAgentInputBarAttachmentSource.allCases.map { source in
            UIAction(title: source.title, image: UIImage(systemName: source.symbolName)) { [weak self] _ in
                self?.selectAttachmentSource(source)
            }
        }
        return UIMenu(children: actions)
    }

    /// 选了面板里的一项：先收起面板和输入焦点，系统选择器才能干净地盖上来。
    private func selectAttachmentSource(_ source: AppAgentInputBarAttachmentSource) {
        hideAttachmentPanel(showKeyboard: false)
        textView.resignFirstResponder()
        delegate?.inputBar(self, didSelectAttachmentSource: source)
    }

    @objc private func handleAttachmentPanelDismissTap() {
        guard isShowingAttachmentPanel else {
            return
        }
        hideAttachmentPanel(showKeyboard: true)
    }

    /// 右侧圆形按钮：形态决定语义，别在外部再判一遍草稿。
    @objc private func trailingActionTapped() {
        switch trailingAction {
        case .plus:
            plusTapped()
        case .send:
            let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !attachments.isEmpty else {
                return
            }
            delegate?.inputBar(self, didSendText: text)
        case .stop:
            delegate?.inputBarDidTapStop(self)
        }
    }

    @objc private func handleVoiceModePress(_ gr: UILongPressGestureRecognizer) {
        handleVoiceInputGesture(gr, source: .voiceModePress)
    }

    @objc private func handleKeyboardModeLongPress(_ gr: UILongPressGestureRecognizer) {
        handleVoiceInputGesture(gr, source: .keyboardModeLongPress)
    }

    /// 探针 touchDown：仅在「键盘模式长按会触发语音」的同等条件下预热（#2/#3）；
    /// 语音模式按下(#1)是 0ms 长按、touchDown 即 began，无需预热。
    private func handleVoiceProbeTouchDown(_ touch: UITouch) {
        voiceProbeDidPrewarm = false
        voiceInputCommittedSincePrewarm = false
        guard canBeginVoiceInput(source: .keyboardModeLongPress) else { return }
        let insideInputArea = isTouch(touch, insideViewHierarchyOf: inputAreaContainer)
        let insideSourceButton = isTouch(touch, insideViewHierarchyOf: inputSourceButton)
            && inputSourceButton.isEnabled
            && inputSourceButton.isUserInteractionEnabled
        guard insideInputArea || insideSourceButton else { return }
        voiceProbeDidPrewarm = true
        lastVoiceInputHostLocation = touch.location(in: superview ?? self)
        sendVoiceGestureEvent(source: .keyboardModeLongPress, phase: .prewarm)
    }

    /// 探针 touchUp：若预热过但长按没成立（短按），通知取消预热；否则交给正式手势收尾。
    private func handleVoiceProbeTouchUp() {
        guard voiceProbeDidPrewarm else { return }
        voiceProbeDidPrewarm = false
        guard !voiceInputCommittedSincePrewarm else { return }
        sendVoiceGestureEvent(source: .keyboardModeLongPress, phase: .abortPrewarm)
    }

    private func handleVoiceInputGesture(
        _ gr: UILongPressGestureRecognizer,
        source: AppAgentInputBarVoiceInputSource
    ) {
        switch gr.state {
        case .began:
            beginVoiceInput(source: source, gestureRecognizer: gr)
        case .changed:
            guard isHoldingVoiceInput, activeVoiceInputSource == source else { return }
            lastVoiceInputHostLocation = hostLocation(of: gr)
            sendVoiceGestureEvent(source: source, phase: .moved)
        case .ended:
            finishActiveVoiceInput(gestureRecognizer: gr)
        case .cancelled, .failed:
            finishActiveVoiceInput(gestureRecognizer: gr, forcesCancel: true)
        default:
            break
        }
    }

    private func beginVoiceInput(
        source: AppAgentInputBarVoiceInputSource,
        gestureRecognizer: UILongPressGestureRecognizer
    ) {
        guard canBeginVoiceInput(source: source) else { return }

        isHoldingVoiceInput = true
        voiceInputCommittedSincePrewarm = true
        activeVoiceInputSource = source
        lastVoiceInputHostLocation = hostLocation(of: gestureRecognizer)
        setVoiceInputHolding(source == .voiceModePress)

        sendVoiceGestureEvent(source: source, phase: .began)
    }

    /// 结束当前语音输入手势。`gestureRecognizer` 为 nil 表示内部主动打断（如切换输入源），一律按取消上报。
    private func finishActiveVoiceInput(
        gestureRecognizer: UILongPressGestureRecognizer?,
        forcesCancel: Bool = false
    ) {
        guard isHoldingVoiceInput,
              let source = activeVoiceInputSource else { return }

        if let gestureRecognizer = gestureRecognizer {
            lastVoiceInputHostLocation = hostLocation(of: gestureRecognizer)
        }
        let phase: AppAgentInputBarVoiceGestureEvent.Phase =
            (gestureRecognizer == nil || forcesCancel) ? .cancelled : .ended
        isHoldingVoiceInput = false
        activeVoiceInputSource = nil
        setVoiceInputHolding(false)

        sendVoiceGestureEvent(source: source, phase: phase)
    }

    private func sendVoiceGestureEvent(
        source: AppAgentInputBarVoiceInputSource,
        phase: AppAgentInputBarVoiceGestureEvent.Phase
    ) {
        delegate?.inputBar(self, didReceiveVoiceInputGesture: AppAgentInputBarVoiceGestureEvent(
            source: source,
            phase: phase,
            locationInHost: lastVoiceInputHostLocation
        ))
    }

    /// 手指在宿主视图坐标系中的位置；尚未挂载时退化为自身坐标。
    private func hostLocation(of gestureRecognizer: UIGestureRecognizer) -> CGPoint {
        gestureRecognizer.location(in: superview ?? self)
    }

    private func canBeginVoiceInput(source: AppAgentInputBarVoiceInputSource) -> Bool {
        guard !isCollapsed,
              !isHoldingVoiceInput else {
            return false
        }

        switch source {
        case .voiceModePress:
            return inputSource == .voice
                && voiceInputHoldButton.isEnabled
                && voiceInputHoldButton.isUserInteractionEnabled
        case .keyboardModeLongPress:
            // 键盘已激活或仍有草稿文字时，不触发语音输入：前者保留原生文本编辑手势，
            // 后者避免收起键盘后长按误开启语音。空白字符也属于已输入内容，不做 trim。
            return inputSource == .keyboard
                && textView.isEditable
                && !textView.isFirstResponder
                && textView.text.isEmpty
        }
    }

    // MARK: - Input Bar Pan

    @objc private func handleInputBarPan(_ gr: UIPanGestureRecognizer) {
        // 手指状态：pan 手势发生在 inputBar 所在宿主视图坐标系中，后续 frame 计算都以宿主视图为基准。
        guard let hostView = superview else { return }

        switch gr.state {
        case .began:
            // 手指阶段：刚按下并开始拖拽，记录本次 pan 的初始状态。
            beginInputBarPan(gr, in: hostView)

        case .changed:
            // 手指阶段：手指移动中，根据已锁定模式提出 frame 变化意图或处理键盘焦点。
            updateInputBarPan(gr, in: hostView)

        case .ended, .cancelled, .failed:
            // 手指阶段：手指抬起、系统取消或手势失败，按模式做最终结算并清理状态。
            finishInputBarPan(gr, in: hostView)

        default:
            // 手指阶段：其它 UIKit 状态不参与 inputBar 的展开、收起、移动或键盘处理。
            break
        }
    }

    private func beginInputBarPan(_ gr: UIPanGestureRecognizer, in hostView: UIView) {
        // 手指阶段：若上一次回弹尚未结束，先停在当前视觉位置，再以该位置开始新的拖拽。
        stopFrameAnimationAtCurrentFrame()

        // 手指阶段：刚按下并开始拖拽，记录本次手势开始时 inputBar 是否已经是收起态。
        inputBarPanStartedCollapsed = isCollapsed

        // 手指阶段：新一轮手势还没有确定用途，先清空上一轮留下的模式。
        inputBarPanMode = .undecided

        // 手指状态：当前手指相对手势开始点的总位移，用作本次 pan 的锚点。
        let translation = gr.translation(in: hostView)

        // 手指阶段：记录拖拽起点的 frame 和 translation，后续所有跟手变化都从这个锚点增量计算。
        inputBarPanAnchorFrame = frame
        inputBarPanAnchorTranslation = translation

        // 手指阶段：初始化收起态停留计时，用于判断手指抬起时是否需要自由落位。
        resetCollapsedHoldTracking(center: frame.center)

        // 手指阶段：初始化“展开 resize 拖到收起态后切换为 move”的停留计时。
        resetResizeCollapsedHoldTracking()
    }

    private func updateInputBarPan(_ gr: UIPanGestureRecognizer, in hostView: UIView) {
        // 手指状态：当前手指相对手势开始点的总位移，用于判断方向、跟手 resize 或跟手移动。
        let translation = gr.translation(in: hostView)

        // 手指阶段：手指移动中，计算从本次 pan 锚点开始的实际位移。
        let delta = inputBarPanDelta(from: translation)

        // 手指阶段：如果本次手势还没有确定用途，根据起始区域和首次明确方向锁定模式。
        resolveInputBarPanModeIfNeeded(delta: delta)

        // 手指阶段：frame 变化和键盘焦点各自处理；不符合当前模式的方法会直接返回。
        proposeFrameChangeIfNeeded(delta: delta, translation: translation)
        updateTextInputFocusPanIfNeeded(delta: delta)
    }

    private func finishInputBarPan(_ gr: UIPanGestureRecognizer, in hostView: UIView) {
        // 手指阶段：手指结束时只结算会改变 frame 的 pan，键盘焦点和 ignored 不需要外部落位策略。
        finishFramePanIfNeeded(velocity: gr.velocity(in: hostView))

        // 手指阶段：本次 pan 已结束，清理状态，避免影响下一次手势判断。
        resetInputBarPanState()
    }

    private func updateTextInputFocusPanIfNeeded(delta: CGPoint) {
        guard inputBarPanMode == .textInputFocus else { return }

        if delta.y > 0, textView.isFirstResponder {
            textView.resignFirstResponder()
            return
        }

        if delta.y < 0,
           inputBarPanStartRegion == .inputArea,
           inputSource == .keyboard,
           !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    private func proposeFrameChangeIfNeeded(delta: CGPoint, translation: CGPoint) {
        switch inputBarPanMode {
        case .expandedMenuResize:
            proposeExpandedResizeFrameChange(delta: delta, translation: translation)
        case .collapsedMenuMove:
            proposeCollapsedMoveFrameChange(delta: delta)
        case .undecided, .textInputFocus, .ignored:
            break
        }
    }

    private func proposeExpandedResizeFrameChange(delta: CGPoint, translation: CGPoint) {
        let proposedFrame = expandedResizeFrame(deltaX: delta.x)
        delegate?.inputBar(self, wantsFrame: proposedFrame, panKind: .expandedResize)
        rebaseExpandedResizeAnchorIfConstrained(
            proposedFrame: proposedFrame,
            delta: delta,
            currentTranslation: translation
        )
        if updateResizeToCollapsedMoveTransition(currentTranslation: translation) {
            proposeCollapsedMoveFrameChange(delta: inputBarPanDelta(from: translation))
        }
    }

    /// 宿主已把 resize 提案限制在边界时重设手势锚点，避免越界 translation 累积成反向拖动的空行程。
    private func rebaseExpandedResizeAnchorIfConstrained(
        proposedFrame: CGRect,
        delta: CGPoint,
        currentTranslation: CGPoint
    ) {
        // 左侧橡皮筋会改变 width 但保持右边缘连续，此时必须保留原始 translation 才能自然反向拖回。
        // 只有 width 与右边缘都被宿主硬限制时才重设锚点，消除真正硬边界产生的反向空行程。
        let widthWasHardConstrained = abs(proposedFrame.width - frame.width) > 0.5
            && abs(proposedFrame.maxX - frame.maxX) > 0.5
        let isPushingPastCollapsedWidth = isCollapsed && delta.x > 0
        guard widthWasHardConstrained || isPushingPastCollapsedWidth else { return }

        inputBarPanAnchorFrame = frame
        inputBarPanAnchorTranslation = currentTranslation
    }

    private func proposeCollapsedMoveFrameChange(delta: CGPoint) {
        let proposedFrame = inputBarPanAnchorFrame.offsetBy(dx: delta.x, dy: delta.y)
        delegate?.inputBar(self, wantsFrame: proposedFrame, panKind: .collapsedMove)
        updateCollapsedHoldTracking(center: frame.center)
    }

    private func finishFramePanIfNeeded(velocity: CGPoint) {
        switch inputBarPanMode {
        case .expandedMenuResize:
            delegate?.inputBar(
                self,
                didEndFramePan: AppAgentInputBarFramePanEndContext(
                    kind: .expandedResize,
                    velocity: velocity,
                    frame: frame,
                    didHoldNearFinalPosition: false
                )
            )
        case .collapsedMenuMove:
            delegate?.inputBar(self, didEndFramePan: collapsedMoveEndContext(velocity: velocity))
        case .undecided, .textInputFocus, .ignored:
            break
        }
    }

    private func collapsedMoveEndContext(velocity: CGPoint) -> AppAgentInputBarFramePanEndContext {
        let speed = hypot(velocity.x, velocity.y)
        let now = Date.timeIntervalSinceReferenceDate
        let holdDuration = now - (collapsedHoldStartTime ?? now)
        let didHoldNearFinalPosition = holdDuration >= Self.collapsedHoldDuration
            && speed <= Self.collapsedHoldSlowVelocityThreshold
        return AppAgentInputBarFramePanEndContext(
            kind: .collapsedMove,
            velocity: velocity,
            frame: frame,
            didHoldNearFinalPosition: didHoldNearFinalPosition
        )
    }

    private func lockedInputBarPanDirection(for delta: CGPoint) -> InputBarPanDirection? {
        let ax = abs(delta.x)
        let ay = abs(delta.y)
        guard max(ax, ay) >= Self.panDirectionThreshold else { return nil }
        return ax > ay ? .horizontal : .vertical
    }

    private func resolveInputBarPanModeIfNeeded(delta: CGPoint) {
        guard inputBarPanMode == .undecided else { return }

        if inputBarPanStartRegion == .menuButton, inputBarPanStartedCollapsed {
            inputBarPanMode = .collapsedMenuMove
            return
        }

        guard let direction = lockedInputBarPanDirection(for: delta) else { return }

        switch inputBarPanStartRegion {
        case .menuButton:
            if direction == .horizontal {
                inputBarPanMode = .expandedMenuResize
            } else if delta.y > 0, textView.isFirstResponder {
                inputBarPanMode = .textInputFocus
            } else {
                inputBarPanMode = .ignored
            }
        case .inputArea:
            guard inputSource == .keyboard else {
                inputBarPanMode = .ignored
                return
            }

            guard direction == .vertical else {
                inputBarPanMode = .ignored
                return
            }

            if delta.y > 0, textView.isFirstResponder {
                inputBarPanMode = .textInputFocus
            } else if delta.y < 0, !textView.isFirstResponder {
                inputBarPanMode = .textInputFocus
            } else {
                inputBarPanMode = .ignored
            }
        case .bar:
            if direction == .vertical, delta.y > 0, textView.isFirstResponder {
                inputBarPanMode = .textInputFocus
            } else {
                inputBarPanMode = .ignored
            }
        }
    }

    private func updateResizeToCollapsedMoveTransition(currentTranslation: CGPoint) -> Bool {
        guard inputBarPanMode == .expandedMenuResize else {
            resetResizeCollapsedHoldTracking()
            return false
        }

        guard isCollapsed else {
            resetResizeCollapsedHoldTracking()
            return false
        }

        if resizeCollapsedHoldStartTime == nil {
            resizeCollapsedHoldStartTime = Date.timeIntervalSinceReferenceDate
            return false
        }

        let now = Date.timeIntervalSinceReferenceDate
        let holdDuration = now - (resizeCollapsedHoldStartTime ?? now)
        if holdDuration >= Self.resizeToCollapsedMoveHoldDuration {
            switchExpandedResizeToCollapsedMove(currentTranslation: currentTranslation)
            return true
        }

        return false
    }

    private func resetResizeCollapsedHoldTracking() {
        resizeCollapsedHoldStartTime = nil
    }

    private func switchExpandedResizeToCollapsedMove(currentTranslation: CGPoint) {
        inputBarPanMode = .collapsedMenuMove
        inputBarPanStartedCollapsed = true
        inputBarPanAnchorFrame = frame
        inputBarPanAnchorTranslation = currentTranslation
        resetCollapsedHoldTracking(center: frame.center)
        resetResizeCollapsedHoldTracking()
    }

    private func inputBarPanDelta(from translation: CGPoint) -> CGPoint {
        CGPoint(
            x: translation.x - inputBarPanAnchorTranslation.x,
            y: translation.y - inputBarPanAnchorTranslation.y
        )
    }

    private func expandedResizeFrame(deltaX: CGFloat) -> CGRect {
        let rightEdge = inputBarPanAnchorFrame.maxX
        let width = max(AppAgentInputBarMetrics.collapsedMinWidth, inputBarPanAnchorFrame.width - deltaX)
        return CGRect(
            x: rightEdge - width,
            y: inputBarPanAnchorFrame.minY,
            width: width,
            height: inputBarPanAnchorFrame.height
        )
    }

    private func resetCollapsedHoldTracking(center: CGPoint) {
        collapsedHoldAnchorCenter = center
        collapsedHoldStartTime = Date.timeIntervalSinceReferenceDate
    }

    private func updateCollapsedHoldTracking(center: CGPoint) {
        if center.distance(to: collapsedHoldAnchorCenter) > Self.collapsedHoldPositionThreshold {
            resetCollapsedHoldTracking(center: center)
        }
    }

    private func resetInputBarPanState() {
        inputBarPanStartRegion = .bar
        inputBarPanMode = .undecided
        inputBarPanStartedCollapsed = false
        inputBarPanAnchorFrame = .zero
        inputBarPanAnchorTranslation = .zero
        collapsedHoldStartTime = nil
        resetResizeCollapsedHoldTracking()
    }

}

// MARK: - UITextViewDelegate

/// 处理输入框的输入状态变化和键盘发送行为。
extension AppAgentInputBar: UITextViewDelegate {
    public func textViewDidBeginEditing(_ textView: UITextView) {
        updatePlaceholder()
        delegate?.inputBar(self, didChangeTextInputFocus: true)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        // 面板只在这一次编辑里顶替键盘；下次点输入框还是先出键盘。
        textView.inputView = nil
        updatePlusButtonIcon()
        updatePlaceholder()
        delegate?.inputBar(self, didChangeTextInputFocus: false)
    }

    public func textViewDidChange(_ textView: UITextView) {
        draftDidChange()
    }

    /// 键盘的「发送」键同样产出换行符：拦下来当发送，不写进草稿。粘贴进来的多行文字不受影响。
    public func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard text == "\n" else {
            return true
        }
        let draft = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty || !attachments.isEmpty {
            delegate?.inputBar(self, didSendText: draft)
        }
        return false
    }
}

// MARK: - UIGestureRecognizerDelegate

/// 处理 inputBar 内部 pan、长按语音输入等手势是否允许开始，以及手势起点区域判定。
extension AppAgentInputBar: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === voiceInputTouchProbe {
            // 被动探针：接收所有触点，预热 / 取消预热的判定在 onTouchDown / onTouchUp 里做。
            return true
        }
        if gestureRecognizer === attachmentPanelDismissTap {
            return isShowingAttachmentPanel
        }
        if gestureRecognizer === keyboardModeLongPressGesture {
            // 手指刚按下：只允许键盘模式、键盘未激活且无草稿时，
            // 从输入区域或麦克风输入源按钮开始长按。
            guard canBeginVoiceInput(source: .keyboardModeLongPress) else { return false }

            if isTouch(touch, insideViewHierarchyOf: inputAreaContainer) {
                return true
            }

            if isTouch(touch, insideViewHierarchyOf: inputSourceButton) {
                return inputSourceButton.isEnabled && inputSourceButton.isUserInteractionEnabled
            }

            return false
        }

        if gestureRecognizer === inputBarPan {
            guard menuButton.isEnabled else {
                inputBarPanStartRegion = .bar
                return false
            }

            inputBarPanStartRegion = startRegion(for: touch.location(in: self))
            return true
        }
        return true
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === voiceModePressGesture {
            return canBeginVoiceInput(source: .voiceModePress)
        }

        if gestureRecognizer === keyboardModeLongPressGesture {
            // 从按下到长按成立之间状态可能变化，因此在正式开始前再次校验。
            return canBeginVoiceInput(source: .keyboardModeLongPress)
        }

        if gestureRecognizer === inputBarPan {
            guard menuButton.isEnabled, !isHoldingVoiceInput else { return false }

            let velocity = inputBarPan.velocity(in: self)
            let ax = abs(velocity.x)
            let ay = abs(velocity.y)
            let isVertical = ay >= ax

            switch inputBarPanStartRegion {
            case .bar:
                return isVertical && velocity.y > 0 && textView.isFirstResponder
            case .inputArea:
                guard inputSource == .keyboard else { return false }
                if !isVertical { return false }
                // 草稿超过最大行数时，输入区里的竖向拖动留给输入框自己滚动查看。
                if textView.isContentScrollable {
                    return false
                }
                if velocity.y > 0, textView.isFirstResponder {
                    return true
                }
                if velocity.y < 0, !textView.isFirstResponder {
                    return true
                }
                return false
            case .menuButton:
                return true
            }
        }
        return true
    }

    /// 判断触点命中的实际视图是否属于指定视图层级，避免手工依赖 frame 和内部子视图结构。
    private func isTouch(_ touch: UITouch, insideViewHierarchyOf view: UIView) -> Bool {
        guard let touchedView = touch.view else { return false }
        return touchedView === view || touchedView.isDescendant(of: view)
    }

    /// 供测试断言上滑起手区域：与 `hitTest` 共用同一个 `extendedInputAreaHitRect`。
    func panStartRegionForTesting(at point: CGPoint) -> InputBarPanStartRegion {
        startRegion(for: point)
    }

    private func startRegion(for point: CGPoint) -> InputBarPanStartRegion {
        if menuButton.frame.contains(point) {
            return .menuButton
        }

        // 与点击命中保持一致：上滑唤起键盘的起始区域同样扩到整条 bar 那么高。
        let extended = extendedInputAreaHitRect
        if !extended.isNull, extended.contains(point) {
            return .inputArea
        }

        return .bar
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 被动探针不参与竞争，但需与真实手势并存，否则会被系统判为互斥而收不到触点。
        if gestureRecognizer === voiceInputTouchProbe || otherGestureRecognizer === voiceInputTouchProbe {
            return true
        }
        // 切回键盘的轻点不能吃掉文字区自己的点按（移动光标）。
        if gestureRecognizer === attachmentPanelDismissTap || otherGestureRecognizer === attachmentPanelDismissTap {
            return true
        }
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

#endif
