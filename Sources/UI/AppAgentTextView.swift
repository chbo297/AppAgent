//
//  AppAgentTextView.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 输入栏的多行文本输入：按内容长高，最多展示 `maximumVisibleLineCount` 行，超过后在框内上下滚动。
///
/// 文字贴满自身 `bounds`，没有上下左右内边距：可见区之外的行不会从边距里露出半截。
/// 高度由外部按 `fittingHeight(forWidth:)` 决定，这里不自己改 frame。
public final class AppAgentTextView: UITextView {

    /// 最多展开的可见行数，参考地图 LUI 输入栏并放宽到 7 行；超出后滚动查看。
    public static let maximumVisibleLineCount = 7

    /// 占位文字。`UITextView` 没有原生 placeholder，由一个不参与交互的 label 承载。
    public var placeholder: NSAttributedString? {
        get {
            placeholderLabel.attributedText
        }
        set {
            placeholderLabel.attributedText = newValue
        }
    }

    public override var text: String! {
        didSet {
            updatePlaceholderVisibility()
        }
    }

    public override var font: UIFont? {
        didSet {
            placeholderLabel.font = font
            setNeedsLayout()
        }
    }

    private let placeholderLabel = UILabel()

    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 单行文字的高度。
    var lineHeight: CGFloat {
        ceil((font ?? .systemFont(ofSize: 15)).lineHeight)
    }

    /// 展开到最大行数时的高度；超过它就固定在这个高度、改为框内滚动。
    var maximumHeight: CGFloat {
        lineHeight * CGFloat(Self.maximumVisibleLineCount)
    }

    /// 在给定宽度下排完全部文字所需的高度，至少一行，不受最大行数限制。
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else {
            return lineHeight
        }
        let fitting = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return max(lineHeight, ceil(fitting))
    }

    /// 文字超过可见高度、需要在框内滚动查看。用内容排版高度判断，不依赖 `contentSize`：
    /// 后者要等下一轮 layout 才更新，frame 刚长高时它还是旧值，会把该滚动的判定成不滚动。
    var isContentScrollable: Bool {
        textHeight(forWidth: bounds.width) > bounds.height + 0.5
    }

    /// 按当前内容排版高度；首行至少一行。文本宽度不足时按 frame 宽度排版。
    func textHeight(forWidth width: CGFloat) -> CGFloat {
        max(lineHeight, fittingHeight(forWidth: max(1, width)))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
        // 文字容器宽度必须等于实际 frame 宽度：输入源按钮显隐会改变 frame 宽度，而 UITextView 的
        // 折行、`sizeThatFits`、`contentSize` 都看容器宽度，不显式同步就会用旧宽度排版，
        // 出现「测出来的行数与画出来不一致」。
        if abs(textContainer.size.width - bounds.width) > 0.5 {
            textContainer.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
        }
    }

    private func setup() {
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        // 状态栏点按「回到顶部」留给对话列表，不让输入框抢走。
        scrollsToTop = false

        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.lineBreakMode = .byTruncatingTail
        addSubview(placeholderLabel)
        // 用户输入不经过 `text` 的 setter，靠系统通知同步占位文字。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextDidChange),
            name: UITextView.textDidChangeNotification,
            object: self
        )
        updatePlaceholderVisibility()
    }

    @objc private func handleTextDidChange() {
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }
}

#endif
