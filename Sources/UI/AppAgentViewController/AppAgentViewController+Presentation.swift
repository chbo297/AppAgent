//
//  AppAgentViewController+Presentation.swift
//  AppAgentUI
//
//  把「AppAgent 现在长在哪、挡住了宿主什么」报给宿主。
//
//  只有一个出口：`notifyPresentationChangeIfNeeded`。所有几何写入路径最后都汇到这里，
//  再按几何判等去重，所以多调几次无害、少调一次才要命。发射点有四类：
//    1. `applyInputBarFrame` —— 输入栏、面板容器、键盘避让（reason 由调用方给）
//    2. 面板可见区变化冒泡 —— 竖向拖拽拉高面板（`chatPanelHeightPan`）
//    3. 侧栏 / 语音浮层 / 决策卡片的显隐
//    4. `AppAgentOverlay.show()/hide()`（`visibility`）
//

#if canImport(UIKit)
import UIKit

extension AppAgentViewController {

    /// 宿主可随时主动查当前展示状态（push 之外的 pull 入口）。
    public var presentationState: AppAgentPresentationState {
        currentPresentationState(reason: .layout, animation: .immediate)
    }

    func notifyPresentationChangeIfNeeded(
        reason: AppAgentPresentationChangeReason,
        animation: AppAgentPresentationAnimation = .immediate
    ) {
        guard let delegate = presentationDelegate, isViewLoaded else { return }
        let state = currentPresentationState(reason: reason, animation: animation)
        // 判等只看几何与显隐：reason / animation 是伴随信息，不该把「同一份画面」报第二次。
        if let last = lastReportedPresentationState, last.hasSameGeometry(as: state) { return }
        lastReportedPresentationState = state
        delegate.appAgentPresentationDidChange(state)
    }

    private func currentPresentationState(
        reason: AppAgentPresentationChangeReason,
        animation: AppAgentPresentationAnimation
    ) -> AppAgentPresentationState {
        // window 被显式隐藏时什么都挡不住，areas 必须清空——宿主只看 areas 也不会判错。
        // 还没挂到 window 上（首次布局、单元测试）则照常给几何：见 `presentationCoordinateSpace`。
        let isHidden = view.window?.isHidden ?? false
        return AppAgentPresentationState(
            reason: reason,
            // 键盘那条路把 `layoutInputBar` 包在键盘自己的动画块里跑，inputBar 侧拿到的是
            // `.immediate`；真正的时长和曲线只有 ambient 那份记得住，宿主要靠它才能同速。
            animation: ambientKeyboardAnimation ?? animation,
            isWindowVisible: view.window != nil && !isHidden,
            isInputBarCollapsed: inputBar.isCollapsed,
            keyboardHeight: effectiveKeyboardHeight,
            areas: isHidden ? [] : currentOccludingAreas()
        )
    }

    /// 上报用的坐标系：宿主 window。
    ///
    /// 没挂到 window 上时退回控制器自己的 view——`AppAgentWindow` 全屏、`rootViewController.view`
    /// 铺满整个 window，两个坐标系在真实配置下**数值相同**，所以这不是近似而是等价；
    /// 同时让不能建 UIWindow 的 Catalyst package test 也能验证几何。
    private var presentationCoordinateSpace: UICoordinateSpace {
        view.window ?? view
    }

    /// 当前盖住宿主的所有区域。
    ///
    /// 对话面板取的是 **`viewportView`**：它 `clipsToBounds = true`，是裁切后真正可见的那块。
    /// 别换成容器 frame（容器按注释明确「不参与裁切」）或 `messageListFrame`（列表按完整
    /// contentArea 布局，底边通常在可见区外面——决策卡片就是踩这个坑踩出来的）。
    private func currentOccludingAreas() -> [AppAgentOccludingArea] {
        var areas: [AppAgentOccludingArea] = []
        appendOccludingArea(&areas, kind: .inputBar, source: inputBar)
        appendOccludingArea(&areas, kind: .chatPanel, source: chatPanelView.viewportView)
        appendOccludingArea(&areas, kind: .sessionSidebar, source: sessionSidebarView)
        appendOccludingArea(&areas, kind: .voiceInputOverlay, source: voiceInputOverlayView)
        appendOccludingArea(&areas, kind: .decisionCard, source: chatPanelView.decisionCard)
        return areas
    }

    private func appendOccludingArea(
        _ areas: inout [AppAgentOccludingArea],
        kind: AppAgentOccludingArea.Kind,
        source: UIView
    ) {
        guard source.isDescendant(of: view) else { return }
        let opacity = effectiveOpacity(of: source)
        guard opacity > 0.001,
              source.bounds.width > 0.5,
              source.bounds.height > 0.5 else { return }
        areas.append(
            AppAgentOccludingArea(
                kind: kind,
                frame: presentationCoordinateSpace.convert(source.bounds, from: source),
                opacity: opacity
            )
        )
    }

    /// 逐级乘上祖先的 alpha：面板淡出是写在**容器**上的，只看 viewport 自己的 alpha 会
    /// 报出「透明了但还在挡」的假遮挡。任意一级 hidden 直接算 0。
    private func effectiveOpacity(of source: UIView) -> CGFloat {
        var opacity = source.isHidden ? 0 : source.alpha
        var node = source.superview
        while let current = node, current !== view, opacity > 0 {
            opacity = current.isHidden ? 0 : opacity * current.alpha
            node = current.superview
        }
        return opacity
    }
}

extension AppAgentPresentationState {
    /// 几何与显隐是否完全一致（忽略 reason / animation）。
    func hasSameGeometry(as other: AppAgentPresentationState) -> Bool {
        isWindowVisible == other.isWindowVisible
            && isInputBarCollapsed == other.isInputBarCollapsed
            && abs(keyboardHeight - other.keyboardHeight) < 0.5
            && areas == other.areas
    }
}

#endif
