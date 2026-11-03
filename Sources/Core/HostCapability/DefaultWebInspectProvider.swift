//
//  DefaultWebInspectProvider.swift
//  AppAgent — 宿主能力层
//
//  WKWebView 的通用 web 内省实现，宿主零代码即可用：
//  - 容器发现走当前 scene 的 UIKit 视图树；不承诺发现外部 SDK 的脱离视图树的预加载池。
//    UUID 存在实例 associated object，登记表只持弱引用。
//  - DOM 查询是**一次性** evaluateJavaScript，跑在独立 WKContentWorld：未被调用时页面里没有任何
//    我们的代码，加载路径零改动；查询期间也看不见、改不了页面自己的全局变量。
//  - 只有 console 采集需要常驻探针（页面调的是页面 world 的 console），所以它按需 arming，
//    且保留原函数透传、错误采集用 addEventListener 而不是覆盖 window.onerror。
//  - **绝不调 removeAllUserScripts**：宿主可能已向同一 userContentController
//    注入自己的脚本，清掉就是破坏宿主行为。
//

#if canImport(UIKit) && canImport(WebKit)
import Foundation
import UIKit
import WebKit
import ObjectiveC.runtime

public final class DefaultWebInspectProvider: WebInspectProvider, @unchecked Sendable {

    public static let shared = DefaultWebInspectProvider()
    private let environment: WebInspectEnvironment

    public init() {
        environment = .live
    }

    /// A real UIView hierarchy for hostless Catalyst, where constructing UIWindow requires
    /// UIApplicationMain. Only root discovery is replaced; WebKit and ownership checks are live.
    @MainActor
    init(testingRoot: UIView, binding: String) {
        environment = .testing(root: testingRoot, binding: binding)
    }

    // MARK: - 容器登记

    private final class WeakWebView {
        weak var view: WKWebView?

        init(_ view: WKWebView) {
            self.view = view
        }
    }

    @MainActor private static var registry: [String: WeakWebView] = [:]
    @MainActor private var knownViews: [String: WeakWebView] = [:]
    @MainActor private var ownedHandlers: [String: ConsoleHandler] = [:]

    static let worldName = "appagent.inspect"
    // Keep the named world alive across calls; WebKit may discard its isolated globals
    // when the last WKContentWorld reference is released.
    @MainActor static let inspectionWorld = WKContentWorld.world(name: worldName)
    private static let handlerName = "appagentWebLog"
    static let consoleBufferLimit = 500

    @MainActor
    private func collect(_ view: UIView, context: HostInspectionContext, into found: inout [WKWebView]) {
        let ownership = HostInspectionContext(scope: context.scope)
        guard HostInspectionUIKit.canTraverse(view, context: ownership) else {
            return
        }
        if let web = view as? WKWebView, environment.includes(web, context: context) {
            found.append(web)
            return
        }
        for sub in view.subviews {
            collect(sub, context: context, into: &found)
        }
    }

    @MainActor
    private func allWebViews(context: HostInspectionContext) throws -> [WKWebView] {
        Self.registry = Self.registry.filter { entry in
            entry.value.view != nil
        }
        var found: [WKWebView] = []
        for window in try environment.roots(context) {
            collect(window, context: context, into: &found)
        }
        return found
    }

    @MainActor
    public static func identity(for webView: WKWebView) -> String {
        registry = registry.filter { entry in
            entry.value.view != nil
        }
        // Cross-component ABI: selector value itself, never the address of a Swift variable.
        let key = unsafeBitCast(NSSelectorFromString("appagent.webview.identity.v1"), to: UnsafeRawPointer.self)
        let id: String
        if let existing = objc_getAssociatedObject(webView, key) as? String {
            id = existing
        } else {
            id = NSUUID().uuidString
            objc_setAssociatedObject(webView, key, id as NSString, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
        Self.registry[id] = WeakWebView(webView)
        return id
    }

    @MainActor
    private func identifier(for webView: WKWebView) -> String {
        knownViews = knownViews.filter { entry in
            entry.value.view != nil
        }
        let id = Self.identity(for: webView)
        knownViews[id] = WeakWebView(webView)
        return id
    }

    /// End this provider's inspections without discovering targets or executing page JS.
    /// Preserve host scripts and buffered console records.
    @MainActor
    public func stopAllInspections() {
        for entry in knownViews.values {
            if let view = entry.view {
                WebInspectHighlight.existingController(for: view)?.stop(clearPageSelection: false)
            }
        }
        knownViews.removeAll()
        for (id, handler) in ownedHandlers {
            handler.isActive = false
            if Self.handlers[id] === handler {
                handler.controller?.removeScriptMessageHandler(forName: Self.handlerName)
                Self.handlers[id] = nil
            }
        }
        ownedHandlers.removeAll()
    }

    /// 没给 id 时取「已上屏且面积最大」的容器：预加载池里的实例没上屏，不该被当成用户在看的页面。
    @MainActor
    private func resolveTarget(_ webviewId: String?, context: HostInspectionContext) throws -> WKWebView? {
        let candidates = try allWebViews(context: context)
        for view in candidates {
            _ = identifier(for: view)
        }
        if let webviewId {
            guard let view = Self.registry[webviewId]?.view else {
                return nil
            }
            guard environment.includes(view, context: context) else {
                throw UIKitInspectionError.outsideScope
            }
            return view
        }
        let visible = candidates.filter { view in
            WebInspectVisibility.isVisible(view, context: context, environment: environment)
        }
        return visible.max(by: { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        })
    }

    // MARK: - JS 执行

    /// JS 求值的结果只有两种下场：一段要给模型看的文本，或者一条失败说明。
    /// **`Any` 不许跨过 continuation** —— `Result<Any, Error>` 不是 Sendable，
    /// Swift 6 的 region isolation 会直接拦住；而 WKWebView 的回调本来就在主线程，
    /// 在回调里就地压成字符串既合规又少一层类型。
    enum JSOutcome: Sendable {
        case value(String)
        case failure(String)
    }

    @MainActor
    func evaluate(_ js: String, on webView: WKWebView, pageWorld: Bool) async -> JSOutcome {
        let world = pageWorld ? WKContentWorld.page : Self.inspectionWorld
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js, in: nil, in: world) { result in
                continuation.resume(returning: Self.outcome(of: result))
            }
        }
    }

    /// 字符串原样、NSNull 记成 `(null)`、其余交给 `String(describing:)`。
    private static func outcome(of result: Result<Any, any Error>) -> JSOutcome {
        switch result {
        case .success(let value):
            if let text = value as? String {
                return .value(text)
            }
            if value is NSNull {
                return .value("(null)")
            }
            return .value(String(describing: value))
        case .failure(let error):
            return .failure(error.localizedDescription)
        }
    }

    /// 统一出口：解析目标 → 生成脚本 → 执行 → 把结果翻译成字符串。
    /// 失败一律以 sentinel 前缀返回，由 WebInspectTool 翻译成工具错误。
    @MainActor
    private func perform(webviewId: String?,
                         context: HostInspectionContext,
                         pageWorld: Bool = false,
                         makeScript: @MainActor (WKWebView) -> String) async -> String {
        let target: WKWebView?
        do {
            target = try resolveTarget(webviewId, context: context)
        } catch {
            return error.localizedDescription
        }
        guard let view = target else {
            if let webviewId {
                return "(webview not found: \(webviewId). Call op='targets' first.)"
            }
            return "(no web view found on screen)"
        }
        guard !Task.isCancelled else {
            return "Inspection denied: cancelled."
        }
        let result = await evaluate(makeScript(view), on: view, pageWorld: pageWorld)
        guard !Task.isCancelled, environment.includes(view, context: context) else {
            return "Inspection denied: cancelled or target left scope."
        }
        switch result {
        case .value(let text):
            return text
        case .failure(let message):
            return "JS error: \(message)"
        }
    }

    // MARK: - WebInspectProvider

    @MainActor
    public func targets(context: HostInspectionContext = .init()) async -> String {
        let views: [WKWebView]
        do {
            views = try allWebViews(context: context)
        } catch {
            return error.localizedDescription
        }
        guard !views.isEmpty else {
            return "(no web view found on screen)"
        }
        var lines: [String] = []
        for view in views {
            let id = identifier(for: view)
            let frame = view.convert(view.bounds, to: nil)
            let host = Self.owningController(view)
            var parts: [String] = []
            parts.append(id)
            parts.append(WebInspectVisibility.isVisible(view, context: context, environment: environment) ? "onscreen" : "offscreen")
            parts.append("rect=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))")
            parts.append("class=\(String(describing: type(of: view)))")
            let hostName = host.map { controller in
                String(describing: type(of: controller))
            } ?? "-"
            parts.append("host=\(hostName)")
            parts.append("loading=\(view.isLoading)")
            parts.append("title=\(view.title ?? "-")")
            parts.append("url=\(view.url?.absoluteString ?? "-")")
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    public func domSummary(webviewId: String?, path: String?, maxNodes: Int, context: HostInspectionContext = .init()) async -> String {
        let root = Self.jsString(path)
        return await perform(webviewId: webviewId, context: context) { _ in
            Self.script("return A.summary(\(root), \(maxNodes));")
        }
    }

    public func domQuery(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext = .init()) async -> String {
        let sel = Self.jsString(selector)
        let root = Self.jsString(path)
        return await perform(webviewId: webviewId, context: context) { _ in
            Self.script("return A.query(\(sel), \(root));")
        }
    }

    public func whyHidden(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext = .init()) async -> String {
        let sel = Self.jsString(selector)
        let root = Self.jsString(path)
        return await perform(webviewId: webviewId, context: context) { _ in
            Self.script("return A.whyHidden(\(sel), \(root));")
        }
    }

    @MainActor
    public func highlight(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext = .init()) async -> String {
        do {
            guard !Task.isCancelled, let view = try resolveTarget(webviewId, context: context) else {
                return "(no web view found on screen)"
            }
            guard WebInspectVisibility.isVisible(view, context: context, environment: environment), !view.isLoading else {
                return "Inspection denied: highlight requires a visible, loaded web view in the active scene."
            }
            let id = identifier(for: view)
            return await WebInspectHighlight.controller(for: view).start(
                selector: selector, path: path, context: context, environment: environment, webviewId: id
            )
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    public func clearHighlight(webviewId: String?, context: HostInspectionContext = .init()) async -> String {
        do {
            guard !Task.isCancelled, let view = try resolveTarget(webviewId, context: context) else {
                return "(no web view found on screen)"
            }
            WebInspectHighlight.existingController(for: view)?.stop()
            return "OK. highlight cleared for \(identifier(for: view))."
        } catch {
            return error.localizedDescription
        }
    }

    public func probe(webviewId: String?, x: Double, y: Double, context: HostInspectionContext = .init()) async -> String {
        await perform(webviewId: webviewId, context: context) { view in
            let inset = view.scrollView.adjustedContentInset
            return Self.script("return A.probe(\(x - Double(inset.left)), \(y - Double(inset.top)), \(Double(view.bounds.width - inset.left - inset.right)));")
        }
    }

    /// 沿 responder 链找承载这个 webview 的 view controller —— 「这个页面是谁打开的」在排查里很有用。
    @MainActor
    private static func owningController(_ view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    public func pageSource(webviewId: String?, kind: String, maxBytes: Int, context: HostInspectionContext = .init()) async -> String {
        await perform(webviewId: webviewId, context: context) { _ in
            if kind == "resources" {
                return Self.script("return A.resources();")
            }
            return Self.script("return A.html(\(maxBytes));")
        }
    }

    public func eval(webviewId: String?, script: String, inPageWorld: Bool, context: HostInspectionContext = .init()) async -> String {
        // 任意 JS 的授权在工具执行边界；直接调用 provider 的宿主自行负责授权。
        let wrapped = "(function(){\nvar __r = (function(){\n\(script)\n})();\ntry {\nreturn typeof __r === 'string' ? __r : JSON.stringify(__r);\n} catch (e) {\nreturn String(__r);\n}\n})()"
        return await perform(webviewId: webviewId, context: context, pageWorld: inPageWorld) { _ in
            wrapped
        }
    }

    // MARK: - console 采集

    @MainActor
    public func consoleStart(webviewId: String?, context: HostInspectionContext = .init()) async -> String {
        guard !Task.isCancelled, let view = try? resolveTarget(webviewId, context: context) else {
            return "(no web view found on screen)"
        }
        let id = identifier(for: view)
        let controller = view.configuration.userContentController
        // 重复 start 幂等：先摘旧 handler 再装，避免 "already has handler" 抛异常。
        Self.handlers[id]?.isActive = false
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        let handler = ConsoleHandler(webviewId: id, store: Self.consoleStore, controller: controller)
        controller.add(handler, name: Self.handlerName)
        Self.handlers[id] = handler
        ownedHandlers[id] = handler
        if Self.installedScripts.contains(id) == false {
            let userScript = WKUserScript(source: Self.consoleProbeJS,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: false)
            controller.addUserScript(userScript)
            Self.installedScripts.insert(id)
        }
        // 当前已经加载完的页面不会再跑 documentStart 脚本，所以立刻在页面 world 里补装一次。
        let result = await evaluate(Self.consoleProbeJS, on: view, pageWorld: true)
        guard handler.isActive, Self.handlers[id] === handler, !Task.isCancelled else {
            return "Inspection denied: console capture cancelled."
        }
        switch result {
        case .value:
            return "OK. console capture armed for \(id). Only logs produced from now on are captured; "
                + "reproduce the problem, then call op='console_read'."
        case .failure(let message):
            return "Failed to arm console capture for \(id): \(message)"
        }
    }

    @MainActor
    public func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?, context: HostInspectionContext = .init()) async -> String {
        guard let view = try? resolveTarget(webviewId, context: context) else {
            return "(no web view found on screen)"
        }
        let id = identifier(for: view)
        let records = Self.consoleStore.read(webviewId: id, limit: limit, sinceSeq: sinceSeq)
        guard !records.isEmpty else {
            let armed = Self.handlers[id] != nil
            return armed ? "(no console records for \(id) yet)"
                : "(console capture not armed for \(id) — call op='console_start' first)"
        }
        var lines: [String] = []
        for record in records {
            lines.append(record.line)
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    public func consoleStop(webviewId: String?, context: HostInspectionContext = .init()) async -> String {
        guard !Task.isCancelled, let view = try? resolveTarget(webviewId, context: context) else {
            return "(no web view found on screen)"
        }
        let id = identifier(for: view)
        Self.handlers[id]?.isActive = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        Self.handlers[id] = nil
        ownedHandlers[id] = nil
        // 注入的代理函数留在页面里（不能只摘单条 user script，而 removeAllUserScripts 会清掉宿主的脚本）；
        // 它的 postMessage 已包在 try/catch 里，handler 摘掉后就是空转，下次页面加载自然消失。
        return "OK. console capture stopped for \(id) (buffered records kept; probe goes idle)."
    }

    // MARK: - console 缓冲

    struct ConsoleRecord: Sendable {
        let seq: UInt64
        let line: String
    }

    /// 进程内环形缓冲。WKScriptMessageHandler 的回调在主线程，但读取可能来自任意 task，
    /// 所以用锁而不是 MainActor —— 采集路径上不该因为等主线程而丢日志顺序。
    final class ConsoleStore: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: [ConsoleRecord]] = [:]
        private var seq: UInt64 = 0

        func append(webviewId: String, line: String) {
            lock.lock()
            seq += 1
            var list = records[webviewId] ?? []
            list.append(ConsoleRecord(seq: seq, line: "#\(seq) \(line)"))
            if list.count > DefaultWebInspectProvider.consoleBufferLimit {
                list.removeFirst(list.count - DefaultWebInspectProvider.consoleBufferLimit)
            }
            records[webviewId] = list
            lock.unlock()
        }

        func read(webviewId: String, limit: Int, sinceSeq: UInt64?) -> [ConsoleRecord] {
            lock.lock()
            var list = records[webviewId] ?? []
            lock.unlock()
            if let sinceSeq {
                list = list.filter { record in
                    record.seq > sinceSeq
                }
            }
            if list.count > limit {
                list = Array(list.suffix(limit))
            }
            return list
        }
    }

    static let consoleStore = ConsoleStore()

    @MainActor private static var handlers: [String: ConsoleHandler] = [:]
    @MainActor private static var installedScripts: Set<String> = []

    @MainActor final class ConsoleHandler: NSObject, WKScriptMessageHandler {
        private let webviewId: String
        private let store: ConsoleStore
        weak var controller: WKUserContentController?
        var isActive = true

        init(webviewId: String, store: ConsoleStore, controller: WKUserContentController) {
            self.webviewId = webviewId
            self.store = store
            self.controller = controller
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard isActive else {
                return
            }
            guard let body = message.body as? [String: Any] else {
                store.append(webviewId: webviewId, line: "log \(message.body)")
                return
            }
            let level = body["level"] as? String ?? "log"
            let text = body["text"] as? String ?? ""
            var line = "\(level) \(text)"
            if let source = body["source"] as? String, !source.isEmpty {
                let lineNo = body["line"].map { value in
                    String(describing: value)
                } ?? "?"
                line += "  @\(source):\(lineNo)"
            }
            store.append(webviewId: webviewId, line: line)
        }
    }

    // MARK: - 脚本组装

    static func jsString(_ value: String?) -> String {
        guard let value else {
            return "null"
        }
        // JSON encoding also covers CR, tabs and other controls; selectors never become JS code.
        guard let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return encoded
    }

    /// 探针库每次随查询一起下发（几 KB 的解析成本可忽略），因此不需要「是否已注入」的状态机，
    /// 也不会在页面里留下任何常驻代码。
    static func script(_ call: String) -> String {
        "(function(){\ntry {\n" + probeJS + "\n" + call
            + "\n} catch (e) {\nreturn 'JS error: ' + e.message;\n}\n})()"
    }

    static func highlightScript(_ call: String) -> String {
        "(function(){\ntry {\n" + probeJSCore + probeJSGeometry + "\n" + call
            + "\n} catch (e) {\nreturn 'JS error: ' + e.message;\n}\n})()"
    }

    static var probeJS: String {
        probeJSCore + probeJSSummary + probeJSWalk + probeJSDetail + probeJSWhy + probeJSMisc + probeJSGeometry
    }

    private static let probeJSCore = #"""
var A = {};
A.SKIP = ['script', 'style', 'link', 'meta', 'noscript', 'template'];
A.indent = function (depth) {
    return new Array(depth + 1).join('  ');
};
A.text = function (el) {
    var t = '';
    for (var i = 0; i < el.childNodes.length; i++) {
        var n = el.childNodes[i];
        if (n.nodeType === 3) {
            t += n.nodeValue;
        }
    }
    t = t.replace(/\s+/g, ' ').trim();
    if (t.length > 60) {
        t = t.slice(0, 60) + '…';
    }
    return t;
};
A.path = function (el) {
    var doc = el.ownerDocument;
    var prefix = doc === document ? '' : A.path(doc.defaultView.frameElement) + '/frame';
    if (el === doc.body) {
        return prefix;
    }
    if (el === doc.documentElement) {
        return (prefix ? prefix + '/' : '') + 'html';
    }
    if (el.nodeType === 11 && el.host) {
        return A.path(el.host) + '/shadow';
    }
    var parent = el.parentNode;
    if (!parent || !parent.children) {
        throw new Error('Unsupported detached node path');
    }
    var base = A.path(parent);
    return (base ? base + '/' : '') + Array.prototype.indexOf.call(parent.children, el);
};
A.node = function (path) {
    if (!path) {
        return document.body;
    }
    var parts = String(path).split('/');
    var cur = document.body;
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === '') {
            continue;
        }
        if (!cur) {
            return null;
        }
        if (parts[i] === 'frame') {
            if (cur.tagName !== 'IFRAME' && cur.tagName !== 'FRAME') {
                throw new Error('frame path segment requires an iframe');
            }
            var doc;
            try {
                doc = cur.contentDocument;
                if (!doc) {
                    throw new Error('inaccessible');
                }
            } catch (e) {
                throw new Error('Unsupported cross-origin or sandboxed iframe');
            }
            if (!doc.body) {
                throw new Error('Iframe document body is not ready');
            }
            cur = doc.body;
            continue;
        }
        if (parts[i] === 'shadow') {
            if (!cur.shadowRoot) {
                throw new Error('Unsupported closed or absent shadow root');
            }
            cur = cur.shadowRoot;
            continue;
        }
        if (parts[i] === 'html') {
            cur = cur.ownerDocument.documentElement;
            continue;
        }
        if (!/^\d+$/.test(parts[i])) {
            throw new Error('Invalid path segment: ' + parts[i]);
        }
        var idx = Number(parts[i]);
        if (!cur.children || idx >= cur.children.length) {
            return null;
        }
        cur = cur.children[idx];
    }
    return cur;
};
A.resolve = function (sel, path) {
    if (sel) {
        var root = path == null ? document : A.node(path);
        return root ? root.querySelector(sel) : null;
    }
    var node = A.node(path);
    if (node && node.nodeType !== 1) {
        throw new Error('Path selects a shadow root; add a child index or selector');
    }
    return node;
};

"""#

    private static let probeJSSummary = #"""
A.label = function (el) {
    var s = el.tagName.toLowerCase();
    if (el.id) {
        s += '#' + el.id;
    }
    if (el.className && typeof el.className === 'string') {
        var cls = el.className.trim().split(/\s+/).slice(0, 2).join('.');
        if (cls) {
            s += '.' + cls;
        }
    }
    return s;
};
A.rectOf = function (el) {
    var r = el.getBoundingClientRect();
    return Math.round(r.left) + ',' + Math.round(r.top) + ',' + Math.round(r.width) + ',' + Math.round(r.height);
};
A.flags = function (el) {
    var win = el.ownerDocument.defaultView;
    var cs = win.getComputedStyle(el);
    var r = el.getBoundingClientRect();
    var f = [];
    if (cs.display === 'none') {
        f.push('display:none');
    }
    if (cs.visibility !== 'visible') {
        f.push('visibility:' + cs.visibility);
    }
    if (parseFloat(cs.opacity) < 0.01) {
        f.push('opacity:' + cs.opacity);
    }
    if (r.width < 1 || r.height < 1) {
        f.push('zero-size');
    }
    if (r.bottom < 0 || r.right < 0 || r.top > win.innerHeight || r.left > win.innerWidth) {
        f.push('outside-viewport');
    }
    return f;
};
A.deep = function (el) {
    try {
        return el.getElementsByTagName('*').length;
    } catch (e) {
        return 0;
    }
};

"""#

    private static let probeJSWalk = #"""
A.emit = function (el, depth, lines) {
    var line = A.indent(depth) + A.path(el) + ' ' + A.label(el) + ' rect=' + A.rectOf(el);
    var f = A.flags(el);
    if (f.length) {
        line += ' [' + f.join(',') + ']';
    }
    var t = A.text(el);
    if (t) {
        line += ' "' + t + '"';
    }
    lines.push(line);
};
A.walk = function (el, depth, lines, count, maxNodes) {
    if (el.nodeType === 11) {
        for (var s = 0; s < el.children.length && count.n < maxNodes; s++) {
            A.walk(el.children[s], depth, lines, count, maxNodes);
        }
        return;
    }
    if (A.SKIP.indexOf(el.tagName.toLowerCase()) >= 0) {
        return;
    }
    A.emit(el, depth, lines);
    count.n += 1;
    if (el.shadowRoot) {
        lines.push(A.indent(depth + 1) + 'open shadow root: path=' + A.path(el) + '/shadow');
    }
    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
        try {
            if (!el.contentDocument) {
                throw new Error('cross-origin');
            }
            lines.push(A.indent(depth + 1) + 'same-origin iframe: path=' + A.path(el) + '/frame');
        } catch (e) {
            lines.push(A.indent(depth + 1) + 'unsupported cross-origin or sandboxed iframe');
        }
    }
    var f = A.flags(el);
    if (f.indexOf('display:none') >= 0 || depth >= 14) {
        var deep = A.deep(el);
        if (deep > 0) {
            var why = f.indexOf('display:none') >= 0 ? 'hidden' : 'depth limit';
            lines.push(A.indent(depth + 1) + '⊞ ' + deep + ' nodes (' + why + ') path=' + A.path(el));
        }
        return;
    }
    for (var i = 0; i < el.children.length; i++) {
        if (count.n >= maxNodes) {
            lines.push(A.indent(depth + 1) + '⊞ ' + (el.children.length - i) + ' more children (node budget reached) path=' + A.path(el));
            break;
        }
        A.walk(el.children[i], depth + 1, lines, count, maxNodes);
    }
};
A.head = function () {
    return 'url=' + location.href + ' readyState=' + document.readyState
        + ' viewport=' + window.innerWidth + 'x' + window.innerHeight
        + ' dpr=' + (window.devicePixelRatio || 1)
        + ' scroll=' + Math.round(window.scrollX) + ',' + Math.round(window.scrollY);
};
A.summary = function (rootPath, maxNodes) {
    var root = A.node(rootPath);
    if (!root) {
        return '(no node at path ' + rootPath + ')';
    }
    var lines = [];
    var count = {
        n: 0
    };
    A.walk(root, 0, lines, count, maxNodes);
    return A.head() + '\nrect coordinates: CSS px in each node owner-document layout viewport\n' + lines.join('\n');
};

"""#

    private static let probeJSDetail = #"""
A.STYLE_KEYS = ['display', 'position', 'visibility', 'opacity', 'zIndex', 'overflow', 'overflowX',
    'boxSizing', 'width', 'minWidth', 'maxWidth', 'height', 'flex', 'flexDirection', 'justifyContent',
    'alignItems', 'transform', 'float', 'textAlign', 'fontSize', 'color', 'backgroundColor'];
A.query = function (sel, path) {
    var el = A.resolve(sel, path);
    if (!el) {
        return '(no element for ' + (sel || path) + ')';
    }
    var win = el.ownerDocument.defaultView;
    var cs = win.getComputedStyle(el);
    var out = [];
    out.push('node ' + A.label(el) + ' path=' + A.path(el));
    out.push(A.head());
    var attrs = {};
    for (var a = 0; a < el.attributes.length; a++) {
        attrs[el.attributes[a].name] = el.attributes[a].value;
    }
    out.push('attributes=' + JSON.stringify(attrs));
    out.push('coordinateSpace: CSS px in owner-document layout viewport; rect is getBoundingClientRect, not screen pt'
        + '; documentURL=' + el.ownerDocument.URL);
    out.push('rect=' + A.rectOf(el) + ' flags=[' + A.flags(el).join(',') + ']');
    out.push('client=' + el.clientWidth + 'x' + el.clientHeight
        + ' scroll=' + el.scrollWidth + 'x' + el.scrollHeight
        + ' offset=' + el.offsetWidth + 'x' + el.offsetHeight
        + (el.scrollWidth > el.clientWidth + 1 ? ' [content wider than box]' : ''));
    out.push('padding=' + cs.paddingTop + '/' + cs.paddingRight + '/' + cs.paddingBottom + '/' + cs.paddingLeft
        + ' border=' + cs.borderTopWidth + '/' + cs.borderRightWidth + '/' + cs.borderBottomWidth + '/' + cs.borderLeftWidth
        + ' margin=' + cs.marginTop + '/' + cs.marginRight + '/' + cs.marginBottom + '/' + cs.marginLeft);
    var st = [];
    for (var i = 0; i < A.STYLE_KEYS.length; i++) {
        st.push(A.STYLE_KEYS[i] + ':' + cs[A.STYLE_KEYS[i]]);
    }
    out.push('computed ' + st.join('; '));
    var chain = [];
    var narrow = null;
    var cur = el.parentElement;
    while (cur && chain.length < 10) {
        var cr = cur.getBoundingClientRect();
        var ccs = win.getComputedStyle(cur);
        chain.push(A.label(cur) + ' w=' + Math.round(cr.width) + ' overflow=' + ccs.overflow + ' path=' + A.path(cur));
        if (!narrow && Math.round(cr.width) < win.innerWidth - 1) {
            narrow = A.label(cur) + ' w=' + Math.round(cr.width) + ' < viewport ' + win.innerWidth
                + ' (width:' + ccs.width + ' maxWidth:' + ccs.maxWidth + ' padding=' + ccs.paddingLeft + '/' + ccs.paddingRight + ') path=' + A.path(cur);
        }
        cur = cur.parentElement;
    }
    out.push('ancestors: ' + chain.join('  <  '));
    out.push('width-constraining-ancestor: ' + (narrow || '(none — every ancestor spans the viewport)'));
    out.push('children=' + el.children.length + ' text="' + A.text(el) + '"');
    return out.join('\n');
};

"""#

    private static let probeJSWhy = #"""
A.whyHidden = function (sel, path) {
    var el = A.resolve(sel, path);
    if (!el) {
        return '(no element for ' + (sel || path) + ')';
    }
    var reasons = [];
    var win = el.ownerDocument.defaultView;
    var cs = win.getComputedStyle(el);
    var r = el.getBoundingClientRect();
    if (cs.display === 'none') {
        reasons.push('self display:none');
    }
    if (cs.visibility !== 'visible') {
        reasons.push('self visibility:' + cs.visibility);
    }
    if (parseFloat(cs.opacity) < 0.01) {
        reasons.push('self opacity:' + cs.opacity);
    }
    if (r.width < 1 || r.height < 1) {
        reasons.push('self zero size (rect=' + A.rectOf(el) + ' width:' + cs.width + ' height:' + cs.height + ')');
    }
    if (r.bottom < 0 || r.right < 0 || r.top > win.innerHeight || r.left > win.innerWidth) {
        reasons.push('outside viewport (rect=' + A.rectOf(el) + ' viewport=' + win.innerWidth + 'x' + win.innerHeight + ') — may just need scrolling');
    }
    var cur = el.parentElement;
    while (cur) {
        var ccs = win.getComputedStyle(cur);
        var crect = cur.getBoundingClientRect();
        if (ccs.display === 'none') {
            reasons.push('ancestor ' + A.label(cur) + ' display:none path=' + A.path(cur));
        }
        if (ccs.visibility === 'hidden') {
            reasons.push('ancestor ' + A.label(cur) + ' visibility:hidden path=' + A.path(cur));
        }
        if (parseFloat(ccs.opacity) < 0.01) {
            reasons.push('ancestor ' + A.label(cur) + ' opacity:' + ccs.opacity + ' path=' + A.path(cur));
        }
        var clips = ccs.overflow === 'hidden' || ccs.overflowX === 'hidden' || ccs.overflowY === 'hidden';
        if (clips && (r.right <= crect.left || r.left >= crect.right || r.bottom <= crect.top || r.top >= crect.bottom)) {
            reasons.push('clipped out by ancestor ' + A.label(cur) + ' (overflow hidden, ancestor rect=' + A.rectOf(cur) + ') path=' + A.path(cur));
        }
        cur = cur.parentElement;
    }
    if (r.width > 0 && r.height > 0) {
        var cx = Math.min(Math.max(r.left + r.width / 2, 1), win.innerWidth - 1);
        var cy = Math.min(Math.max(r.top + r.height / 2, 1), win.innerHeight - 1);
        var root = el.getRootNode();
        var top = root.elementFromPoint ? root.elementFromPoint(cx, cy) : el.ownerDocument.elementFromPoint(cx, cy);
        if (top && top !== el && !el.contains(top) && !top.contains(el)) {
            reasons.push('covered at its center by ' + A.label(top) + ' (z-index ' + win.getComputedStyle(top).zIndex + ') path=' + A.path(top));
        }
    }
    if (reasons.length === 0) {
        reasons.push('nothing hides it: rect=' + A.rectOf(el) + ', it is laid out and visible. Check that this is the node the user means, or whether it is scrolled out of the visible area.');
    }
    return 'node ' + A.label(el) + ' path=' + A.path(el) + '\n' + A.head()
        + '\ncoordinateSpace: owner-document CSS px; occlusion checks are local to this document/root'
        + '\n- ' + reasons.join('\n- ');
};

"""#

    private static let probeJSMisc = #"""
A.probe = function (x, y, boundsWidth) {
    var vp = window.visualViewport;
    var ratio = ((vp ? vp.width : window.innerWidth) / boundsWidth);
    var cx = x * ratio + (vp ? vp.offsetLeft : 0);
    var cy = y * ratio + (vp ? vp.offsetTop : 0);
    var el = document.elementFromPoint(cx, cy);
    if (!el) {
        return '(no element at view point ' + x + ',' + y + ' → css ' + Math.round(cx) + ',' + Math.round(cy) + ')';
    }
    return 'hit ' + A.label(el) + ' path=' + A.path(el)
        + ' cssPoint=' + Math.round(cx) + ',' + Math.round(cy) + ' pt→css ratio=' + ratio.toFixed(3) + '\n'
        + A.query(null, A.path(el));
};
A.html = function (maxBytes) {
    var s = '';
    try {
        s = document.documentElement.outerHTML || '';
    } catch (e) {
        return 'Failed to serialize DOM: ' + e;
    }
    if (s.length > maxBytes) {
        return s.slice(0, maxBytes) + '\n…(truncated, ' + s.length + ' chars total)';
    }
    return s;
};
A.resources = function () {
    var out = [A.head()];
    try {
        var nav = performance.getEntriesByType('navigation')[0];
        if (nav) {
            out.push('navigation type=' + nav.type + ' duration=' + Math.round(nav.duration)
                + 'ms domContentLoaded=' + Math.round(nav.domContentLoadedEventEnd) + 'ms');
        }
        var entries = performance.getEntriesByType('resource');
        out.push('resources=' + entries.length + ' (showing first 60)');
        for (var i = 0; i < entries.length && i < 60; i++) {
            var e = entries[i];
            var suspect = (e.transferSize === 0 && e.duration === 0) ? ' [no transfer — cached or failed]' : '';
            out.push(Math.round(e.duration) + 'ms ' + (e.transferSize || 0) + 'B ' + (e.initiatorType || '?') + ' ' + e.name + suspect);
        }
    } catch (e) {
        out.push('(performance API unavailable: ' + e + ')');
    }
    return out.join('\n');
};

"""#

    /// Read-only geometry, shared by the initial selection and subsequent native redraws.
    private static let probeJSGeometry = #"""
A.parent = function (el) {
    return el.parentElement || (el.getRootNode && el.getRootNode().host) || null;
};
A.geometry = function (el) {
    if (!el || !el.isConnected) {
        throw new Error('Selected node is detached');
    }
    var r = el.getBoundingClientRect();
    var box = {left: r.left, top: r.top, right: r.right, bottom: r.bottom};
    var clip = function (l, t, r, b) {
        box.left = Math.max(box.left, l);
        box.top = Math.max(box.top, t);
        box.right = Math.min(box.right, r);
        box.bottom = Math.min(box.bottom, b);
    };
    var current = el;
    var doc = el.ownerDocument;
    while (true) {
        var win = doc.defaultView;
        for (var p = current; p; p = A.parent(p)) {
            var cs = win.getComputedStyle(p);
            if (cs.display === 'none' || cs.visibility !== 'visible' || Number(cs.opacity) <= 0.01) {
                throw new Error('Selected node or ancestor is hidden');
            }
            if (p !== current && /(hidden|clip|scroll|auto)/.test(cs.overflow + cs.overflowX + cs.overflowY)) {
                var pr = p.getBoundingClientRect();
                clip(pr.left, pr.top, pr.right, pr.bottom);
            }
        }
        if (doc === document) {
            break;
        }
        clip(0, 0, win.innerWidth, win.innerHeight);
        var frame = win.frameElement;
        if (!frame || frame.contentDocument !== doc || !frame.isConnected) {
            throw new Error('Selected iframe navigated or detached');
        }
        // Axis-aligned scale/translation are supported; do not invent a rect for rotated frames.
        for (var f = frame; f; f = A.parent(f)) {
            var transform = f.ownerDocument.defaultView.getComputedStyle(f).transform;
            if (transform !== 'none') {
                var m = new DOMMatrixReadOnly(transform);
                if (!m.is2D || m.b !== 0 || m.c !== 0 || m.a <= 0 || m.d <= 0) {
                    throw new Error('Unsupported rotated, skewed or perspective iframe geometry');
                }
            }
        }
        var fr = frame.getBoundingClientRect();
        var fs = frame.ownerDocument.defaultView.getComputedStyle(frame);
        var sx = fr.width / frame.offsetWidth;
        var sy = fr.height / frame.offsetHeight;
        var left = fr.left + (frame.clientLeft + parseFloat(fs.paddingLeft)) * sx;
        var top = fr.top + (frame.clientTop + parseFloat(fs.paddingTop)) * sy;
        box = {left: left + box.left * sx, top: top + box.top * sy,
            right: left + box.right * sx, bottom: top + box.bottom * sy};
        current = frame;
        doc = frame.ownerDocument;
    }
    var vp = window.visualViewport;
    var vx = vp ? vp.offsetLeft : 0;
    var vy = vp ? vp.offsetTop : 0;
    var vw = vp ? vp.width : window.innerWidth;
    var vh = vp ? vp.height : window.innerHeight;
    clip(vx, vy, vx + vw, vy + vh);
    if (box.right <= box.left || box.bottom <= box.top || vw <= 0) {
        throw new Error('Selected node is outside the visible viewport');
    }
    return {x: (box.left - vx) / vw, y: (box.top - vy) / vw,
        width: (box.right - box.left) / vw, height: (box.bottom - box.top) / vw,
        path: A.path(el), coordinateSpace: 'normalized top visual viewport; all axes divided by viewport width'};
};
A.selectHighlight = function (token, sel, path) {
    var el = A.resolve(sel, path);
    if (!el) {
        throw new Error('No element for highlight');
    }
    var geometry = A.geometry(el);
    window.__appagentHighlight = {token: token, node: el};
    return JSON.stringify(geometry);
};
A.highlightGeometry = function (token) {
    var state = window.__appagentHighlight;
    if (!state || state.token !== token) {
        throw new Error('Highlight selection expired');
    }
    return JSON.stringify(A.geometry(state.node));
};

"""#

    /// 页面 world 的 console 代理。三条硬约定：
    /// ① 保留原函数并透传（页面自己的日志行为不变，DevTools 里照样看得到）；
    /// ② 错误用 addEventListener 而不是覆盖 window.onerror（覆盖会踩掉页面自己的兜底）；
    /// ③ 整体 try/catch —— handler 被摘掉后 postMessage 会抛，绝不能把异常扔回页面代码。
    private static let consoleProbeJS = #"""
(function () {
    if (window.__appagentWebLogInstalled) {
        return 'already-installed';
    }
    window.__appagentWebLogInstalled = true;
    var post = function (level, text) {
        try {
            window.webkit.messageHandlers.appagentWebLog.postMessage({
                level: level,
                text: String(text).slice(0, 2000)
            });
        } catch (e) {
        }
    };
    var join = function (args) {
        var parts = [];
        for (var i = 0; i < args.length; i++) {
            var a = args[i];
            try {
                parts.push(typeof a === 'string' ? a : JSON.stringify(a));
            } catch (e) {
                parts.push(String(a));
            }
        }
        return parts.join(' ');
    };
    var levels = ['log', 'info', 'warn', 'error', 'debug'];
    for (var i = 0; i < levels.length; i++) {
        (function (name) {
            var original = console[name];
            console[name] = function () {
                post(name, join(arguments));
                if (original) {
                    return original.apply(console, arguments);
                }
            };
        })(levels[i]);
    }
    window.addEventListener('error', function (e) {
        try {
            window.webkit.messageHandlers.appagentWebLog.postMessage({
                level: 'jserror',
                text: String(e.message || e.type).slice(0, 2000),
                source: String(e.filename || ''),
                line: e.lineno || 0
            });
        } catch (err) {
        }
    });
    window.addEventListener('unhandledrejection', function (e) {
        post('unhandledrejection', (e.reason && (e.reason.message || e.reason)) || 'unknown');
    });
    return 'installed';
})()
"""#

    // WEB-INSPECT-PROVIDER-APPEND
}
#endif
