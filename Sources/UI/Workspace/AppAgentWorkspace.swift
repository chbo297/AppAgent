//
//  AppAgentWorkspace.swift
//  AppAgent — 工作区渲染器（唯一入口）
//
//  工作区数据属于会话（`AISession.workspace`），这里只负责把**当前会话**的那份显示出来：
//  全局一个容器、一个页面、一个 WebView、一个插槽视图，切会话只换数据。
//  容器放在对话界面的会话容器里（`AppAgentSessionContainerView`，对话面板之下），不进宿主的界面层级；
//  输入栏收成小球时随会话内容一起收起。
//  后台会话改自己的数据不触发任何界面变化，等它成为当前会话时才按数据刷新。
//
//  宿主接入：实现 `AppAgentWorkspaceHost`，调 `install(host:chatViewController:)`，
//  再把 `AppAgentWorkspaceTool` 注册给模型。对话面板的事件由 SDK 内部直接送到这里，宿主不用转发。
//

#if canImport(UIKit)
import UIKit

@MainActor
public final class AppAgentWorkspace: NSObject {

    public static let shared = AppAgentWorkspace()

    private let container = AppAgentWorkspaceContainerVC()
    private let page = AppAgentWorkspacePageVC()
    private weak var host: AppAgentWorkspaceHost?
    private weak var chatViewController: AppAgentViewController?

    /// 每个插槽名一个视图，第一次需要时向宿主要，切会话只 bind 新数据。
    private var slotViews: [String: any AppAgentWorkspaceSlotView] = [:]

    /// 会话内容（对话面板 + 工作区）可见：对话界面在显示，且输入栏不是收起的小球。
    private var sessionContentVisible = false
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var isObserving = false

    private static let accessibilityName = "工作区页面"

    private override init() {
        super.init()
        page.workspace = self
        page.onCollapse = { [weak self] in
            self?.collapseFromPage()
        }
        page.onStateChange = { [weak self] sessionId, key, value in
            self?.pageDidWriteState(sessionId: sessionId, key: key, value: value)
        }
    }

    // MARK: - 装配

    /// 接入宿主并绑定对话面板。宿主的开关变化后再调一次即可：开启时按当前会话显示，
    /// 关闭时收起并释放页面和插槽视图（会话里的数据不动）。
    public func install(host: AppAgentWorkspaceHost, chatViewController: AppAgentViewController) {
        self.host = host
        page.host = host
        startObservingIfNeeded()
        if self.chatViewController !== chatViewController {
            self.chatViewController = chatViewController
            chatViewController.workspace = self
            chatViewController.onNavigationAccessoryTapped = { [weak self] in
                self?.toggleFromAccessory()
            }
            let state = chatViewController.uiState
            sessionContentVisible = state.isWindowVisible && !state.isInputBarCollapsed
        }
        if host.workspaceIsEnabled() {
            render()
        } else {
            shutDown()
        }
    }

    /// 宿主开关是否开启。未接入宿主时为 false。
    public func isEnabled() -> Bool {
        host?.workspaceIsEnabled() == true
    }

    // MARK: - 给宿主和工具用的前台信息

    /// 同步门禁：该会话是当前会话，会话内容可见（输入栏未收成小球），且 App 在前台。
    /// 检查与界面写入须在同一 MainActor 执行段内，中间不能 await。不看工作区开关，宿主改界面的工具也用它。
    public func canAffectHostUI(sessionId: String) -> Bool {
        guard applicationIsActive,
              UIApplication.shared.applicationState == .active,
              !sessionId.isEmpty,
              chatViewController?.currentSessionId == sessionId else {
            return false
        }
        return sessionContentVisible
    }

    /// 某会话正在前台显示的这个插槽的视图；拿到即表示可以改界面。宿主的工具经这里拿到自己放进去的视图。
    public func slotView(named name: String, forSession sessionId: String) -> (any AppAgentWorkspaceSlotView)? {
        guard isEnabled(), canAffectHostUI(sessionId: sessionId), isShowing(pageId: sessionId),
              page.slotName == name else {
            return nil
        }
        container.view.layoutIfNeeded()
        page.view.layoutIfNeeded()
        return page.slotView
    }

    /// 当前显示页面的运行情况（触摸分配、加载失败、脚本报错）；该会话的页面不在前台时为 nil。
    func liveReport(sessionId: String) -> JSONValue? {
        guard isShowing(pageId: sessionId) else {
            return nil
        }
        var report: [String: JSONValue] = ["touch": page.touchStatus()]
        if let failure = page.loadFailure {
            report["loadFailure"] = .string(failure)
        }
        report["scriptErrors"] = .array(page.scriptErrors.map(JSONValue.string))
        return .object(report)
    }

    private func isShowing(pageId: String) -> Bool {
        sessionContentVisible && container.currentChild != nil && page.pageId == pageId
            && container.viewIfLoaded?.isHidden == false
    }

    // MARK: - 对话面板事件（SDK 内部由 AppAgentViewController 直接调用）

    func chatViewController(_ sender: AppAgentViewController, didSwitchSessionTo sessionId: String?) {
        guard sender === chatViewController else {
            return
        }
        render()
    }

    func chatViewController(_ sender: AppAgentViewController, didChangeUIState state: AppAgentUIState) {
        guard sender === chatViewController else {
            return
        }
        sessionContentVisible = state.isWindowVisible && !state.isInputBarCollapsed
    }

    func chatViewControllerDidHidePanel(_ sender: AppAgentViewController) {
        guard sender === chatViewController else {
            return
        }
        sessionContentVisible = false
    }

    // MARK: - 插槽视图

    /// 插槽视图写自己的状态：存进该会话的 `workspace.slots[slot].state`（value 为 nil 删掉这个 key）。
    /// 会话不在前台也能写；切到它时 SDK 把这份状态交给 `bind`。
    public func updateSlotState(_ changes: [String: String?], slot name: String, sessionId: String) throws {
        guard let session = chatViewController?.agent?.session(id: sessionId) else {
            throw SessionWorkspaceError("workspace session is gone")
        }
        try session.updateWorkspace { workspace in
            var slot = workspace.slots[name] ?? SessionWorkspace.Slot()
            for (key, value) in changes {
                slot.state[key] = value
            }
            workspace.slots[name] = slot
        }
    }

    /// 某会话保存的插槽状态（宿主工具在页面不在前台时读）。会话不存在时为 nil。
    public func slotState(slot name: String, sessionId: String) -> [String: String]? {
        guard let session = chatViewController?.agent?.session(id: sessionId) else {
            return nil
        }
        return session.workspace.slots[name]?.state ?? [:]
    }

    func sharedSlotView(named name: String) throws -> any AppAgentWorkspaceSlotView {
        if let made = slotViews[name] {
            return made
        }
        guard let host else {
            throw AppAgentWorkspaceH5Error.invalid("the slot layer needs a host view, but no workspace host is installed")
        }
        let made = try host.makeWorkspaceSlotView(named: name)
        slotViews[name] = made
        return made
    }

    private func disposeSlotViews() {
        page.detachSlotView()
        for slot in slotViews.values {
            slot.dispose()
        }
        slotViews = [:]
    }

    // MARK: - 显示

    private func currentSession() -> AISession? {
        guard let id = chatViewController?.currentSessionId else {
            return nil
        }
        return chatViewController?.agent?.session(id: id)
    }

    /// 让界面和数据对齐：显示当前会话的工作区（如果它要显示）。
    @discardableResult
    private func render() -> Bool {
        defer {
            refreshNavigationAccessory()
        }
        guard applicationIsActive, UIApplication.shared.applicationState == .active, isEnabled() else {
            container.hidePage()
            return false
        }
        guard let session = currentSession(), session.workspace.isShown, session.workspace.hasContent else {
            container.hidePage()
            return false
        }
        return show(pageId: session.id, workspace: session.workspace, title: session.title)
    }

    private func show(pageId: String, workspace data: SessionWorkspace, title: String) -> Bool {
        guard container.attach(to: chatViewController) else {
            container.hidePage()
            return false
        }
        do {
            try page.render(pageId: pageId, workspace: data, fallbackTitle: title)
        } catch {
            Logger.info("AppAgentWorkspace", "page \(pageId) failed: \(error.localizedDescription)")
            container.hidePage()
            return false
        }
        container.showPage(page)
        container.view.layoutIfNeeded()
        page.view.layoutIfNeeded()
        page.setWorkspaceActive(true)
        return true
    }

    /// 功能关闭：收起并释放页面和插槽视图，把容器从会话容器里移除。会话里的数据不动。
    private func shutDown() {
        container.hidePage()
        page.releaseResources()
        disposeSlotViews()
        container.detach()
        refreshNavigationAccessory()
    }

    // MARK: - 用户操作（不经工具门禁）

    /// 页面左上角的收起按钮，或页面按钮调了宿主动作：把当前会话工作区的「显示」改成关。
    private func collapseFromPage() {
        _ = try? currentSession()?.updateWorkspace { workspace in
            workspace.isShown = false
        }
    }

    private func pageDidWriteState(sessionId: String, key: String, value: String?) {
        _ = try? chatViewController?.agent?.session(id: sessionId)?.updateWorkspace { workspace in
            workspace.h5.state[key] = value
        }
    }

    /// 顶栏开关：当前会话的工作区有内容时才出现，亮暗表示是否显示。
    private func refreshNavigationAccessory() {
        guard let chatViewController else {
            return
        }
        guard isEnabled(), let session = currentSession(), session.workspace.hasContent else {
            chatViewController.navigationAccessory = nil
            return
        }
        chatViewController.navigationAccessory = AppAgentNavigationAccessory(
            isActive: session.workspace.isShown,
            accessibilityName: Self.accessibilityName
        )
    }

    private func toggleFromAccessory() {
        _ = try? currentSession()?.updateWorkspace { workspace in
            workspace.isShown.toggle()
        }
    }

    // MARK: - 生命周期

    private func startObservingIfNeeded() {
        guard !isObserving else {
            return
        }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleMemoryWarning),
                           name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(forName: AISession.workspaceDidChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let session = note.object as? AISession else {
                return
            }
            let sessionId = session.id
            Task { @MainActor [weak self] in
                self?.workspaceDidChange(sessionId: sessionId)
            }
        }
    }

    /// 只有当前会话的数据变化才刷新界面；后台会话的改动等切过去时再生效。
    private func workspaceDidChange(sessionId: String) {
        guard chatViewController?.currentSessionId == sessionId else {
            return
        }
        render()
    }

    @objc private func handleMemoryWarning() {
        guard container.currentChild == nil else {
            return
        }
        page.releaseResources()
        disposeSlotViews()
    }

    @objc private func applicationWillResignActive() {
        applicationIsActive = false
        container.hidePage()
    }

    @objc private func applicationDidBecomeActive() {
        applicationIsActive = true
        render()
    }
}

#endif
