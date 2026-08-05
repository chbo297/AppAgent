//
//  OpenAPPInputBar.swift
//  OpenAPPUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Delegate Protocol

/// inputBar frame 拖拽的业务类型，用于区分展开态调整宽度和收起态移动位置。
public enum OpenAPPInputBarFramePanKind {
    case expandedResize
    case collapsedMove
}

/// inputBar frame 的应用方式：拖拽即时跟手、普通过渡或越界回弹。
public enum OpenAPPInputBarFrameAnimation {
    /// 不播放动画，立即应用 frame；用于布局和拖拽 changed 阶段。
    case immediate

    /// 普通 ease-out 过渡；用于展开、收起和常规吸附。
    case standard

    /// 带阻尼的边界回弹；用于展开 resize 或收起 move 越界后的合法 frame 恢复。
    case boundaryRebound

    var isAnimated: Bool {
        switch self {
        case .immediate:
            return false
        case .standard, .boundaryRebound:
            return true
        }
    }

    func makeAnimator(animations: @escaping () -> Void) -> UIViewPropertyAnimator? {
        switch self {
        case .immediate:
            return nil
        case .standard:
            return UIViewPropertyAnimator(duration: 0.24, curve: .easeOut, animations: animations)
        case .boundaryRebound:
            let timing = UISpringTimingParameters(dampingRatio: 0.78)
            let animator = UIViewPropertyAnimator(duration: 0.30, timingParameters: timing)
            animator.addAnimations(animations)
            return animator
        }
    }
}

/// inputBar 当前输入源模式：键盘输入或语音输入。
public enum OpenAPPInputBarInputSource {
    case keyboard
    case voice
}

/// 触发语音输入的交互场景，用于区分“语音模式按下”和“键盘模式长按”。
public enum OpenAPPInputBarVoiceInputSource {
    /// 语音输入模式下，手指按下中间“按住说话”区域。
    case voiceModePress

    /// 键盘输入模式且键盘未激活时，长按输入区域或输入源切换按钮。
    case keyboardModeLongPress
}

/// 语音输入手势的值上下文：不向宿主暴露 UIKit recognizer，只透传阶段与宿主坐标系中的位置。
public struct OpenAPPInputBarVoiceGestureEvent {
    /// 手势阶段：began → moved* → ended / cancelled。
    public enum Phase {
        case began
        case moved
        case ended
        case cancelled
    }

    public let source: OpenAPPInputBarVoiceInputSource
    public let phase: Phase

    /// 手指在 inputBar 宿主视图（superview）坐标系中的位置。
    public let locationInHost: CGPoint
}

/// inputBar frame 拖拽结束时传给外部的上下文，外部据此决定最终展开、收起、吸附或自由落位。
public struct OpenAPPInputBarFramePanEndContext {
    public let kind: OpenAPPInputBarFramePanKind
    public let velocity: CGPoint
    public let frame: CGRect

    /// 收起态 move 结束时，手指是否已经在当前位置附近低速停留足够久；为 true 时外部通常自由落位，不再吸附边缘。
    public let didHoldNearFinalPosition: Bool

    public init(
        kind: OpenAPPInputBarFramePanKind,
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
public protocol OpenAPPInputBarDelegate: AnyObject {
    func inputBar(_ bar: OpenAPPInputBar, didSendText text: String)
    func inputBarDidTapVoice(_ bar: OpenAPPInputBar)
    func inputBarDidTapPlus(_ bar: OpenAPPInputBar)
    func inputBar(_ bar: OpenAPPInputBar, didChangeInputSource source: OpenAPPInputBarInputSource)
    func inputBar(_ bar: OpenAPPInputBar, didChangeTextInputFocus isFocused: Bool)
    func inputBar(_ bar: OpenAPPInputBar, didReceiveVoiceInputGesture event: OpenAPPInputBarVoiceGestureEvent)
    func inputBarDidRequestExpand(_ bar: OpenAPPInputBar)
    func inputBarDidRequestCollapse(_ bar: OpenAPPInputBar)
    func inputBar(
        _ bar: OpenAPPInputBar,
        wantsFrame frame: CGRect,
        panKind kind: OpenAPPInputBarFramePanKind
    )
    func inputBar(
        _ bar: OpenAPPInputBar,
        didEndFramePan context: OpenAPPInputBarFramePanEndContext
    )
}

/// inputBar 代理默认空实现，让宿主只实现自己关心的事件。
public extension OpenAPPInputBarDelegate {
    func inputBar(_ bar: OpenAPPInputBar, didSendText text: String) {}
    func inputBarDidTapVoice(_ bar: OpenAPPInputBar) {}
    func inputBarDidTapPlus(_ bar: OpenAPPInputBar) {}
    func inputBar(_ bar: OpenAPPInputBar, didChangeInputSource source: OpenAPPInputBarInputSource) {}
    func inputBar(_ bar: OpenAPPInputBar, didChangeTextInputFocus isFocused: Bool) {}
    func inputBar(_ bar: OpenAPPInputBar, didReceiveVoiceInputGesture event: OpenAPPInputBarVoiceGestureEvent) {}
    func inputBarDidRequestExpand(_ bar: OpenAPPInputBar) {}
    func inputBarDidRequestCollapse(_ bar: OpenAPPInputBar) {}
    func inputBar(
        _ bar: OpenAPPInputBar,
        wantsFrame frame: CGRect,
        panKind kind: OpenAPPInputBarFramePanKind
    ) {}
    func inputBar(
        _ bar: OpenAPPInputBar,
        didEndFramePan context: OpenAPPInputBarFramePanEndContext
    ) {}
}

// MARK: - OpenAPPInputBar

/// 胶囊输入栏视图：内部负责按钮、输入区、语音输入区布局和手势识别，外部宿主负责最终 frame 约束与落位。
public final class OpenAPPInputBar: UIView {

    // MARK: - Layout Constants

    /// 胶囊条默认高度。
    public static let barHeight: CGFloat = 56

    /// 完全收起宽度：8 + 40 + 8。
    public static var collapsedMinWidth: CGFloat { innerPadding * 2 + buttonSize }

    /// 最小展开宽度：8 + 40 + 8 + 80 + 8 + 40 + 8 + 40 + 8。
    public static var minimumExpandedWidth: CGFloat {
        innerPadding * 5 + buttonSize * 3 + minimumInputAreaWidth
    }

    private static let innerPadding: CGFloat = 8
    private static let buttonSize: CGFloat = 40
    private static let minimumInputAreaWidth: CGFloat = 80
    private static let symbolIconPointSize: CGFloat = 24
    private static let keyboardIconPointSize: CGFloat = 17
    /// 展开态 inputBar 背景圆角；ChatPanel 收至最小高度时复用该值以保持视觉对齐。
    static let expandedCornerRadius: CGFloat = 16
    private static let inactiveTextInputPlaceholder = "发消息或按住说话..."
    private static let activeTextInputPlaceholder = "发消息..."

    private static let normalZeroInputAreaWidth: CGFloat = innerPadding * 5 + buttonSize * 3
    private static let compressedTextGapWidth: CGFloat = innerPadding * 4 + buttonSize * 3
    private static let collapsedPlusVisibleWidth: CGFloat = innerPadding * 3 + buttonSize * 2

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
    private enum InputBarPanStartRegion {
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
    private var activeVoiceInputSource: OpenAPPInputBarVoiceInputSource?
    private var lastVoiceInputHostLocation: CGPoint = .zero
    private var frameAnimator: UIViewPropertyAnimator?

    // MARK: - Delegate

    public weak var delegate: OpenAPPInputBarDelegate?

    // MARK: - Subviews

    public let menuButton = OpenAPPMenuButton()
    public let inputAreaContainer = UIView()
    public let textField = OpenAPPTextField()
    public let voiceInputHoldButton = UIButton(type: .custom)
    public let inputSourceButton = UIButton(type: .system)
    public let plusButton = UIButton(type: .system)

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

    // MARK: - Public API

    public var text: String {
        get { textField.text ?? "" }
        set { textField.text = newValue }
    }

    public private(set) var inputSource: OpenAPPInputBarInputSource = .keyboard

    public var isCollapsed: Bool {
        bounds.width <= Self.collapsedMinWidth + 0.5
    }

    public func clearText() {
        textField.text = ""
    }

    public func setInputEnabled(_ enabled: Bool) {
        textField.isEnabled = enabled
        menuButton.isEnabled = enabled
        inputSourceButton.isEnabled = enabled
        voiceInputHoldButton.isEnabled = enabled
        plusButton.isEnabled = enabled
        updateControlInteractionState()
    }

    public func setInputSource(_ source: OpenAPPInputBarInputSource, animated: Bool) {
        setInputSource(source, animated: animated, focusKeyboard: false)
    }

    public func setInputBarFrame(_ frame: CGRect, animation: OpenAPPInputBarFrameAnimation) {
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
        pointSize: CGFloat = symbolIconPointSize
    ) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        for name in [primary] + fallbacks {
            if let image = UIImage(systemName: name, withConfiguration: config) {
                return image
            }
        }
        return nil
    }

    private func setup() {
        layer.cornerRadius = Self.expandedCornerRadius
        layer.masksToBounds = false
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.borderWidth = 1

        plusButton.setImage(
            Self.systemSymbolImage(primary: "plus.circle", fallbacks: ["plus"]),
            for: .normal
        )
        plusButton.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)

        inputSourceButton.addTarget(self, action: #selector(inputSourceTapped), for: .touchUpInside)

        inputAreaContainer.clipsToBounds = true

        textField.placeholder = Self.inactiveTextInputPlaceholder
        textField.font = .systemFont(ofSize: 15)
        textField.returnKeyType = .send
        textField.borderStyle = .none
        textField.delegate = self

        voiceInputHoldButton.setTitle("按住说话", for: .normal)
        voiceInputHoldButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        voiceInputHoldButton.titleLabel?.textAlignment = .center
        voiceInputHoldButton.contentHorizontalAlignment = .center
        voiceInputHoldButton.layer.cornerRadius = inputAreaHeight / 2
        voiceInputHoldButton.layer.masksToBounds = true
        voiceInputHoldButton.adjustsImageWhenHighlighted = false
        voiceInputHoldButton.accessibilityLabel = "按住说话"
        voiceInputHoldButton.addGestureRecognizer(voiceModePressGesture)

        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)

        addSubview(plusButton)
        addSubview(inputSourceButton)
        addSubview(inputAreaContainer)
        inputAreaContainer.addSubview(textField)
        inputAreaContainer.addSubview(voiceInputHoldButton)
        addSubview(menuButton)
        addGestureRecognizer(inputBarPan)
        // 键盘模式长按需要同时覆盖输入区域和输入源按钮，因此由 inputBar 统一接收，再由代理过滤起点。
        addGestureRecognizer(keyboardModeLongPressGesture)

        applyAppearance()
        updateInputSourceAppearance(animated: false, notifyDelegate: false)
        updateControlInteractionState()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func applyAppearance() {
        backgroundColor = OpenAPPAppearance.inputBarBackground
        layer.borderColor = OpenAPPAppearance.inputBarBorder.resolvedColor(with: traitCollection).cgColor
        layer.shadowColor = OpenAPPAppearance.inputBarShadow.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = OpenAPPAppearance.inputBarShadowOpacity(for: traitCollection)

        textField.textColor = OpenAPPAppearance.primaryText
        textField.tintColor = OpenAPPAppearance.accent
        updateTextFieldPlaceholder()
        plusButton.tintColor = OpenAPPAppearance.icon
        inputSourceButton.tintColor = OpenAPPAppearance.icon
        voiceInputHoldButton.setTitleColor(OpenAPPAppearance.primaryText, for: .normal)
        setVoiceInputHolding(isHoldingVoiceInput)
        menuButton.setNeedsDisplay()
    }

    // MARK: - Layout

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
        let width = max(size.width, Self.collapsedMinWidth)
        let contentY = size.height >= Self.barHeight ? (size.height - Self.barHeight) / 2 : 0
        let buttonY = contentY + (Self.barHeight - Self.buttonSize) / 2
        let inputAreaY = contentY + (Self.barHeight - inputAreaHeight) / 2

        let menuX = Self.innerPadding
        let inputAreaX: CGFloat
        let inputAreaWidth: CGFloat
        let inputSourceX: CGFloat
        let plusX: CGFloat

        if width >= Self.normalZeroInputAreaWidth {
            inputAreaX = menuX + Self.buttonSize + Self.innerPadding
            inputAreaWidth = width - Self.normalZeroInputAreaWidth
            plusX = width - Self.innerPadding - Self.buttonSize
            inputSourceX = plusX - Self.innerPadding - Self.buttonSize
        } else if width >= Self.compressedTextGapWidth {
            let compressedMenuTextGap = width - Self.compressedTextGapWidth
            inputAreaX = menuX + Self.buttonSize + compressedMenuTextGap
            inputAreaWidth = 0
            inputSourceX = inputAreaX + Self.innerPadding
            plusX = inputSourceX + Self.buttonSize + Self.innerPadding
        } else if width >= Self.collapsedPlusVisibleWidth {
            inputAreaX = menuX + Self.buttonSize
            inputAreaWidth = 0
            inputSourceX = width - Self.buttonSize * 2 - Self.innerPadding * 2
            plusX = width - Self.buttonSize - Self.innerPadding
        } else {
            inputAreaX = menuX + Self.buttonSize
            inputAreaWidth = 0
            inputSourceX = menuX
            plusX = width - Self.buttonSize - Self.innerPadding
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
            width: max(inputAreaWidth, Self.minimumInputAreaWidth),
            height: inputAreaHeight
        )
        voiceInputHoldButton.frame = CGRect(
            x: 0,
            y: 0,
            width: max(inputAreaWidth, Self.minimumInputAreaWidth),
            height: inputAreaHeight
        )

        plusButton.frame = CGRect(x: plusX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
        inputSourceButton.frame = CGRect(x: inputSourceX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
        menuButton.frame = CGRect(x: menuX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)

        // inputBar 小于最小展开宽度后，输入区会从 80pt 逐步压缩到 0；alpha 同步由 1 线性过渡到 0。
        inputAreaContainer.alpha = OpenAPPGeometry.clamp(
            (width - Self.normalZeroInputAreaWidth)
                / (Self.minimumExpandedWidth - Self.normalZeroInputAreaWidth),
            0,
            1
        )
        inputSourceButton.alpha = OpenAPPGeometry.clamp(
            (width - Self.collapsedPlusVisibleWidth)
                / (Self.compressedTextGapWidth - Self.collapsedPlusVisibleWidth),
            0,
            1
        )
        plusButton.alpha = OpenAPPGeometry.clamp(
            (width - Self.collapsedMinWidth)
                / (Self.collapsedPlusVisibleWidth - Self.collapsedMinWidth),
            0,
            1
        )
    }

    private func updateCapsuleCornerRadius(for size: CGSize) {
        let width = max(size.width, Self.collapsedMinWidth)
        let expandedTravel = Self.minimumExpandedWidth - Self.collapsedMinWidth
        let expandedProgress = OpenAPPGeometry.clamp((width - Self.collapsedMinWidth) / expandedTravel, 0, 1)
        let cornerRadiusCollapseRatio = 1 - expandedProgress
        let collapsedRadius = min(width, size.height) / 2
        let radius = Self.expandedCornerRadius
            + (collapsedRadius - Self.expandedCornerRadius) * cornerRadiusCollapseRatio

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
    }

    private func setInputSource(
        _ source: OpenAPPInputBarInputSource,
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
            attributes: [.foregroundColor: OpenAPPAppearance.placeholderText]
        )
    }

    private func setVoiceInputHolding(_ holding: Bool) {
        voiceInputHoldButton.backgroundColor = holding
            ? OpenAPPAppearance.voicePressedBackground
            : .clear
        voiceInputHoldButton.setTitleColor(OpenAPPAppearance.primaryText, for: .normal)
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

    @objc private func handleVoiceModePress(_ gr: UILongPressGestureRecognizer) {
        handleVoiceInputGesture(gr, source: .voiceModePress)
    }

    @objc private func handleKeyboardModeLongPress(_ gr: UILongPressGestureRecognizer) {
        handleVoiceInputGesture(gr, source: .keyboardModeLongPress)
    }

    private func handleVoiceInputGesture(
        _ gr: UILongPressGestureRecognizer,
        source: OpenAPPInputBarVoiceInputSource
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
        source: OpenAPPInputBarVoiceInputSource,
        gestureRecognizer: UILongPressGestureRecognizer
    ) {
        guard canBeginVoiceInput(source: source) else { return }

        isHoldingVoiceInput = true
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
        let phase: OpenAPPInputBarVoiceGestureEvent.Phase =
            (gestureRecognizer == nil || forcesCancel) ? .cancelled : .ended
        isHoldingVoiceInput = false
        activeVoiceInputSource = nil
        setVoiceInputHolding(false)

        sendVoiceGestureEvent(source: source, phase: phase)
    }

    private func sendVoiceGestureEvent(
        source: OpenAPPInputBarVoiceInputSource,
        phase: OpenAPPInputBarVoiceGestureEvent.Phase
    ) {
        delegate?.inputBar(self, didReceiveVoiceInputGesture: OpenAPPInputBarVoiceGestureEvent(
            source: source,
            phase: phase,
            locationInHost: lastVoiceInputHostLocation
        ))
    }

    /// 手指在宿主视图坐标系中的位置；尚未挂载时退化为自身坐标。
    private func hostLocation(of gestureRecognizer: UIGestureRecognizer) -> CGPoint {
        gestureRecognizer.location(in: superview ?? self)
    }

    private func canBeginVoiceInput(source: OpenAPPInputBarVoiceInputSource) -> Bool {
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
                didEndFramePan: OpenAPPInputBarFramePanEndContext(
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

    private func collapsedMoveEndContext(velocity: CGPoint) -> OpenAPPInputBarFramePanEndContext {
        let speed = hypot(velocity.x, velocity.y)
        let now = Date.timeIntervalSinceReferenceDate
        let holdDuration = now - (collapsedHoldStartTime ?? now)
        let didHoldNearFinalPosition = holdDuration >= Self.collapsedHoldDuration
            && speed <= Self.collapsedHoldSlowVelocityThreshold
        return OpenAPPInputBarFramePanEndContext(
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
        let width = max(Self.collapsedMinWidth, inputBarPanAnchorFrame.width - deltaX)
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
extension OpenAPPInputBar: UITextFieldDelegate {
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
extension OpenAPPInputBar: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
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

    private func startRegion(for point: CGPoint) -> InputBarPanStartRegion {
        if menuButton.frame.contains(point) {
            return .menuButton
        }

        if inputAreaContainer.frame.contains(point) {
            return .inputArea
        }

        return .bar
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

#endif
