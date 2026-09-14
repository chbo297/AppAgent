//
//  AppAgentVoiceEditModeSession.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 编辑会话需要从宿主 overlay 获取/回写的最小接口。
///
/// 关键约束：编辑态必须与手势态共享同一个气泡视图（保证 path 形变连续），
/// 因此编辑态不是独立视图，而是一个操作宿主共享气泡的会话对象。
protocol AppAgentVoiceEditModeSessionHost: AnyObject {
    /// 挂载按钮与手势的宿主视图（overlay 自身）。
    var editSessionHostView: UIView { get }

    /// 气泡内容容器（bubbleView.contentView）：textView 挂在这里，与气泡形变同步移动。
    var editSessionBubbleContentView: UIView { get }

    /// 当前气泡 bodyFrame（宿主坐标系），用于点按命中判定。
    var editSessionBubbleBodyFrame: CGRect { get }

    /// 编辑文字变化：宿主同步 transcript 测量并触发重布局。
    func editSessionTextDidChange(_ text: String)

    /// 键盘高度变化：宿主触发带动画的重布局。
    func editSessionKeyboardHeightDidChange(duration: TimeInterval)

    func editSessionDidTapCancel()
    func editSessionDidTapSend(_ text: String)
}

/// 语音输入编辑会话：承载编辑态的 textView、取消/发送按钮、键盘跟随与点/滑收放键盘策略。
///
/// 生命周期：`begin(text:)` → 用户编辑/键盘交互 → 宿主经 cancel/send 回调收尾 → `end()`。
/// 视图在首次 begin 时挂载到宿主上，之后仅做显示/隐藏切换。
final class AppAgentVoiceEditModeSession: NSObject {

    private(set) var isActive = false

    weak var host: AppAgentVoiceEditModeSessionHost?

    /// 键盘当前遮挡高度，编辑态布局据此把按钮行贴在键盘上方。
    var keyboardHeight: CGFloat {
        keyboardObserver?.keyboardHeight ?? 0
    }

    var currentText: String {
        textView.text ?? ""
    }

    private static let cancelCircleSize: CGFloat = 62
    private static let sendButtonSize = CGSize(width: 116, height: 58)

    private let textView = UITextView()
    private let cancelButton = UIButton(type: .custom)
    private let cancelTitleLabel = UILabel()
    private let sendButton = UIButton(type: .custom)
    private var keyboardObserver: AppAgentKeyboardObserver?
    private var isMounted = false

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        gesture.cancelsTouchesInView = false
        gesture.isEnabled = false
        return gesture
    }()

    private lazy var panGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.cancelsTouchesInView = false
        gesture.isEnabled = false
        return gesture
    }()

    init(textFont: UIFont, textTintColor: UIColor) {
        super.init()
        configureViews(textFont: textFont, textTintColor: textTintColor)
    }

    // MARK: - 生命周期

    /// 进入编辑：挂载（首次）并展示编辑控件。键盘唤起由宿主布局完成后调用 activateKeyboard()。
    func begin(text: String) {
        mountIfNeeded()
        isActive = true
        textView.text = text
        setControlsHidden(false)
        tapGesture.isEnabled = true
        panGesture.isEnabled = true
    }

    func end() {
        guard isActive else { return }
        isActive = false
        textView.text = ""
        setControlsHidden(true)
        tapGesture.isEnabled = false
        panGesture.isEnabled = false
    }

    func activateKeyboard() {
        textView.becomeFirstResponder()
    }

    func resignKeyboard() {
        textView.resignFirstResponder()
    }

    // MARK: - 布局

    /// 编辑态按钮行（取消圆钮）的顶部 Y：键盘可见时贴着键盘上方，否则贴近屏幕底部安全区。
    func controlsCircleY(in bounds: CGRect, safeBottom: CGFloat) -> CGFloat {
        let bottomLimit = keyboardHeight > 0
            ? bounds.height - keyboardHeight - 12
            : bounds.height - safeBottom - 44
        let labelHeight: CGFloat = 18
        return bottomLimit - labelHeight - 6 - Self.cancelCircleSize
    }

    /// 布局按钮行与 textView。bubbleFrame 为宿主坐标系中的气泡 bodyFrame；
    /// textInset 由宿主传入，与文字气泡的测量补偿保持同源。
    func layout(in bounds: CGRect, safeBottom: CGFloat, bubbleFrame: CGRect, textInset: UIEdgeInsets) {
        let circleSize = Self.cancelCircleSize
        let circleY = controlsCircleY(in: bounds, safeBottom: safeBottom)
        cancelButton.frame = CGRect(x: 28, y: circleY, width: circleSize, height: circleSize)
        cancelTitleLabel.frame = CGRect(
            x: 28 + circleSize / 2 - 51,
            y: circleY + circleSize + 6,
            width: 102,
            height: 18
        )
        sendButton.frame = CGRect(
            x: bounds.width - 22 - Self.sendButtonSize.width,
            y: circleY + (circleSize - Self.sendButtonSize.height) / 2,
            width: Self.sendButtonSize.width,
            height: Self.sendButtonSize.height
        )

        // textView 在气泡内容容器坐标系内布局，随容器与气泡形变同步移动。
        let contentBounds = CGRect(origin: .zero, size: bubbleFrame.size)
        textView.frame = contentBounds.inset(by: textInset)
    }

    // MARK: - 视图与挂载

    private func configureViews(textFont: UIFont, textTintColor: UIColor) {
        textView.font = textFont
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.tintColor = textTintColor
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.delegate = self
        textView.isHidden = true

        cancelButton.backgroundColor = UIColor(white: 1, alpha: 0.22)
        cancelButton.layer.cornerRadius = Self.cancelCircleSize / 2
        cancelButton.tintColor = .white
        cancelButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            ),
            for: .normal
        )
        cancelButton.addTarget(self, action: #selector(handleCancelTapped), for: .touchUpInside)
        cancelButton.isHidden = true

        cancelTitleLabel.text = "取消"
        cancelTitleLabel.font = .systemFont(ofSize: 13)
        cancelTitleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        cancelTitleLabel.textAlignment = .center
        cancelTitleLabel.isHidden = true

        sendButton.backgroundColor = UIColor(white: 0.98, alpha: 1)
        sendButton.layer.cornerRadius = Self.sendButtonSize.height / 2
        sendButton.setTitle("发送", for: .normal)
        sendButton.setTitleColor(.black, for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        sendButton.addTarget(self, action: #selector(handleSendTapped), for: .touchUpInside)
        sendButton.isHidden = true
    }

    private func mountIfNeeded() {
        guard !isMounted, let host = host else { return }
        isMounted = true

        host.editSessionBubbleContentView.addSubview(textView)
        let hostView = host.editSessionHostView
        hostView.addSubview(cancelButton)
        hostView.addSubview(cancelTitleLabel)
        hostView.addSubview(sendButton)
        hostView.addGestureRecognizer(tapGesture)
        hostView.addGestureRecognizer(panGesture)

        let observer = AppAgentKeyboardObserver(referenceView: hostView)
        observer.onChange = { [weak self] _, duration in
            self?.host?.editSessionKeyboardHeightDidChange(duration: duration)
        }
        keyboardObserver = observer
    }

    private func setControlsHidden(_ hidden: Bool) {
        textView.isHidden = hidden
        cancelButton.isHidden = hidden
        cancelTitleLabel.isHidden = hidden
        sendButton.isHidden = hidden
    }

    // MARK: - 交互

    @objc private func handleCancelTapped() {
        guard isActive else { return }
        host?.editSessionDidTapCancel()
    }

    @objc private func handleSendTapped() {
        guard isActive else { return }
        host?.editSessionDidTapSend(currentText)
    }

    /// 点按策略：点气泡/textView 唤起键盘，点按钮交给按钮，点其余背景收起键盘。
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard isActive, let host = host else { return }
        let location = gesture.location(in: host.editSessionHostView)
        if cancelButton.frame.contains(location) || sendButton.frame.contains(location) {
            return
        }
        if host.editSessionBubbleBodyFrame.contains(location) {
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
        } else {
            textView.resignFirstResponder()
        }
    }

    /// 滑动策略：下拉收起键盘、上拉唤起键盘（与 inputBar 键盘交互策略一致的方向语义）。
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isActive, let host = host else { return }
        switch gesture.state {
        case .ended, .cancelled:
            let hostView = host.editSessionHostView
            let translationY = gesture.translation(in: hostView).y
            let velocityY = gesture.velocity(in: hostView).y
            if translationY > 40 || velocityY > 500 {
                textView.resignFirstResponder()
            } else if translationY < -40 || velocityY < -500 {
                textView.becomeFirstResponder()
            }
        default:
            break
        }
    }
}

// MARK: - UITextViewDelegate

extension AppAgentVoiceEditModeSession: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard isActive else { return }
        host?.editSessionTextDidChange(textView.text ?? "")
    }
}

#endif
