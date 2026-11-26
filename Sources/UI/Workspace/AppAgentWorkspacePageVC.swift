//
//  AppAgentWorkspacePageVC.swift
//  AppAgent — 工作区页面：H5 在上，需要时下面垫宿主的插槽视图
//
//  只由 `AppAgentWorkspace` 创建和驱动，宿主不直接接触。
//

#if canImport(UIKit)
import UIKit
import WebKit

private final class AppAgentWorkspaceWebView: WKWebView {
    var touchPolicy = AppAgentWorkspaceUIPolicy()
    var touchPolicyActive = false
    var hasSlot = false
    var occlusions: [CGRect] = []

    /// 最近一次被接受的上报来自哪种模式：auto（脚本自动测量）或 manual（页面 setTouchRegions）。
    var touchMode = "none"
    private var lastLoggedTouch: TimeInterval = -1

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let passes = touchPolicyActive && hasSlot
            && touchPolicy.resolve(.touch(point: point, size: bounds.size, occlusions: occlusions)) == .slot

        // 每次触摸只记一条，进诊断包的运行日志：拖不动插槽视图时先看触摸给了谁。
        if hasSlot, let event, event.type == .touches, event.timestamp != lastLoggedTouch {
            lastLoggedTouch = event.timestamp
            Logger.info("AppAgentWorkspace", "touch (\(Int(point.x)),\(Int(point.y))) -> \(passes ? "slot" : "web"), "
                + "policyActive=\(touchPolicyActive) regions=\(touchPolicy.regions.count) polygons=\(touchPolicy.polygons.count) "
                + "blocks=\(touchPolicy.blocks.count)")
        }
        if passes {
            // UIKit 在 touch began 时确定接收者；后续区域更新不改派已开始的手势。
            // canvas 仍接住未被插槽视图命中的事件，不会继续落到宿主页面。
            return nil
        }
        return super.hitTest(point, with: event)
    }

    func invalidateTouchPolicy() {
        touchPolicy.invalidate(size: bounds.size)
        touchPolicyActive = false
    }
}

private final class AppAgentWorkspaceBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: AppAgentWorkspacePageVC?

    init(owner: AppAgentWorkspacePageVC) {
        self.owner = owner
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.receiveBridgeMessage(message)
    }
}

/// 工作区页面：全局只有一个，哪个会话在前台就按哪个会话的数据显示。
/// 上层 H5、下层宿主的插槽视图，两层按数据各自显示或隐藏。只由 `AppAgentWorkspace` 驱动。
final class AppAgentWorkspacePageVC: UIViewController, WKNavigationDelegate {

    /// 正在显示的页面，就是会话 id。没有显示时为 nil。
    private(set) var pageId: String?
    var onCollapse: (() -> Void)?

    /// 页面自己写了一条状态（value 为 nil 表示删掉）。
    var onStateChange: ((String, String, String?) -> Void)?
    weak var host: AppAgentWorkspaceHost?
    weak var workspace: AppAgentWorkspace?

    /// 插槽视图：有插槽显示时才挂在本页，隐藏或离开前台就摘下（每个插槽名全局一个视图）。
    private(set) var slotView: (any AppAgentWorkspaceSlotView)?

    /// 挂着的插槽名。
    private(set) var slotName: String?

    /// 插槽视图当前绑定的页面；和 `pageId` 不同时要重新 bind。
    private var slotPageId: String?

    /// 左上角的收起按钮，与对话面板顶栏的工作区开关是同一个 SDK 控件，两处长得一样。
    private let toggleButton = AppAgentPageToggleButton(style: .floating)
    private let canvas = UIView()
    private var webView: AppAgentWorkspaceWebView?
    private var schemeHandler: AppAgentWorkspaceSchemeHandler?
    private var bridgeHandler: AppAgentWorkspaceBridgeHandler?
    private var content: AppAgentWorkspaceH5Content?
    private var renderedSource: RenderSource?

    /// 页面眼里的状态：页面自己写的先记在这里，回写的数据再到达时不重复通知页面。
    private var pageState: [String: String] = [:]
    private var isWorkspaceActive = false
    private var isPageReady = false

    /// 正在执行的页面动作；同一时间只跑一个。token 区分新旧动作，超时或宿主返回时只认当前这个。
    private var actionInFlight = false
    private var actionToken = 0
    private var keyboardFrame: CGRect = .null
    private var lastSafeAreaInsets = UIEdgeInsets.zero

    /// 最近一次加载的结果和页面脚本报的错，给模型 `read` 看。
    private(set) var loadFailure: String?
    private(set) var scriptErrors: [String] = []

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        canvas.backgroundColor = .clear
        canvas.clipsToBounds = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)

        // 页面正在显示，按钮始终是展开态；点一下收起，之后从顶栏的同款按钮再打开。
        toggleButton.setExpanded(true, animated: false)
        toggleButton.accessibilityName = "工作区页面"
        toggleButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggleButton)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toggleButton.topAnchor.constraint(equalTo: canvas.topAnchor, constant: Self.toggleInset),
            toggleButton.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: Self.toggleInset),
            toggleButton.widthAnchor.constraint(equalToConstant: AppAgentPageToggleButton.visualSize),
            toggleButton.heightAnchor.constraint(equalToConstant: AppAgentPageToggleButton.visualSize)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    /// 按钮离页面左上角的距离（pt）；工具说明里告诉模型这块区域被原生按钮占用。
    static let toggleInset: CGFloat = 10

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSlotView()
        guard let webView else {
            return
        }
        if webView.bounds.size != webView.touchPolicy.nativeSize || lastSafeAreaInsets != view.safeAreaInsets {
            lastSafeAreaInsets = view.safeAreaInsets
            invalidateLayout()
        }
    }

    /// 插槽视图不用约束，跟随 canvas 显式写 frame：有的宿主视图只在 `setFrame:` 里重建绘制面
    /// （如地图引擎），Auto Layout 走 setBounds/setCenter 不会触发，视图会停在创建时的尺寸。
    private func layoutSlotView() {
        guard let slotView else {
            return
        }
        canvas.layoutIfNeeded()
        let target = canvas.bounds
        guard target.width > 0, target.height > 0 else {
            return
        }
        slotView.view.frame = target
    }

    /// 按一份工作区数据显示。内容没变就不重新加载 WebView；换了页面或内容才重载。
    func render(pageId: String, workspace data: SessionWorkspace, fallbackTitle: String) throws {
        loadViewIfNeeded()
        let source = RenderSource(workspace: data, fallbackTitle: fallbackTitle)

        // 会话数据改的时候已整体校验过；只是状态变了（页面 setState、插槽回写）时文件没动，
        // 沿用上次的内容，不重新整份校验和复制。
        let next: AppAgentWorkspaceH5Content
        if let content, source == renderedSource {
            next = content
        } else {
            next = try AppAgentWorkspaceH5Content(workspace: data, fallbackTitle: fallbackTitle)
        }
        let pageChanged = pageId != self.pageId
        self.pageId = pageId
        if let name = data.shownSlot {
            try attachSlotView(named: name, state: data.slots[name]?.state ?? [:])
        } else {
            detachSlotView()
        }
        let showsH5 = data.h5.isShown && !next.html.isEmpty
        if !showsH5 {
            releaseWebView()
            content = nil
            return
        }
        if pageChanged || next != content || webView == nil {
            try loadWebView(next, state: data.h5.state)
        } else if data.h5.state != pageState {
            // 只是状态变了（模型 set_state）：交给页面自己刷新，不重新加载。
            pushState(data.h5.state)
        }
        renderedSource = source
    }

    /// 决定页面内容的那几项输入；和上次相同就沿用 `content`。
    private struct RenderSource: Equatable {
        let title: String
        let fallbackTitle: String
        let hasSlot: Bool
        let files: [String: String]

        init(workspace: SessionWorkspace, fallbackTitle: String) {
            title = workspace.title
            self.fallbackTitle = fallbackTitle
            hasSlot = workspace.shownSlot != nil
            files = workspace.h5.files
        }
    }

    private func loadWebView(_ next: AppAgentWorkspaceH5Content, state: [String: String]) throws {
        releaseWebView()
        content = next
        pageState = state
        loadFailure = nil
        scriptErrors = []
        let handler = AppAgentWorkspaceSchemeHandler(content: next)
        let bridge = AppAgentWorkspaceBridgeHandler(owner: self)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(handler, forURLScheme: AppAgentWorkspaceSchemeHandler.scheme)
        configuration.userContentController.add(bridge, name: AppAgentWorkspaceBridgeScript.messageHandlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: try AppAgentWorkspaceBridgeScript.source(documentID: handler.documentID, state: state),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = AppAgentWorkspaceWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // 插槽层显示时固定 viewport，面板需要滚动时在 H5 内使用 overflow:auto。
        webView.scrollView.isScrollEnabled = !next.hasSlot
        webView.scrollView.bounces = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.hasSlot = next.hasSlot
        webView.isUserInteractionEnabled = isWorkspaceActive
        canvas.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: canvas.topAnchor),
            webView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
        ])
        self.webView = webView
        schemeHandler = handler
        bridgeHandler = bridge
        webView.load(URLRequest(url: handler.documentURL))
    }

    private func pushState(_ state: [String: String]) {
        pageState = state
        guard isPageReady, let webView,
              let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.__appAgentWorkspaceState(\(json));", completionHandler: nil)
    }

    /// 把这个插槽的视图挂到本页，并按本页数据 bind；已经绑着本页就不动（避免重置用户刚拖的视野）。
    private func attachSlotView(named name: String, state: [String: String]) throws {
        guard let pageId, let workspace else {
            throw AppAgentWorkspaceH5Error.invalid("the slot layer needs a host view, but no workspace host is installed")
        }
        if slotName != name {
            detachSlotView()
        }
        let slot = try slotView ?? workspace.sharedSlotView(named: name)
        if slotPageId != pageId {
            if slotPageId != nil {
                slot.unbind()
            }
            slotPageId = nil
            try slot.bind(pageId: pageId, state: state)
            slotPageId = pageId
        }
        if slot.view.superview !== canvas {
            slot.view.translatesAutoresizingMaskIntoConstraints = true
            slot.view.autoresizingMask = []
            canvas.insertSubview(slot.view, at: 0)
        }
        slotView = slot
        slotName = name
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// 摘下插槽视图：宿主存好当前页面的状态。没挂着就什么都不做。
    func detachSlotView() {
        guard let slot = slotView else {
            return
        }
        slotView = nil
        slotName = nil
        if slotPageId != nil {
            slot.unbind()
        }
        slotPageId = nil
        if slot.view.superview === canvas {
            slot.view.removeFromSuperview()
        }
    }

    func setWorkspaceActive(_ active: Bool) {
        guard active != isWorkspaceActive else {
            return
        }
        isWorkspaceActive = active
        webView?.isUserInteractionEnabled = active
        if !active {
            view.endEditing(true)
        }
        invalidateLayout()
    }

    /// 页面离开前台：摘下插槽视图、停用交互；WebView 留着，同一页面回来时不用重载。
    func deactivate() {
        setWorkspaceActive(false)
        detachSlotView()
    }

    /// 释放全部资源（功能关闭、内存告警）。下次显示从会话数据重建。
    func releaseResources() {
        deactivate()
        releaseWebView()
        content = nil
        pageId = nil
    }

    func receiveBridgeMessage(_ message: WKScriptMessage) {
        guard let webView,
              message.webView === webView,
              message.frameInfo.isMainFrame,
              isDocumentURL(message.frameInfo.request.url),
              let body = message.body as? [String: Any],
              body["documentID"] as? String == schemeHandler?.documentID,
              let type = body["type"] as? String else {
            return
        }
        guard isWorkspaceActive, isPageReady, canHandleBridgeMessage() else {
            // 页面在等 invoke 的结果，不回就一直占着「同一时间只跑一个」；send 不等结果，直接丢掉。
            if type == "invoke", let callID = Self.integer(body["callID"]) {
                deliverInvokeResult(callID: callID, output: .error("workspace is not active"))
            }
            return
        }
        if type == "setState" {
            receiveState(key: body["key"], value: body["value"])
            return
        }
        if type == "error" {
            if let text = body["message"] as? String, scriptErrors.count < 20 {
                scriptErrors.append(String(text.prefix(500)))
            }
            return
        }
        if type == "ready" {
            syncLayoutToWebView()
            return
        }
        if type == "invoke" || type == "send" {
            handlePageAction(body, waitsForResult: type == "invoke")
            return
        }
        guard type == "setTouchRegions",
              webView.hasSlot,
              let epoch = Self.integer(body["epoch"]),
              let revision = Self.integer(body["revision"]),
              let viewport = body["viewport"] as? [String: NSNumber],
              let width = viewport["width"]?.doubleValue,
              let height = viewport["height"]?.doubleValue,
              let rawRects = body["rects"] as? [[NSNumber]],
              rawRects.count <= 64 else {
            webView.touchPolicyActive = false
            return
        }

        // blocks 只有自动穿透模式会带；polygons 是页面手动上报的多边形区域。
        let rawBlocks = body["blocks"] as? [[NSNumber]] ?? []
        let rawPolygons = body["polygons"] as? [[[NSNumber]]] ?? []
        let rects = Self.rects(rawRects)
        let blocks = Self.rects(rawBlocks)
        let polygons = rawPolygons.compactMap { points -> [CGPoint]? in
            let converted = points.compactMap { pair -> CGPoint? in
                pair.count == 2 ? CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue) : nil
            }
            return converted.count == points.count ? converted : nil
        }
        let polygonsValid = polygons.count == rawPolygons.count
            && (body["polygons"] == nil || body["polygons"] is [[[NSNumber]]])
        guard rects.count == rawRects.count,
              blocks.count == rawBlocks.count,
              polygonsValid,
              webView.touchPolicy.accept(
                epoch: epoch,
                revision: revision,
                viewport: CGSize(width: width, height: height),
                rects: rects,
                polygons: polygons,
                blocks: blocks
              ) else {
            Logger.info("AppAgentWorkspace", "touch regions rejected: epoch=\(epoch) revision=\(revision) "
                + "viewport=\(Int(width))x\(Int(height)) native=\(Int(webView.bounds.width))x\(Int(webView.bounds.height))")
            webView.touchPolicyActive = false
            return
        }
        if !rects.isEmpty || !polygons.isEmpty {
            Logger.info("AppAgentWorkspace", "touch regions accepted: regions=\(rects.count) "
                + "polygons=\(polygons.count) blocks=\(blocks.count)")
        }
        webView.touchMode = body["mode"] as? String == "manual" ? "manual" : "auto"
        webView.touchPolicyActive = isWorkspaceActive && isPageReady
    }

    /// 给 workspace status 用：模型据此核对手势穿透是否真的生效。
    func touchStatus() -> JSONValue {
        guard let webView else {
            return .null
        }
        let policy = webView.touchPolicy
        let passing = webView.touchPolicyActive && webView.hasSlot
            && (!policy.regions.isEmpty || !policy.polygons.isEmpty)
        return .object([
            "slot": .bool(webView.hasSlot),
            "mode": .string(webView.touchMode),
            "passesToSlot": .bool(passing),
            "regions": .number(Double(policy.regions.count)),
            "polygons": .number(Double(policy.polygons.count)),
            "blocks": .number(Double(policy.blocks.count))
        ])
    }

    private static func rects(_ raw: [[NSNumber]]) -> [CGRect] {
        raw.compactMap { values -> CGRect? in
            guard values.count == 4 else {
                return nil
            }
            return CGRect(x: values[0].doubleValue,
                          y: values[1].doubleValue,
                          width: values[2].doubleValue,
                          height: values[3].doubleValue)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, isDocumentURL(webView.url) else {
            return
        }
        isPageReady = true
        invalidateLayout()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let allowed = webView === self.webView
            && navigationAction.targetFrame?.isMainFrame == true
            && isDocumentURL(navigationAction.request.url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else {
            return
        }
        isPageReady = false
        self.webView?.invalidateTouchPolicy()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            return
        }
        isPageReady = false
        self.webView?.invalidateTouchPolicy()

        // 保留 WebView 接住触摸，防止进程退出后整页突然穿透到插槽视图。
        // 下次展示由会话数据重建，不在后台自动拉起页面。
        content = nil
        loadFailure = "page process terminated"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else {
            return
        }
        loadFailure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else {
            return
        }
        loadFailure = error.localizedDescription
    }

    private func isDocumentURL(_ url: URL?) -> Bool {
        guard let url, let documentURL = schemeHandler?.documentURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.fragment = nil
        return components.url == documentURL
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            return nil
        }
        return number.intValue
    }

    /// 要求该会话仍在前台、会话内容可见。
    private func canHandleBridgeMessage() -> Bool {
        guard let pageId else {
            return false
        }
        return workspace?.canAffectHostUI(sessionId: pageId) == true
    }

    /// `invoke` 等宿主返回的上限；超时回失败并放开「同一时间只跑一个」。`send` 不等返回，不受它限制。
    private static let pageActionTimeout: UInt64 = 12_000_000_000

    /// 页面调宿主动作，两种：
    /// - `invoke`：等宿主返回，结果回填给页面的 Promise。用于取信息，或要确认宿主真的执行了的动作。同一时间一个。
    /// - `send`：单向发出，不等结果、不占「同一时间一个」，宿主失败也不回页面。
    /// 哪些动作可调、名字怎么解析、要不要先收起工作区都由宿主决定。
    private func handlePageAction(_ body: [String: Any], waitsForResult: Bool) {
        let callID = Self.integer(body["callID"])
        if waitsForResult, callID == nil {
            return
        }
        let kind = waitsForResult ? "invoke" : "send"
        func reject(_ message: String) {
            Logger.info("AppAgentWorkspace", "page \(kind) rejected: \(message)")
            if let callID {
                deliverInvokeResult(callID: callID, output: .error(message))
            }
        }

        if waitsForResult, actionInFlight {
            reject("another invoke is running")
            return
        }
        guard let name = body["tool"] as? String, let host, host.workspaceCanPerformPageAction(name) else {
            reject("\(kind) tool is not allowed on this page")
            return
        }
        guard let args = body["args"] as? [String: Any],
              JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args), data.count <= 16_384,
              let params = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            reject("\(kind) args must be a JSON object up to 16 KiB")
            return
        }
        let callLabel = callID.map(String.init) ?? "-"
        Logger.info("AppAgentWorkspace", "page \(kind) \(name) call=\(callLabel)")
        if host.workspacePageActionHidesWorkspace(name) {
            onCollapse?()
        }
        guard waitsForResult, let callID else {
            Task { @MainActor [weak host] in
                _ = await host?.workspacePerformPageAction(name, params: params)
            }
            return
        }
        actionInFlight = true
        actionToken &+= 1
        let token = actionToken
        let documentID = schemeHandler?.documentID
        Task { @MainActor [weak self, weak host] in
            let output = await host?.workspacePerformPageAction(name, params: params)
                ?? .error("workspace host is gone")
            self?.finishPageAction(token: token, documentID: documentID, callID: callID, output: output)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pageActionTimeout)
            self?.finishPageAction(token: token, documentID: documentID, callID: callID,
                                   output: .error("invoke timed out after 12 s"))
        }
    }

    /// 宿主返回或超时，先到的那个生效。结果只回给发起调用的那份文档，页面已重载就不回。
    private func finishPageAction(token: Int, documentID: String?, callID: Int, output: Tool.Output) {
        guard actionInFlight, token == actionToken else {
            return
        }
        actionInFlight = false
        guard documentID != nil, documentID == schemeHandler?.documentID else {
            return
        }
        deliverInvokeResult(callID: callID, output: output)
    }

    private func deliverInvokeResult(callID: Int, output: Tool.Output) {
        let result: JSONValue
        switch output {
        case .json(let value):
            result = .object(["ok": .bool(true), "result": value])
        case .text(let text):
            result = .object(["ok": .bool(true), "result": .string(text)])
        case .image(let image):
            result = .object(["ok": .bool(true), "result": .string(image.caption)])
        case .error(let message):
            result = .object(["ok": .bool(false), "error": .string(message)])
        @unknown default:
            result = .object(["ok": .bool(true), "result": .string(output.stringValue)])
        }
        guard let webView,
              let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.__appAgentInvokeResult(\(callID), \(json));", completionHandler: nil)
    }

    /// 页面写了一条状态：先记在页面眼里的状态，再交给数据的主人（会话）。
    private func receiveState(key: Any?, value: Any?) {
        guard let pageId,
              let key = key as? String, !key.isEmpty, key.utf8.count <= 256 else {
            return
        }
        let text = value as? String
        guard text != nil || value is NSNull else {
            return
        }
        var next = pageState
        next[key] = text
        guard SessionWorkspaceLimits.stateBytes(next) <= SessionWorkspaceLimits.maximumStateBytes else {
            return
        }
        pageState = next
        onStateChange?(pageId, key, text)
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .null
        invalidateLayout()
    }

    private func invalidateLayout() {
        guard let webView else {
            return
        }
        webView.invalidateTouchPolicy()
        if let window = webView.window, !keyboardFrame.isNull {
            let frame = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            webView.occlusions = [webView.convert(frame, from: window)]
        } else {
            webView.occlusions = []
        }
        syncLayoutToWebView()
    }

    private func syncLayoutToWebView() {
        guard isPageReady, let webView else {
            return
        }
        let payload: [String: Any] = [
            "epoch": webView.touchPolicy.epoch,
            "active": isWorkspaceActive,
            "hasSlot": webView.hasSlot,
            "width": webView.bounds.width,
            "height": webView.bounds.height
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.__appAgentWorkspaceLayout(\(json));", completionHandler: nil)
    }

    private func releaseWebView() {
        guard let webView else {
            return
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: AppAgentWorkspaceBridgeScript.messageHandlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        bridgeHandler?.owner = nil
        bridgeHandler = nil
        schemeHandler?.invalidate()
        schemeHandler = nil
        webView.removeFromSuperview()
        self.webView = nil
        isPageReady = false
    }

    @objc private func collapseTapped() {
        onCollapse?()
    }
}

#endif
