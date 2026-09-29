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
    func inputBar(_ bar: AppAgentInputBar, didSendText text: String)
    func inputBarDidTapVoice(_ bar: AppAgentInputBar)
    func inputBarDidTapPlus(_ bar: AppAgentInputBar)
    /// loop 运行中且输入框为空时，右侧圆形按钮变为停止按钮，点击走这里。
    func inputBarDidTapStop(_ bar: AppAgentInputBar)
    func inputBar(_ bar: AppAgentInputBar, didChangeInputSource source: AppAgentInputBarInputSource)
    func inputBar(_ bar: AppAgentInputBar, didChangeTextInputFocus isFocused: Bool)
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
    func inputBarDidTapStop(_ bar: AppAgentInputBar) {}
    func inputBar(_ bar: AppAgentInputBar, didChangeInputSource source: AppAgentInputBarInputSource) {}
    func inputBar(_ bar: AppAgentInputBar, didChangeTextInputFocus isFocused: Bool) {}
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

    private static let panDirectionThreshold: CGFloat = 6
    private static let collapsedHoldPositionThreshold: CGFloat = 4
    private static let collapsedHoldDuration: TimeInterval = 0.3
    private static let collapsedHoldSlowVelocityThreshold: CGFloat = 50
    private static let resizeToCollapsedMoveHoldDuration: TimeInterval = 0.1

    private let inputAreaHeight: CGFloat = 36

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

    // MARK: - Delegate

    public weak var delegate: AppAgentInputBarDelegate?

    // MARK: - Subviews

    public let menuButton = AppAgentMenuButton()
    public let inputAreaContainer = UIView()
    public let textField = AppAgentTextField()
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
        get { textField.text ?? "" }
        set {
            textField.text = newValue
            updateTrailingAction()
        }
    }

    public private(set) var inputSource: AppAgentInputBarInputSource = .keyboard

    /// 当前会话是否还在跑 agent loop。由宿主（`AppAgentViewController`）在运行状态变化时写入；
    /// inputBar 自己不猜，只据此决定右侧槽显示加号还是停止。
    public private(set) var isRunActive = false

    /// 右侧动作槽当前形态：草稿优先，其次运行中，否则加号。
    public var trailingAction: AppAgentInputBarTrailingAction {
        if hasDraftText { return .send }
        return isRunActive ? .stop : .plus
    }

    /// 输入框里是否有可发送的内容（纯空白不算）。
    private var hasDraftText: Bool {
        !(textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        textField.text = ""
        updateTrailingAction()
    }

    public func setInputEnabled(_ enabled: Bool) {
        textField.isEnabled = enabled
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

        plusButton.setImage(
            Self.systemSymbolImage(primary: "plus.circle", fallbacks: ["plus"]),
            for: .normal
        )
        plusButton.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)

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

        textField.placeholder = Self.inactiveTextInputPlaceholder
        textField.font = .systemFont(ofSize: 15)
        textField.returnKeyType = .send
        textField.borderStyle = .none
        textField.delegate = self
        // 草稿有无决定右侧槽形态；`.editingChanged` 只覆盖用户输入，程序化改文本走 `text` / `clearText`。
        textField.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)

        voiceInputHoldButton.setTitle("按住说话", for: .normal)
        voiceInputHoldButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        voiceInputHoldButton.titleLabel?.textAlignment = .center
        voiceInputHoldButton.contentHorizontalAlignment = .center
        voiceInputHoldButton.layer.cornerRadius = inputAreaHeight / 2
        voiceInputHoldButton.layer.masksToBounds = true
        voiceInputHoldButton.accessibilityLabel = "按住说话"
        voiceInputHoldButton.addGestureRecognizer(voiceModePressGesture)

        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)

        addSubview(plusButton)
        addSubview(inputSourceButton)
        addSubview(inputAreaContainer)
        inputAreaContainer.addSubview(textField)
        inputAreaContainer.addSubview(voiceInputHoldButton)
        addSubview(menuButton)
        addSubview(trailingActionButton)
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

        textField.textColor = AppAgentAppearance.primaryText
        textField.tintColor = AppAgentAppearance.accent
        updateTextFieldPlaceholder()
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
        guard hit === self, isUserInteractionEnabled else { return hit }

        let extended = extendedInputAreaHitRect
        guard !extended.isNull, extended.contains(point) else { return hit }

        // 触点在输入区上下的空白里，先把 y 夹进输入区自身 bounds 再做一次命中。
        var local = convert(point, to: inputAreaContainer)
        local.y = min(max(0, local.y), max(0, inputAreaContainer.bounds.height - 0.5))
        return inputAreaContainer.hitTest(local, with: event) ?? hit
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size

        layoutContent(for: size)
        updateCapsuleCornerRadius(for: size)
        updateControlInteractionState()
    }

    private func layoutContent(for size: CGSize) {
        let width = max(size.width, AppAgentInputBarMetrics.collapsedMinWidth)
        let barHeight = AppAgentInputBarMetrics.barHeight
        let innerPadding = AppAgentInputBarMetrics.innerPadding
        let buttonSize = AppAgentInputBarMetrics.buttonSize
        let contentY = size.height >= barHeight ? (size.height - barHeight) / 2 : 0
        let buttonY = contentY + (barHeight - buttonSize) / 2
        let inputAreaY = contentY + (barHeight - inputAreaHeight) / 2

        let menuX = innerPadding
        let inputAreaX: CGFloat
        let inputAreaWidth: CGFloat
        let inputSourceX: CGFloat
        let plusX: CGFloat

        if width >= Self.normalZeroInputAreaWidth {
            inputAreaX = menuX + buttonSize + innerPadding
            inputAreaWidth = width - Self.normalZeroInputAreaWidth
            plusX = width - innerPadding - buttonSize
            inputSourceX = plusX - innerPadding - buttonSize
        } else if width >= Self.compressedTextGapWidth {
            let compressedMenuTextGap = width - Self.compressedTextGapWidth
            inputAreaX = menuX + buttonSize + compressedMenuTextGap
            inputAreaWidth = 0
            inputSourceX = inputAreaX + innerPadding
            plusX = inputSourceX + buttonSize + innerPadding
        } else if width >= Self.collapsedPlusVisibleWidth {
            inputAreaX = menuX + buttonSize
            inputAreaWidth = 0
            inputSourceX = width - buttonSize * 2 - innerPadding * 2
            plusX = width - buttonSize - innerPadding
        } else {
            inputAreaX = menuX + buttonSize
            inputAreaWidth = 0
            inputSourceX = menuX
            plusX = width - buttonSize - innerPadding
        }

        inputAreaContainer.frame = CGRect(
            x: inputAreaX,
            y: inputAreaY,
            width: max(0, inputAreaWidth),
            height: inputAreaHeight
        )
        textField.frame = CGRect(
            x: 0,
            y: 0,
            width: max(inputAreaWidth, AppAgentInputBarMetrics.minimumInputAreaWidth),
            height: inputAreaHeight
        )
        voiceInputHoldButton.frame = CGRect(
            x: 0,
            y: 0,
            width: max(inputAreaWidth, AppAgentInputBarMetrics.minimumInputAreaWidth),
            height: inputAreaHeight
        )

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
        textField.isUserInteractionEnabled = textField.isEnabled
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
        inputSourceButton.isHidden = action == .send

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
                textField.becomeFirstResponder()
            }
            return
        }

        if inputSource == .voice {
            finishActiveVoiceInput(gestureRecognizer: nil)
        }

        inputSource = source
        if source == .voice {
            textField.resignFirstResponder()
        }
        updateInputSourceAppearance(animated: animated, notifyDelegate: true)
        if focusKeyboard, source == .keyboard {
            textField.becomeFirstResponder()
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

        textField.isHidden = !keyboardMode
        textField.alpha = 1
        voiceInputHoldButton.isHidden = keyboardMode
        voiceInputHoldButton.alpha = 1
        inputAreaContainer.bringSubviewToFront(voiceInputHoldButton)
        updateTextFieldPlaceholder()
        updateControlInteractionState()

        if notifyDelegate {
            delegate?.inputBar(self, didChangeInputSource: inputSource)
        }
    }

    private func updateTextFieldPlaceholder() {
        let text = textField.isFirstResponder
            ? Self.activeTextInputPlaceholder
            : Self.inactiveTextInputPlaceholder
        textField.attributedPlaceholder = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: AppAgentAppearance.placeholderText]
        )
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
        delegate?.inputBarDidTapPlus(self)
    }

    /// 右侧圆形按钮：形态决定语义，别在外部再判一遍草稿。
    @objc private func trailingActionTapped() {
        switch trailingAction {
        case .plus:
            delegate?.inputBarDidTapPlus(self)
        case .send:
            let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            delegate?.inputBar(self, didSendText: text)
        case .stop:
            delegate?.inputBarDidTapStop(self)
        }
    }

    @objc private func textFieldEditingChanged() {
        updateTrailingAction()
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
                && textField.isEnabled
                && !textField.isFirstResponder
                && (textField.text ?? "").isEmpty
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

        if delta.y > 0, textField.isFirstResponder {
            textField.resignFirstResponder()
            return
        }

        if delta.y < 0,
           inputBarPanStartRegion == .inputArea,
           inputSource == .keyboard,
           !textField.isFirstResponder {
            textField.becomeFirstResponder()
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
            } else if delta.y > 0, textField.isFirstResponder {
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

            if delta.y > 0, textField.isFirstResponder {
                inputBarPanMode = .textInputFocus
            } else if delta.y < 0, !textField.isFirstResponder {
                inputBarPanMode = .textInputFocus
            } else {
                inputBarPanMode = .ignored
            }
        case .bar:
            if direction == .vertical, delta.y > 0, textField.isFirstResponder {
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

// MARK: - UITextFieldDelegate

/// 处理 textField 的输入状态变化和键盘发送行为。
extension AppAgentInputBar: UITextFieldDelegate {
    public func textFieldDidBeginEditing(_ textField: UITextField) {
        updateTextFieldPlaceholder()
        delegate?.inputBar(self, didChangeTextInputFocus: true)
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        updateTextFieldPlaceholder()
        delegate?.inputBar(self, didChangeTextInputFocus: false)
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return true }
        delegate?.inputBar(self, didSendText: text)
        return true
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
                return isVertical && velocity.y > 0 && textField.isFirstResponder
            case .inputArea:
                guard inputSource == .keyboard else { return false }
                if !isVertical { return false }
                if velocity.y > 0, textField.isFirstResponder { return true }
                if velocity.y < 0, !textField.isFirstResponder { return true }
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
