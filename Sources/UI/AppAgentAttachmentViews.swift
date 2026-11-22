//
//  AppAgentAttachmentViews.swift
//  AppAgentUI
//
//  输入栏「+」相关的三块视图：
//   - 功能面板：点加号后顶替键盘出现在输入栏下方（参考微信「更多」面板），图标 + 文字的方格按 4 列排开；
//   - 附件条：选好的图片 / 文件以缩略图排在输入栏最上面一行，右上角的叉可以移除；
//   - 缩略图：附件条与用户气泡共用，气泡里不带叉。
//

#if canImport(UIKit)
import BOUIKit
import ImageIO
import UIKit

/// 「+」面板里的一项能力。
public enum AppAgentInputBarAttachmentSource: CaseIterable, Sendable {
    /// 系统相册（PHPicker，无需相册权限）。
    case photoLibrary
    /// 系统文件选择器。
    case file

    var title: String {
        switch self {
        case .photoLibrary:
            return "图片"
        case .file:
            return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .photoLibrary:
            return "photo"
        case .file:
            return "folder"
        }
    }
}

// MARK: - Panel

/// 加号面板：作为输入框的 `inputView` 顶替键盘出现。
///
/// 走 `inputView` 而不自己在输入栏下面摆一块视图：键盘与面板互切由系统负责动画，
/// 控制器现有的「随键盘顶起」链路（`keyboardWillChangeFrame`）原样生效，面板高度就是新的键盘高度。
final class AppAgentAttachmentPanelView: UIInputView {
    static let columnCount = 4
    static let contentHeight: CGFloat = 128
    private static let horizontalInset: CGFloat = 24
    private static let topInset: CGFloat = 20

    var onSelect: ((AppAgentInputBarAttachmentSource) -> Void)?

    private let gridView = UIView()
    private(set) var tiles: [AppAgentAttachmentPanelTile] = []

    init(sources: [AppAgentInputBarAttachmentSource]) {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.contentHeight),
            inputViewStyle: .default
        )
        allowsSelfSizing = true
        // 与输入栏同底色，面板和输入栏连成一片；方格用浅灰块区分。
        backgroundColor = AppAgentAppearance.inputBarBackground

        gridView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: topAnchor),
            gridView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            gridView.heightAnchor.constraint(equalToConstant: Self.contentHeight),
            gridView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        ])

        for source in sources {
            let tile = AppAgentAttachmentPanelTile(source: source)
            tile.addTarget(self, action: #selector(tileTapped(_:)), for: .touchUpInside)
            gridView.addSubview(tile)
            tiles.append(tile)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutTiles(in: gridView.bounds.width)
    }

    /// 方格按固定列数等分横向空间，一格一格从左到右、从上到下排。
    func layoutTiles(in width: CGFloat) {
        let columns = CGFloat(Self.columnCount)
        let columnWidth = max(0, (width - Self.horizontalInset * 2) / columns)
        let tileSize = AppAgentAttachmentPanelTile.size
        for (index, tile) in tiles.enumerated() {
            let column = CGFloat(index % Self.columnCount)
            let row = CGFloat(index / Self.columnCount)
            let x = Self.horizontalInset + columnWidth * column + (columnWidth - tileSize.width) / 2
            let y = Self.topInset + row * (tileSize.height + Self.topInset)
            tile.frame = CGRect(origin: CGPoint(x: x, y: y), size: tileSize)
        }
    }

    @objc private func tileTapped(_ tile: AppAgentAttachmentPanelTile) {
        onSelect?(tile.source)
    }
}

/// 面板里的一格：上面圆角方块里一个图标，下面一行文字。
final class AppAgentAttachmentPanelTile: UIControl {
    static let iconBoxSide: CGFloat = 60
    static let size = CGSize(width: 72, height: iconBoxSide + 8 + 18)

    let source: AppAgentInputBarAttachmentSource
    private let iconBox = UIView()
    private let iconView = UIImageView()
    let titleLabel = UILabel()

    init(source: AppAgentInputBarAttachmentSource) {
        self.source = source
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        iconBox.isUserInteractionEnabled = false
        iconBox.layer.cornerRadius = 14
        iconBox.backgroundColor = AppAgentAppearance.attachmentTileBackground
        iconView.image = UIImage(
            systemName: source.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        )
        iconView.tintColor = AppAgentAppearance.icon
        iconView.contentMode = .center
        titleLabel.text = source.title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = AppAgentAppearance.secondaryText
        titleLabel.textAlignment = .center
        addSubview(iconBox)
        iconBox.addSubview(iconView)
        addSubview(titleLabel)
        accessibilityLabel = source.title
        accessibilityTraits = .button
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.iconBoxSide
        iconBox.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        iconView.frame = iconBox.bounds
        titleLabel.frame = CGRect(x: 0, y: side + 8, width: bounds.width, height: 18)
    }

    override var isHighlighted: Bool {
        didSet {
            iconBox.alpha = isHighlighted ? 0.6 : 1
        }
    }
}

// MARK: - Thumbnail

/// 一个附件的方形缩略图：图片铺满裁切，文件显示文档图标 + 文件名。
/// `onRemove` 非 nil 时右上角压一个叉（附件条用）；气泡里只展示，不带叉。
final class AppAgentAttachmentThumbnailView: UIView {
    static let side: CGFloat = 72
    /// 叉的圆心落在缩略图右上角，一半露在外面，所以整格要比缩略图大出这么一圈。
    static let removeOverhang: CGFloat = 7
    private static let removeButtonSide: CGFloat = removeOverhang * 2 + 6

    let attachment: AIAgentMessage.Attachment
    private let contentBox = UIView()
    private let imageView = UIImageView()
    private let fileIconView = UIImageView()
    private let fileNameLabel = UILabel()
    let removeButton = UIButton(type: .custom)

    var onRemove: ((String) -> Void)? {
        didSet {
            removeButton.isHidden = onRemove == nil
        }
    }

    /// 带叉时整格的尺寸（缩略图 + 右上角外伸）。
    static var removableSize: CGSize {
        CGSize(width: side + removeOverhang, height: side + removeOverhang)
    }

    init(attachment: AIAgentMessage.Attachment) {
        self.attachment = attachment
        super.init(frame: .zero)

        contentBox.layer.cornerRadius = 10
        contentBox.clipsToBounds = true
        contentBox.backgroundColor = AppAgentAppearance.attachmentTileBackground
        addSubview(contentBox)

        switch attachment.kind {
        case .image:
            imageView.contentMode = .scaleAspectFill
            imageView.image = AppAgentAttachmentImageCache.shared.thumbnail(for: attachment)
            contentBox.addSubview(imageView)
            accessibilityLabel = "图片"
        case .file:
            fileIconView.image = UIImage(
                systemName: "doc.text",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            )
            fileIconView.tintColor = AppAgentAppearance.icon
            fileIconView.contentMode = .center
            fileNameLabel.text = attachment.name
            fileNameLabel.font = .systemFont(ofSize: 10)
            fileNameLabel.textColor = AppAgentAppearance.secondaryText
            fileNameLabel.textAlignment = .center
            fileNameLabel.numberOfLines = 2
            fileNameLabel.lineBreakMode = .byTruncatingMiddle
            contentBox.addSubview(fileIconView)
            contentBox.addSubview(fileNameLabel)
            accessibilityLabel = "文件 \(attachment.name)"
        }
        isAccessibilityElement = true

        removeButton.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            ),
            for: .normal
        )
        removeButton.tintColor = UIColor.black.withAlphaComponent(0.65)
        removeButton.backgroundColor = .white
        removeButton.layer.cornerRadius = Self.removeButtonSide / 2
        removeButton.accessibilityLabel = "移除"
        removeButton.bo_hitAreaOutsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        removeButton.isHidden = true
        addSubview(removeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.side
        let top = removeButton.isHidden ? 0 : Self.removeOverhang
        contentBox.frame = CGRect(x: 0, y: top, width: side, height: side)
        imageView.frame = contentBox.bounds
        fileIconView.frame = CGRect(x: 0, y: 8, width: side, height: 28)
        fileNameLabel.frame = CGRect(x: 4, y: 38, width: side - 8, height: side - 42)
        let buttonSide = Self.removeButtonSide
        removeButton.frame = CGRect(
            x: contentBox.frame.maxX - buttonSide / 2 - 3,
            y: contentBox.frame.minY - buttonSide / 2 + 3,
            width: buttonSide,
            height: buttonSide
        )
    }

    @objc private func removeTapped() {
        onRemove?(attachment.id)
    }
}

// MARK: - Strip

/// 一排缩略图，横向放不下时可以左右滑。附件条与用户气泡共用：
/// 附件条左对齐、带叉；气泡右对齐（贴着用户气泡）、不带叉。
final class AppAgentAttachmentStripView: UIScrollView {
    static let spacing: CGFloat = 8

    /// 非 nil 表示可移除（附件条），缩略图右上角显示叉。
    var onRemove: ((String) -> Void)?
    /// 点最后那个加号格（附件条用）。
    var onAdd: (() -> Void)?
    /// 是否在缩略图右边显示加号格；图片选满后由输入栏关掉。
    var showsAddButton = false {
        didSet {
            addButton.isHidden = !showsAddButton
            setNeedsLayout()
        }
    }
    var alignsTrailing = false
    /// 首尾留白：气泡里与用户气泡的右边距对齐。
    var horizontalInset: CGFloat = 0

    private(set) var thumbnails: [AppAgentAttachmentThumbnailView] = []
    let addButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        clipsToBounds = true

        addButton.setImage(
            UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
            ),
            for: .normal
        )
        addButton.tintColor = AppAgentAppearance.secondaryText
        addButton.backgroundColor = AppAgentAppearance.attachmentTileBackground
        addButton.layer.cornerRadius = 10
        addButton.accessibilityLabel = "添加图片"
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addButton.isHidden = true
        addSubview(addButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 高度：可移除时要把叉的外伸算进去。
    var preferredHeight: CGFloat {
        onRemove == nil ? AppAgentAttachmentThumbnailView.side : AppAgentAttachmentThumbnailView.removableSize.height
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: thumbnails.isEmpty ? 0 : preferredHeight)
    }

    @objc private func addTapped() {
        onAdd?()
    }

    func setAttachments(_ attachments: [AIAgentMessage.Attachment]) {
        let ids = attachments.map(\.id)
        guard ids != thumbnails.map(\.attachment.id) else {
            return
        }
        for view in thumbnails {
            view.removeFromSuperview()
        }
        thumbnails = attachments.map { attachment in
            let view = AppAgentAttachmentThumbnailView(attachment: attachment)
            view.onRemove = onRemove
            addSubview(view)
            return view
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let removable = onRemove != nil
        let size = removable
            ? AppAgentAttachmentThumbnailView.removableSize
            : CGSize(width: AppAgentAttachmentThumbnailView.side, height: AppAgentAttachmentThumbnailView.side)
        let showsAdd = showsAddButton && !thumbnails.isEmpty
        let count = CGFloat(thumbnails.count + (showsAdd ? 1 : 0))
        let contentWidth = count > 0 ? count * size.width + (count - 1) * Self.spacing : 0
        let startX = alignsTrailing
            ? max(horizontalInset, bounds.width - horizontalInset - contentWidth)
            : horizontalInset
        for (index, view) in thumbnails.enumerated() {
            let x = startX + CGFloat(index) * (size.width + Self.spacing)
            view.frame = CGRect(origin: CGPoint(x: x, y: 0), size: size)
        }
        // 加号格与缩略图本体对齐（不含叉的外伸），排在最后一张右边。
        addButton.isHidden = !showsAdd
        if showsAdd {
            let side = AppAgentAttachmentThumbnailView.side
            let x = startX + CGFloat(thumbnails.count) * (size.width + Self.spacing)
            addButton.frame = CGRect(x: x, y: size.height - side, width: side, height: side)
        }
        let newContentSize = CGSize(
            width: max(contentWidth + horizontalInset * 2, bounds.width),
            height: bounds.height
        )
        if contentSize != newContentSize {
            contentSize = newContentSize
        }
    }
}

// MARK: - Image cache

/// 图片附件缩略图缓存：消息里存的是发给模型的整张 JPEG（base64），列表滚动时不能每次都整张解码。
/// 按附件 id 缓存一张小图；id 随附件落盘，跨重建、跨重启都稳定。
@MainActor
final class AppAgentAttachmentImageCache {
    static let shared = AppAgentAttachmentImageCache()
    private static let thumbnailPixelSize = 240

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 64
    }

    func store(_ image: UIImage, for id: String) {
        cache.setObject(image, forKey: id as NSString)
    }

    func thumbnail(for attachment: AIAgentMessage.Attachment) -> UIImage? {
        if let cached = cache.object(forKey: attachment.id as NSString) {
            return cached
        }
        guard let base64 = attachment.image?.base64,
              let data = Data(base64Encoded: base64),
              let image = Self.downsample(data, maxPixelSize: Self.thumbnailPixelSize) else {
            return nil
        }
        store(image, for: attachment.id)
        return image
    }

    static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
#endif
