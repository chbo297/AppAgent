//
//  AppAgentVoiceInputOverlayView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

final class AppAgentVoiceInputOverlayView: UIView {

    /// 编辑态点击取消按钮：由宿主收尾（隐藏面板、丢弃文案）。
    var onEditCancel: (() -> Void)?

    /// 编辑态点击发送按钮：携带编辑后的最终文案，由宿主决定发送方式。
    var onEditSend: ((String) -> Void)?

    private static let bubbleGreen = UIColor(red: 0.56, green: 0.94, blue: 0.40, alpha: 1)
    private static let bubbleRed = UIColor(red: 1.00, green: 0.30, blue: 0.33, alpha: 1)
    private static let waveformGreen = UIColor(red: 0.24, green: 0.55, blue: 0.20, alpha: 0.55)
    private static let waveformRed = UIColor(red: 0.42, green: 0.05, blue: 0.07, alpha: 0.42)
    private static let cursorGreen = UIColor(red: 0.14, green: 0.78, blue: 0.50, alpha: 1)
    /// 气泡内文字统一字体：label 展示、尺寸测量、编辑态 textView 三处共用。
    private static let transcriptFont = UIFont.systemFont(ofSize: 18)
    /// 气泡内文字内边距：bottom 预留波形/尾巴空间；气泡宽高测量的补偿量由此派生。
    private static let bubbleTextInset = UIEdgeInsets(top: 24, left: 24, bottom: 44, right: 24)
    private static let backgroundFadeDuration: TimeInterval = 0.06
    private static let overlayDismissDuration: TimeInterval = 0.1
    private static let bottomPanelEntranceDuration: TimeInterval = 0.06
    private static let bottomPanelTopRevealHeight = AppAgentVoiceArcMetrics.bottomArcSideYOffset
    private static let isHitTestingDebugLoggingEnabled = false
    private static let backgroundBottomColor = UIColor.black.withAlphaComponent(0.54)

    private let backgroundView = AppAgentVoiceInputOverlayBackgroundView(
        bottomColor: AppAgentVoiceInputOverlayView.backgroundBottomColor
    )
    private let bubbleView = AppAgentVoiceBubbleView()
    private let waveformView = AppAgentVoiceWaveformView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let transcriptLabel = UILabel()
    private let bottomPanelView = AppAgentVoiceBottomPanelView()
    private let cancelZoneView = AppAgentVoiceActionZoneView(
        side: .left,
        title: "取消",
        selectedHint: "松手 取消"
    )
    private let editZoneView = AppAgentVoiceActionZoneView(
        side: .right,
        title: "编辑",
        selectedHint: "松手 编辑文字"
    )
    /// 编辑会话：编辑态的 textView、按钮、键盘策略都在会话对象内；与手势态共享同一个 bubbleView。
    /// 惰性存储而非 lazy var：isEditingModeActive 的频繁查询不应触发会话实例化，
    /// 只有真正进入编辑态（enterEditMode）才创建。
    private var editSessionStorage: AppAgentVoiceEditModeSession?

    private var editSession: AppAgentVoiceEditModeSession {
        if let session = editSessionStorage {
            return session
        }
        let session = AppAgentVoiceEditModeSession(
            textFont: Self.transcriptFont,
            textTintColor: Self.cursorGreen
        )
        session.host = self
        editSessionStorage = session
        return session
    }

    private var isEditingModeActive: Bool {
        editSessionStorage?.isActive ?? false
    }

    private var currentRecognitionState: AppAgentVoiceRecognitionVisualState = .none
    private var currentReleaseAction: AppAgentVoiceInputReleaseAction = .send
    private var currentFingerLocation: CGPoint = .zero
    private var transcriptText = ""
    private var showsTranscriptCursor = false
    private var cachedGeometryBounds: CGRect = .null
    private var cachedGeometrySafeAreaInsets: UIEdgeInsets = .zero
    private var cachedBottomPanelFrame: CGRect = .zero
    private var cachedActionZoneFrames: (cancel: CGRect, edit: CGRect) = (.zero, .zero)
    private var cachedTranscriptMeasurementText = ""
    private var cachedTranscriptMeasurementWidth: CGFloat = -1
    private var cachedTranscriptMeasurementHeight: CGFloat = 0
    private var cachedTranscriptNaturalWidthText: String?
    private var cachedTranscriptNaturalWidth: CGFloat = 0
    private var visibilityAnimationID = 0
    private var currentBubbleBodyFrame: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func show(startLocation: CGPoint, animated: Bool) {
        // 上一次编辑态可能仍在淡出中途（complete 未执行），新手势开始前强制退出，避免布局走错形态。
        exitEditModeIfNeeded()
        let shouldResetBackgroundAlpha = isHidden || backgroundView.alpha <= 0.01
        currentFingerLocation = startLocation
        activityIndicator.startAnimating()
        setNeedsLayout()
        layoutIfNeeded()
        setOverlayVisible(true, animated: animated)
        animateBackgroundVisibility(true, animated: true, resetAlpha: shouldResetBackgroundAlpha)
        animateBottomPanelEntrance()
    }

    func update(
        recognitionState: AppAgentVoiceRecognitionVisualState,
        releaseAction: AppAgentVoiceInputReleaseAction,
        fingerLocation: CGPoint,
        transcriptText: String,
        showsTranscriptCursor: Bool
    ) {
        // 编辑态由 textView 驱动，忽略手势阶段的更新。
        guard !isEditingModeActive else { return }
        let recognitionChanged = currentRecognitionState != recognitionState
        let releaseActionChanged = currentReleaseAction != releaseAction
        let transcriptChanged = self.transcriptText != transcriptText
        let cursorChanged = self.showsTranscriptCursor != showsTranscriptCursor
        let fingerLocationChanged = !currentFingerLocation.isApproximatelyEqual(to: fingerLocation)
        guard recognitionChanged
            || releaseActionChanged
            || transcriptChanged
            || cursorChanged
            || fingerLocationChanged else {
            return
        }

        currentRecognitionState = recognitionState
        currentReleaseAction = releaseAction
        currentFingerLocation = fingerLocation
        self.transcriptText = transcriptText
        self.showsTranscriptCursor = showsTranscriptCursor
        let isLoading = recognitionState == .loading && transcriptText.isEmpty
        updateActivityIndicator(isLoading: isLoading)
        if transcriptChanged || cursorChanged {
            updateTranscriptText()
            invalidateTranscriptMeasurementCache()
        }
        if recognitionChanged || releaseActionChanged || transcriptChanged || cursorChanged {
            setNeedsLayout()
        }
    }

    func hide(animated: Bool) {
        // 立即禁用交互：淡出窗口期内再点“发送/取消”会重复触发收尾（如消息重复发送）。
        isUserInteractionEnabled = false
        if isEditingModeActive {
            editSessionStorage?.resignKeyboard()
        }
        let complete = { [weak self] in
            guard let self else { return }
            self.isHidden = true
            self.alpha = 1
            self.backgroundView.layer.removeAllAnimations()
            self.backgroundView.alpha = 0
            self.activityIndicator.stopAnimating()
            self.transcriptText = ""
            self.showsTranscriptCursor = false
            self.currentRecognitionState = .none
            self.currentReleaseAction = .send
            self.cancelZoneView.setSelected(false, animated: false)
            self.editZoneView.setSelected(false, animated: false)
            self.exitEditModeIfNeeded()
            self.invalidateTranscriptMeasurementCache()
            self.updateTranscriptText()
        }
        setOverlayVisible(false, animated: animated, completion: complete)
    }

    private func setOverlayVisible(
        _ visible: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        visibilityAnimationID += 1
        let animationID = visibilityAnimationID

        if visible {
            isHidden = false
            alpha = 1
            completion?()
            return
        }

        let finish = { [weak self] in
            guard let self, self.visibilityAnimationID == animationID else { return }
            self.isHidden = true
            completion?()
        }

        guard animated else {
            alpha = 0
            finish()
            return
        }

        UIView.animate(
            withDuration: Self.overlayDismissDuration,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction, .beginFromCurrentState],
            animations: {
                self.alpha = 0
            },
            completion: { _ in finish() }
        )
    }

    private func animateBottomPanelEntrance() {
        bottomPanelView.layer.removeAnimation(forKey: "appagent.voice.bottomPanelEntrance")
        let translationAnimation = CABasicAnimation(keyPath: "transform.translation.y")
        translationAnimation.fromValue = Self.bottomPanelTopRevealHeight
        translationAnimation.toValue = 0
        translationAnimation.isAdditive = true

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0
        opacityAnimation.toValue = 1

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [translationAnimation, opacityAnimation]
        animationGroup.duration = Self.bottomPanelEntranceDuration
        animationGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bottomPanelView.layer.add(animationGroup, forKey: "appagent.voice.bottomPanelEntrance")
    }

    private func animateBackgroundVisibility(
        _ visible: Bool,
        animated: Bool,
        resetAlpha: Bool,
        completion: (() -> Void)? = nil
    ) {
        if resetAlpha {
            backgroundView.alpha = visible ? 0 : 1
        }

        let apply = {
            self.backgroundView.alpha = visible ? 1 : 0
        }

        guard animated else {
            apply()
            completion?()
            return
        }

        UIView.animate(
            withDuration: Self.backgroundFadeDuration,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
            animations: apply,
            completion: { _ in completion?() }
        )
    }

    func releaseAction(for fingerLocation: CGPoint) -> AppAgentVoiceInputReleaseAction {
        refreshGeometryCacheIfNeeded()
        setFrameIfNeeded(cachedBottomPanelFrame, for: bottomPanelView)

        // 手指命中：先判断底部发送面板，bottom 和上方按钮区域重叠时优先发送。
        if isFingerInsideBottomPanel(fingerLocation) {
            return .send
        }

        // 手指未命中 bottom：移动未抬起期间，按 bottom 的 x 轴中线切分整个非 bottom 区域。
        // 中线左边全部视为取消，右边全部视为编辑，不再要求命中按钮自身的贝塞尔绘制区域。
        return fingerLocation.x < cachedBottomPanelFrame.midX ? .cancel : .edit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setFrameIfNeeded(bounds, for: backgroundView)
        refreshGeometryCacheIfNeeded()
        if isEditingModeActive {
            let bubbleFrame = layoutEditingBubble()
            editSession.layout(
                in: bounds,
                safeBottom: safeAreaInsets.bottom,
                bubbleFrame: bubbleFrame,
                textInset: Self.bubbleTextInset
            )
        } else {
            layoutActionZones()
            layoutBubble()
        }
    }

    private func setup() {
        isHidden = true
        alpha = 0
        isUserInteractionEnabled = false
        backgroundColor = .clear

        backgroundView.alpha = 0
        addSubview(backgroundView)

        bubbleView.backgroundColor = .clear
        addSubview(bubbleView)

        waveformView.backgroundColor = .clear
        bubbleView.contentView.addSubview(waveformView)

        activityIndicator.color = Self.waveformGreen
        bubbleView.contentView.addSubview(activityIndicator)

        transcriptLabel.numberOfLines = 0
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.font = Self.transcriptFont
        bubbleView.contentView.addSubview(transcriptLabel)

        bottomPanelView.backgroundColor = .clear
        addSubview(bottomPanelView)

        [cancelZoneView, editZoneView].forEach {
            $0.backgroundColor = .clear
            addSubview($0)
        }

        updateTranscriptText()
    }

    // MARK: - 编辑态

    /// 进入编辑态：手势阶段已结束，保持面板展示，把气泡切换为可编辑状态并唤起键盘。
    /// 编辑控件与交互由 editSession 承载，overlay 只切换自身形态并共享气泡。
    func enterEditMode(text: String) {
        transcriptText = text
        showsTranscriptCursor = false
        currentReleaseAction = .edit
        currentRecognitionState = .none
        updateTranscriptText()
        invalidateTranscriptMeasurementCache()
        updateActivityIndicator(isLoading: false)

        bottomPanelView.isHidden = true
        cancelZoneView.isHidden = true
        editZoneView.isHidden = true
        transcriptLabel.isHidden = true
        waveformView.isHidden = true
        isUserInteractionEnabled = true

        editSession.begin(text: text)
        setNeedsLayout()
        layoutIfNeeded()
        editSession.activateKeyboard()
    }

    private func exitEditModeIfNeeded() {
        guard let session = editSessionStorage, session.isActive else { return }
        session.end()
        bottomPanelView.isHidden = false
        cancelZoneView.isHidden = false
        editZoneView.isHidden = false
        isUserInteractionEnabled = false
    }

    /// 编辑态气泡：沿用文字气泡的测量逻辑，底部悬在编辑按钮上方，隐藏波形。
    private func layoutEditingBubble() -> CGRect {
        let bubbleFrame = preferredBubbleFrame(hasTranscript: true)
        currentBubbleBodyFrame = bubbleFrame
        setFrameIfNeeded(bounds, for: bubbleView)
        backgroundView.gradientTopY = bubbleFrame.minY
        bubbleView.setAppearance(
            fillColor: Self.bubbleGreen,
            cornerRadius: 24,
            tailXRatio: 0.84,
            bodyFrame: bubbleFrame,
            animated: !isHidden
        )

        transcriptLabel.isHidden = true
        activityIndicator.isHidden = true
        waveformView.isHidden = true
        return bubbleFrame
    }

    private func layoutActionZones() {
        refreshGeometryCacheIfNeeded()
        let zones = cachedActionZoneFrames
        let panelFrame = cachedBottomPanelFrame
        setFrameIfNeeded(panelFrame, for: bottomPanelView)
        setFrameIfNeeded(zones.cancel, for: cancelZoneView)
        setFrameIfNeeded(zones.edit, for: editZoneView)

        let cancelSelected = currentReleaseAction == .cancel
        let editSelected = currentReleaseAction == .edit
        bottomPanelView.setSelected(currentReleaseAction == .send)
        cancelZoneView.setSelected(cancelSelected, animated: true)
        editZoneView.setSelected(editSelected, animated: true)
        cancelZoneView.fillColor = cancelSelected
            ? UIColor.white.withAlphaComponent(0.84)
            : UIColor.white.withAlphaComponent(0.13)
        editZoneView.fillColor = editSelected
            ? UIColor.white.withAlphaComponent(0.84)
            : UIColor.white.withAlphaComponent(0.13)
        cancelZoneView.setTitleColor(cancelSelected ? .black : UIColor.white.withAlphaComponent(0.88))
        editZoneView.setTitleColor(editSelected ? .black : UIColor.white.withAlphaComponent(0.88))
    }

    private func isFingerInsideBottomPanel(_ fingerLocation: CGPoint) -> Bool {
        let bottomPoint = bottomPanelView.convert(fingerLocation, from: self)
        if Self.isHitTestingDebugLoggingEnabled {
            print("[AppAgentVoiceInputOverlay] bottomPoint=\(bottomPoint)")
        }
        return bottomPanelView.point(inside: bottomPoint, with: nil)
    }

    private func layoutBubble() {
        // 取消状态强制退回小气泡：不显示转写大气泡，只保留红色波形。
        let hasTranscript = !transcriptText.isEmpty && currentReleaseAction != .cancel
        let isLoading = currentRecognitionState == .loading && !hasTranscript
        let bubbleFrame = preferredBubbleFrame(hasTranscript: hasTranscript)
        currentBubbleBodyFrame = bubbleFrame
        // 气泡视图占满 overlay，形状/位置完全由 path 表达，切换时是一次连续形变而非 frame 跳变。
        setFrameIfNeeded(bounds, for: bubbleView)
        backgroundView.gradientTopY = bubbleFrame.minY
        bubbleView.setAppearance(
            fillColor: currentReleaseAction == .cancel ? Self.bubbleRed : Self.bubbleGreen,
            cornerRadius: currentReleaseAction == .cancel ? 22 : 24,
            tailXRatio: bubbleTailXRatio(for: bubbleFrame),
            bodyFrame: bubbleFrame,
            animated: !isHidden
        )

        transcriptLabel.isHidden = !hasTranscript
        activityIndicator.isHidden = !isLoading
        waveformView.isHidden = isLoading

        // 气泡内子视图都挂在 contentView 下，使用容器内相对坐标，随容器与气泡形变同步移动。
        let contentBounds = CGRect(origin: .zero, size: bubbleFrame.size)
        if hasTranscript {
            setFrameIfNeeded(contentBounds.inset(by: Self.bubbleTextInset), for: transcriptLabel)
            // 有文字后迷你波形移到气泡右下角（参照微信编辑态）。
            setWaveformFrame(CGRect(
                x: contentBounds.maxX - 54,
                y: contentBounds.maxY - 36,
                width: 34,
                height: 14
            ))
            activityIndicator.center = CGPoint(x: contentBounds.midX, y: contentBounds.midY)
        } else {
            setFrameIfNeeded(.zero, for: transcriptLabel)
            // 录音态居中波形；取消态小气泡里换成迷你波形（均参照微信）。
            let waveSize = currentReleaseAction == .cancel
                ? CGSize(width: 32, height: 14)
                : CGSize(width: 68, height: 14)
            setWaveformFrame(CGRect(
                x: contentBounds.midX - waveSize.width / 2,
                y: (contentBounds.height - 10 - waveSize.height) / 2,
                width: waveSize.width,
                height: waveSize.height
            ))
            activityIndicator.center = CGPoint(x: contentBounds.midX, y: contentBounds.midY - 5)
        }
        waveformView.setAppearance(
            barColor: currentReleaseAction == .cancel ? Self.waveformRed : Self.waveformGreen,
            animated: !isHidden
        )
    }

    /// 波形 frame 更新：气泡形变（path 动画）期间，波形的位置也用同节奏动画跟随，避免瞬移。
    private func setWaveformFrame(_ frame: CGRect) {
        let targetCenter = CGPoint(x: frame.midX, y: frame.midY)
        let positionChanged = !waveformView.center.isApproximatelyEqual(to: targetCenter)
        let fromPosition = waveformView.layer.presentation()?.position ?? waveformView.layer.position
        setFrameIfNeeded(frame, for: waveformView)
        guard positionChanged, !isHidden, !waveformView.isHidden else { return }

        waveformView.layer.add(
            AppAgentVoiceBubbleView.makeAppearanceAnimation(
                keyPath: "position",
                from: NSValue(cgPoint: fromPosition),
                to: NSValue(cgPoint: waveformView.layer.position)
            ),
            forKey: "appagent.voice.waveformPosition"
        )
    }

    private func preferredBubbleFrame(hasTranscript: Bool) -> CGRect {
        refreshGeometryCacheIfNeeded()
        let zones = cachedActionZoneFrames
        // 气泡底部（尾巴尖）在取消/录音/有文字三种状态下保持同一水平线（参照微信），
        // 有文字后气泡先随文字变宽，到达最大宽度后随行数向上长高。
        // 编辑态下底部改为悬在编辑按钮上方（随键盘上移）。
        let bubbleBottom = isEditingModeActive
            ? editSession.controlsCircleY(in: bounds, safeBottom: safeAreaInsets.bottom) - 24
            : zones.cancel.minY - 152
        let safeTop = safeAreaInsets.top

        if hasTranscript {
            // 最大宽度：两侧各距屏幕边缘 40；编辑态直接展开到最大宽度。
            let horizontalTextPadding = Self.bubbleTextInset.left + Self.bubbleTextInset.right
            let verticalTextPadding = Self.bubbleTextInset.top + Self.bubbleTextInset.bottom
            let maxWidth = max(0, bounds.width - 80)
            let width = isEditingModeActive
                ? maxWidth
                : AppAgentGeometry.clamp(
                    measuredTranscriptNaturalWidth() + horizontalTextPadding,
                    min(146, maxWidth),
                    maxWidth
                )
            let labelWidth = max(0, width - horizontalTextPadding)
            let textHeight = measuredTranscriptHeight(for: labelWidth)
            let maxHeight = max(104, bubbleBottom - (safeTop + 96))
            let height = AppAgentGeometry.clamp(textHeight + verticalTextPadding, 104, maxHeight)
            return CGRect(
                x: (bounds.width - width) / 2,
                y: bubbleBottom - height,
                width: width,
                height: height
            )
        }

        switch currentReleaseAction {
        case .cancel:
            // 取消态：小号方形红色气泡，靠左 20（参照微信取消态）。
            let size: CGFloat = 78
            return CGRect(x: 20, y: bubbleBottom - size, width: size, height: size)
        case .send, .edit:
            // 录音态：居中的小绿气泡（参照微信录音态）。
            let width: CGFloat = 146
            let height: CGFloat = 80
            return CGRect(x: (bounds.width - width) / 2, y: bubbleBottom - height, width: width, height: height)
        }
    }

    private func bubbleTailXRatio(for bubbleFrame: CGRect) -> CGFloat {
        let targetX: CGFloat
        switch currentReleaseAction {
        case .send:
            targetX = cachedBottomPanelFrame.midX
        case .cancel:
            // 取消态小气泡：尾巴固定居中。
            return 0.5
        case .edit:
            targetX = cachedActionZoneFrames.edit.midX
        }

        guard bubbleFrame.width > 0 else { return 0.5 }
        return (targetX - bubbleFrame.minX) / bubbleFrame.width
    }

    private func updateTranscriptText() {
        var text = showsTranscriptCursor && !transcriptText.isEmpty
            ? transcriptText + "|"
            : transcriptText
        // 结尾是换行时补一个零宽空格：UILabel 测量会折叠尾部空行，
        // 而编辑态 textView 的光标会落在新行上，补齐后气泡高度能容纳光标行。
        if text.hasSuffix("\n") {
            text += "\u{200B}"
        }
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: UIColor.black,
                .font: Self.transcriptFont
            ]
        )
        if showsTranscriptCursor, !transcriptText.isEmpty {
            let cursorRange = NSRange(location: attributed.length - 1, length: 1)
            attributed.addAttributes(
                [
                    .foregroundColor: Self.cursorGreen,
                    .font: UIFont.systemFont(ofSize: 20, weight: .regular)
                ],
                range: cursorRange
            )
        }
        transcriptLabel.attributedText = attributed
    }

    @discardableResult
    private func refreshGeometryCacheIfNeeded() -> Bool {
        guard !cachedGeometryBounds.isApproximatelyEqual(to: bounds)
            || !cachedGeometrySafeAreaInsets.isApproximatelyEqual(to: safeAreaInsets) else {
            return false
        }

        cachedGeometryBounds = bounds
        cachedGeometrySafeAreaInsets = safeAreaInsets
        cachedBottomPanelFrame = makeBottomPanelFrame()
        cachedActionZoneFrames = makeActionZoneFrames(bottomPanelFrame: cachedBottomPanelFrame)
        return true
    }

    private func makeActionZoneFrames(bottomPanelFrame panelFrame: CGRect) -> (cancel: CGRect, edit: CGRect) {
        let zoneY = panelFrame.minY - AppAgentVoiceArcMetrics.actionTopExpansionFromBottomApex
        let zoneHeight = AppAgentVoiceArcMetrics.actionZoneHeight
        let cancel = CGRect(
            x: panelFrame.minX,
            y: zoneY,
            width: max(0, panelFrame.midX - AppAgentVoiceArcMetrics.actionCenterGap - panelFrame.minX),
            height: zoneHeight
        )
        let edit = CGRect(
            x: panelFrame.midX + AppAgentVoiceArcMetrics.actionCenterGap,
            y: zoneY,
            width: max(0, panelFrame.maxX - panelFrame.midX - AppAgentVoiceArcMetrics.actionCenterGap),
            height: zoneHeight
        )
        return (cancel, edit)
    }

    private func makeBottomPanelFrame() -> CGRect {
        let safeBottom = safeAreaInsets.bottom
        let panelHeight = Self.bottomPanelTopRevealHeight + AppAgentInputBar.barHeight + safeBottom
        return CGRect(
            x: 0,
            y: max(0, bounds.height - panelHeight),
            width: bounds.width,
            height: panelHeight
        )
    }

    private func measuredTranscriptHeight(for width: CGFloat) -> CGFloat {
        let text = transcriptLabel.attributedText?.string ?? ""
        guard cachedTranscriptMeasurementText != text
            || abs(cachedTranscriptMeasurementWidth - width) > 0.5 else {
            return cachedTranscriptMeasurementHeight
        }

        let height = transcriptLabel.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        cachedTranscriptMeasurementText = text
        cachedTranscriptMeasurementWidth = width
        cachedTranscriptMeasurementHeight = height
        return height
    }

    private func invalidateTranscriptMeasurementCache() {
        cachedTranscriptMeasurementText = ""
        cachedTranscriptMeasurementWidth = -1
        cachedTranscriptMeasurementHeight = 0
        cachedTranscriptNaturalWidthText = nil
        cachedTranscriptNaturalWidth = 0
    }

    /// 文字不换行时的自然宽度，用于让气泡宽度跟随文字增长。
    private func measuredTranscriptNaturalWidth() -> CGFloat {
        let text = transcriptLabel.attributedText?.string ?? ""
        if cachedTranscriptNaturalWidthText == text {
            return cachedTranscriptNaturalWidth
        }

        let width = transcriptLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ).width
        cachedTranscriptNaturalWidthText = text
        cachedTranscriptNaturalWidth = width
        return width
    }

    private func updateActivityIndicator(isLoading: Bool) {
        let shouldHide = !isLoading
        if activityIndicator.isHidden != shouldHide {
            activityIndicator.isHidden = shouldHide
        }

        if isLoading {
            if !activityIndicator.isAnimating {
                activityIndicator.startAnimating()
            }
        } else if activityIndicator.isAnimating {
            activityIndicator.stopAnimating()
        }
    }

    @discardableResult
    private func setFrameIfNeeded(_ frame: CGRect, for view: UIView) -> Bool {
        let oldSize = view.bounds.size
        let targetCenter = CGPoint(x: frame.midX, y: frame.midY)
        guard !oldSize.isApproximatelyEqual(to: frame.size)
            || !view.center.isApproximatelyEqual(to: targetCenter) else {
            return false
        }

        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = targetCenter
        return !oldSize.isApproximatelyEqual(to: view.bounds.size)
    }

}

// MARK: - AppAgentVoiceEditModeSessionHost

extension AppAgentVoiceInputOverlayView: AppAgentVoiceEditModeSessionHost {
    var editSessionHostView: UIView {
        self
    }

    var editSessionBubbleContentView: UIView {
        bubbleView.contentView
    }

    var editSessionBubbleBodyFrame: CGRect {
        currentBubbleBodyFrame
    }

    /// 编辑态文字变化：同步到 transcriptText 驱动气泡尺寸测量，气泡随文字增删连续形变。
    func editSessionTextDidChange(_ text: String) {
        transcriptText = text
        showsTranscriptCursor = false
        updateTranscriptText()
        invalidateTranscriptMeasurementCache()
        setNeedsLayout()
    }

    func editSessionKeyboardHeightDidChange(duration: TimeInterval) {
        guard isEditingModeActive, !isHidden else { return }
        UIView.animate(withDuration: max(duration, 0.01)) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    func editSessionDidTapCancel() {
        onEditCancel?()
    }

    func editSessionDidTapSend(_ text: String) {
        onEditSend?(text)
    }
}

private final class AppAgentVoiceInputOverlayBackgroundView: UIView {
    private let bottomColor: UIColor
    var gradientTopY: CGFloat = 0 {
        didSet {
            guard abs(gradientTopY - oldValue) > 0.5 else { return }
            setNeedsDisplay()
        }
    }

    init(bottomColor: UIColor) {
        self.bottomColor = bottomColor
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.bottomColor = .clear
        super.init(coder: coder)
        setup()
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
//        let topColor = bottomColor.withAlphaComponent(0)
        let topColor = bottomColor
        let colors = [topColor.cgColor, bottomColor.cgColor] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, 1]
        ) else { return }

        // 绘制思路：输入气泡顶部以上保持透明，从气泡顶部向底部线性过渡到原来的黑色遮罩；
        // overlay 自身仍保持透明，显示/隐藏动画继续只改本 view 的 alpha。
//        let topY = min(bounds.maxY, max(bounds.minY, gradientTopY))
        let topY: CGFloat = 0
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: topY),
            end: CGPoint(x: bounds.midX, y: bounds.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private func setup() {
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }
}

#endif
