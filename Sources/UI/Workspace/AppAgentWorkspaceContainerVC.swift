//
//  AppAgentWorkspaceContainerVC.swift
//  AppAgent — 工作区容器（全局一个，里面只放那一个工作区页面）
//
//  由宿主经 `AppAgentWorkspaceHost.mountWorkspaceContainer(_:)` 挂进自己的界面层级。
//  内部用标准 UIKit containment 承载当前页面：增删 child 驱动真实 appear/disappear
//  （而非 isHidden，后者不触发生命周期回调）。没有页面时隐藏根视图，让触摸回到宿主页面。
//

#if canImport(UIKit)
import UIKit

@MainActor
final class AppAgentWorkspaceContainerVC: UIViewController {

    /// 当前挂载的页面（nil = 未展示任何页面）。
    private(set) var currentChild: AppAgentWorkspacePageVC?

    weak var host: AppAgentWorkspaceHost?

    private var isMounted = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // 自身透明；隐藏（无 child）时不应遮挡宿主触摸。
        view.backgroundColor = .clear
        view.isHidden = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        currentChild?.view.frame = view.bounds
    }

    /// 挂进宿主界面；已挂上时直接返回 true。
    @discardableResult
    func mount() -> Bool {
        guard !isMounted else {
            return true
        }
        isMounted = host?.mountWorkspaceContainer(self) == true
        return isMounted
    }

    /// 收起当前页面并从宿主界面移除。
    func unmount() {
        hidePage()
        guard isMounted else {
            return
        }
        if host?.unmountWorkspaceContainer(self) == true {
            isMounted = false
        }
    }

    /// 展示某个页面：先移除现有 child，再加入新的。传入与当前相同的实例时，刷新尺寸并确保容器可见。
    func showPage(_ page: AppAgentWorkspacePageVC) {
        if currentChild === page {
            page.view.frame = view.bounds
            view.isHidden = false
            return
        }
        removeCurrentChild()

        addChild(page)
        page.beginAppearanceTransition(true, animated: false)
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentChild = page
        view.isHidden = false
        view.addSubview(page.view)
        page.didMove(toParent: self)
        page.endAppearanceTransition()
    }

    /// 收起当前页面：移除 child（触发 disappear），使容器不再遮挡宿主页面。
    func hidePage() {
        removeCurrentChild()
    }

    private func removeCurrentChild() {
        guard let child = currentChild else {
            // 空容器也必须隐藏；不为关闭操作主动加载视图。
            viewIfLoaded?.isHidden = true
            return
        }
        child.deactivate()
        currentChild = nil
        child.beginAppearanceTransition(false, animated: false)
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        child.endAppearanceTransition()
        viewIfLoaded?.isHidden = true
    }
}

#endif
