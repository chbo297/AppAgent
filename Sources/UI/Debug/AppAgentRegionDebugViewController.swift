//
//  AppAgentRegionDebugViewController.swift
//  AppAgentUI
//
//  调试窗口的 root VC：托管浮动按钮/面板，并按帧把三类响应区域的矩形
//  换算到调试窗口坐标系，用彩色边框画出来。
//

#if canImport(UIKit)
import UIKit

public final class AppAgentRegionDebugViewController: UIViewController {

    /// 被观测的 AppAgent 主控制器（弱引用，随宿主释放）。
    weak var target: AppAgentViewController?

    private let panel = AppAgentRegionDebugPanelView()
    private var outlines: [AppAgentInteractionRegion: AppAgentRegionOutlineView] = [:]
    private var displayLink: CADisplayLink?
    /// 折叠态按钮中心；nil 表示还没定位过，首次布局时落到右上角。
    private var collapsedCenter: CGPoint?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        for region in AppAgentInteractionRegion.allCases {
            // 上滑唤键盘区与点击区完全同尺寸，用虚线区分。
            let outline = AppAgentRegionOutlineView(region: region, isDashed: region == .keyboardSwipe)
            outline.isHidden = true
            view.addSubview(outline)
            outlines[region] = outline
        }

        panel.onExpansionChange = { [weak self] _ in self?.view.setNeedsLayout() }
        panel.onRegionVisibilityChange = { [weak self] region, isOn in
            self?.outlines[region]?.isHidden = !isOn
            self?.syncDisplayLink()
            self?.refreshOutlines()
        }
        panel.onDragToCenter = { [weak self] center in
            guard let self else { return }
            self.collapsedCenter = self.clampedCenter(center, size: AppAgentRegionDebugPanelView.collapsedSize)
            self.view.setNeedsLayout()
        }
        view.addSubview(panel)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanel()
        refreshOutlines()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopDisplayLink()
    }

    // MARK: - Panel layout

    private func layoutPanel() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }

        if collapsedCenter == nil {
            let inset = view.safeAreaInsets
            collapsedCenter = CGPoint(
                x: bounds.maxX - inset.right - 24 - AppAgentRegionDebugPanelView.collapsedSize.width / 2,
                y: bounds.minY + inset.top + 96
            )
        }
        guard let center = collapsedCenter else { return }

        if panel.isExpanded {
            let size = AppAgentRegionDebugPanelView.expandedSize
            // 展开时以折叠按钮位置为锚点，向左下展开，再夹回屏幕内。
            var origin = CGPoint(x: center.x - size.width + 20, y: center.y + 24)
            origin.x = min(max(8, origin.x), max(8, bounds.maxX - size.width - 8))
            origin.y = min(max(8, origin.y), max(8, bounds.maxY - size.height - 8))
            panel.frame = CGRect(origin: origin, size: size)
        } else {
            panel.bounds = CGRect(origin: .zero, size: AppAgentRegionDebugPanelView.collapsedSize)
            panel.center = clampedCenter(center, size: AppAgentRegionDebugPanelView.collapsedSize)
        }
    }

    private func clampedCenter(_ center: CGPoint, size: CGSize) -> CGPoint {
        let bounds = view.bounds
        guard bounds.width > size.width, bounds.height > size.height else { return center }
        return CGPoint(
            x: min(max(size.width / 2, center.x), bounds.maxX - size.width / 2),
            y: min(max(size.height / 2, center.y), bounds.maxY - size.height / 2)
        )
    }

    // MARK: - Region outlines

    /// 是否有任何一个区域正在显示；没有就不用每帧跑。
    private var hasVisibleRegion: Bool {
        AppAgentInteractionRegion.allCases.contains { panel.isOn($0) }
    }

    private func syncDisplayLink() {
        hasVisibleRegion ? startDisplayLink() : stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleTick() {
        refreshOutlines()
    }

    func refreshOutlines() {
        for region in AppAgentInteractionRegion.allCases {
            guard let outline = outlines[region] else { continue }
            guard panel.isOn(region), let rect = rect(for: region) else {
                outline.isHidden = true
                continue
            }
            outline.isHidden = false
            outline.frame = rect
            view.bringSubviewToFront(outline)
        }
        view.bringSubviewToFront(panel)
    }

    /// 把区域对应视图的矩形换算到调试窗口坐标系；不可见时返回 nil。
    func rect(for region: AppAgentInteractionRegion) -> CGRect? {
        guard let target else { return nil }
        let source: UIView
        var rectInSource: CGRect?
        switch region {
        case .inputTap, .keyboardSwipe:
            // 两者是同一块命中区：点击弹键盘和上滑唤键盘都以 extendedInputAreaHitRect 为准。
            source = target.inputBar
            rectInSource = target.inputBar.extendedInputAreaHitRect
        case .chatPanelSwipe:
            source = target.chatPanelView
        case .inputBarHit:
            source = target.inputBar
        }
        // 没上窗的视图不会显示，也就不该画框。
        guard source.window != nil else { return nil }
        return Self.outlineRect(source: source, container: view, rectInSource: rectInSource)
    }

    /// 纯几何部分：可见性判断 + 坐标换算，不依赖窗口，便于单测。
    /// `rectInSource` 为 nil 时用 `source.bounds`。
    static func outlineRect(
        source: UIView,
        container: UIView,
        rectInSource: CGRect? = nil
    ) -> CGRect? {
        guard isEffectivelyVisible(source) else { return nil }
        let sourceRect = rectInSource ?? source.bounds
        guard !sourceRect.isNull, !sourceRect.isEmpty else { return nil }

        let rect = container.convert(sourceRect, from: source)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    private static func isEffectivelyVisible(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return true
    }
}

#endif
