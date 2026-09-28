//
//  DefaultWebInspectProvider.swift
//  AppAgent — 宿主能力层
//
//  WKWebView 的通用 web 内省实现，宿主零代码即可用：
//  - 容器发现走 UIKit 视图树（含预加载池里没上屏的实例），id 记在弱引用表里，跨调用稳定。
//  - DOM 查询是**一次性** evaluateJavaScript，跑在独立 WKContentWorld：未被调用时页面里没有任何
//    我们的代码，加载路径零改动；查询期间也看不见、改不了页面自己的全局变量。
//  - 只有 console 采集需要常驻探针（页面调的是页面 world 的 console），所以它按需 arming，
//    且保留原函数透传、错误采集用 addEventListener 而不是覆盖 window.onerror。
//  - **绝不调 removeAllUserScripts**：宿主（如百度地图 BMWebView）自己也往同一个
//    userContentController 装脚本（静音、闪屏浮层），清掉就是破坏宿主功能。
//

#if canImport(UIKit) && canImport(WebKit)
import Foundation
import UIKit
import WebKit

public final class DefaultWebInspectProvider: WebInspectProvider, @unchecked Sendable {

    public static let shared = DefaultWebInspectProvider()

    public init() {
    }

    // MARK: - 容器登记

    private final class WeakWebView {
        weak var view: WKWebView?

        init(_ view: WKWebView) {
            self.view = view
        }
    }

    @MainActor private static var registry: [String: WeakWebView] = [:]
    @MainActor private static var nextIndex = 1

    private static let worldName = "appagent.inspect"
    private static let handlerName = "appagentWebLog"
    static let consoleBufferLimit = 500

    @MainActor
    private static func windows() -> [UIWindow] {
        var result: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            result.append(contentsOf: windowScene.windows)
        }
        return result
    }

    @MainActor
    private func collect(_ view: UIView, into found: inout [WKWebView]) {
        if let web = view as? WKWebView {
            found.append(web)
            return
        }
        for sub in view.subviews {
            collect(sub, into: &found)
        }
    }

    @MainActor
    private func allWebViews() -> [WKWebView] {
        var found: [WKWebView] = []
        for window in Self.windows() {
            collect(window, into: &found)
        }
        return found
    }

    @MainActor
    private func identifier(for webView: WKWebView) -> String {
        for (id, box) in Self.registry where box.view === webView {
            return id
        }
        let id = "w\(Self.nextIndex)"
        Self.nextIndex += 1
        Self.registry[id] = WeakWebView(webView)
        return id
    }

    @MainActor
    private func isOnScreen(_ webView: UIView) -> Bool {
        guard webView.window != nil, !webView.isHidden, webView.alpha > 0.01 else {
            return false
        }
        return webView.bounds.width > 1 && webView.bounds.height > 1
    }

    /// 没给 id 时取「已上屏且面积最大」的容器：预加载池里的实例没上屏，不该被当成用户在看的页面。
    @MainActor
    private func resolveTarget(_ webviewId: String?) -> WKWebView? {
        if let webviewId {
            return Self.registry[webviewId]?.view
        }
        let candidates = allWebViews()
        for view in candidates {
            _ = identifier(for: view)
        }
        let visible = candidates.filter { view in
            isOnScreen(view)
        }
        let pool = visible.isEmpty ? candidates : visible
        return pool.max(by: { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        })
    }

    // MARK: - JS 执行

    @MainActor
    private func evaluate(_ js: String, on webView: WKWebView, pageWorld: Bool) async -> Result<Any, Error> {
        let world = pageWorld ? WKContentWorld.page : WKContentWorld.world(name: Self.worldName)
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js, in: nil, in: world) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// 统一出口：解析目标 → 生成脚本 → 执行 → 把结果翻译成字符串。
    /// 失败一律以 sentinel 前缀返回，由 WebInspectTool 翻译成工具错误。
    @MainActor
    private func perform(webviewId: String?,
                         pageWorld: Bool = false,
                         makeScript: @MainActor (WKWebView) -> String) async -> String {
        guard let view = resolveTarget(webviewId) else {
            if let webviewId {
                return "(webview not found: \(webviewId). Call op='targets' first.)"
            }
            return "(no web view found on screen)"
        }
        let result = await evaluate(makeScript(view), on: view, pageWorld: pageWorld)
        switch result {
        case .success(let value):
            if let text = value as? String {
                return text
            }
            if value is NSNull {
                return "(null)"
            }
            return String(describing: value)
        case .failure(let error):
            return "JS error: \(error.localizedDescription)"
        }
    }

    // MARK: - WebInspectProvider

    @MainActor
    public func targets() async -> String {
        let views = allWebViews()
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
            parts.append(isOnScreen(view) ? "onscreen" : "offscreen")
            parts.append("rect=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))")
            parts.append("class=\(String(describing: type(of: view)))")
            parts.append("host=\(host.map { String(describing: type(of: $0)) } ?? "-")")
            parts.append("loading=\(view.isLoading)")
            parts.append("title=\(view.title ?? "-")")
            parts.append("url=\(view.url?.absoluteString ?? "-")")
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    public func domSummary(webviewId: String?, path: String?, maxNodes: Int) async -> String {
        let root = Self.jsString(path)
        return await perform(webviewId: webviewId) { _ in
            Self.script("return A.summary(\(root), \(maxNodes));")
        }
    }

    public func domQuery(webviewId: String?, selector: String?, path: String?) async -> String {
        let sel = Self.jsString(selector)
        let root = Self.jsString(path)
        return await perform(webviewId: webviewId) { _ in
            Self.script("return A.query(\(sel), \(root));")
        }
    }

    public func whyHidden(webviewId: String?, selector: String?, path: String?) async -> String {
        let sel = Self.jsString(selector)
        let root = Self.jsString(path)
        return await perform(webviewId: webviewId) { _ in
            Self.script("return A.whyHidden(\(sel), \(root));")
        }
    }

    public func probe(webviewId: String?, x: Double, y: Double) async -> String {
        await perform(webviewId: webviewId) { view in
            // 传进来的是 view 坐标（pt），JS 侧按 innerWidth / boundsWidth 换算成 CSS px。
            // 双指缩放过的页面这个换算是近似值，结论里会带上换算比例。
            Self.script("return A.probe(\(x), \(y), \(Double(view.bounds.width)));")
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

    public func pageSource(webviewId: String?, kind: String, maxBytes: Int) async -> String {
        await perform(webviewId: webviewId) { _ in
            if kind == "resources" {
                return Self.script("return A.resources();")
            }
            return Self.script("return A.html(\(maxBytes));")
        }
    }

    public func eval(webviewId: String?, script: String, inPageWorld: Bool) async -> String {
        // 内部阶段放开任意 JS：不做语法/能力过滤，只保证结果可读（对象走 JSON.stringify）。
        let wrapped = "(function(){\nvar __r = (function(){\n\(script)\n})();\ntry {\nreturn typeof __r === 'string' ? __r : JSON.stringify(__r);\n} catch (e) {\nreturn String(__r);\n}\n})()"
        return await perform(webviewId: webviewId, pageWorld: inPageWorld) { _ in
            wrapped
        }
    }

    // MARK: - console 采集

    @MainActor
    public func consoleStart(webviewId: String?) async -> String {
        guard let view = resolveTarget(webviewId) else {
            return "(no web view found on screen)"
        }
        let id = identifier(for: view)
        let controller = view.configuration.userContentController
        // 重复 start 幂等：先摘旧 handler 再装，避免 "already has handler" 抛异常。
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        let handler = ConsoleHandler(webviewId: id, store: Self.consoleStore)
        controller.add(handler, name: Self.handlerName)
        Self.handlers[id] = handler
        if Self.installedScripts.contains(id) == false {
            let userScript = WKUserScript(source: Self.consoleProbeJS,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: false)
            controller.addUserScript(userScript)
            Self.installedScripts.insert(id)
        }
        // 当前已经加载完的页面不会再跑 documentStart 脚本，所以立刻在页面 world 里补装一次。
        let result = await evaluate(Self.consoleProbeJS, on: view, pageWorld: true)
        switch result {
        case .success:
            return "OK. console capture armed for \(id). Only logs produced from now on are captured; "
                + "reproduce the problem, then call op='console_read'."
        case .failure(let error):
            return "Failed to arm console capture for \(id): \(error.localizedDescription)"
        }
    }

    @MainActor
    public func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?) async -> String {
        guard let view = resolveTarget(webviewId) else {
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
    public func consoleStop(webviewId: String?) async -> String {
        guard let view = resolveTarget(webviewId) else {
            return "(no web view found on screen)"
        }
        let id = identifier(for: view)
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        Self.handlers[id] = nil
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

    final class ConsoleHandler: NSObject, WKScriptMessageHandler {
        private let webviewId: String
        private let store: ConsoleStore

        init(webviewId: String, store: ConsoleStore) {
            self.webviewId = webviewId
            self.store = store
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
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

    private static func jsString(_ value: String?) -> String {
        guard let value else {
            return "null"
        }
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// 探针库每次随查询一起下发（几 KB 的解析成本可忽略），因此不需要「是否已注入」的状态机，
    /// 也不会在页面里留下任何常驻代码。
    private static func script(_ call: String) -> String {
        "(function(){\n" + probeJS + "\n" + call + "\n})()"
    }

    static var probeJS: String {
        probeJSCore + probeJSSummary + probeJSWalk + probeJSDetail + probeJSWhy + probeJSMisc
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
    var parts = [];
    var cur = el;
    while (cur && cur !== document.body && cur.parentElement) {
        parts.unshift(Array.prototype.indexOf.call(cur.parentElement.children, cur));
        cur = cur.parentElement;
    }
    return parts.join('/');
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
        var idx = parseInt(parts[i], 10);
        if (!cur || !cur.children || isNaN(idx) || idx >= cur.children.length) {
            return null;
        }
        cur = cur.children[idx];
    }
    return cur;
};
A.resolve = function (sel, path) {
    if (sel) {
        return document.querySelector(sel);
    }
    return A.node(path);
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
    var cs = getComputedStyle(el);
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
    if (r.bottom < 0 || r.right < 0 || r.top > window.innerHeight || r.left > window.innerWidth) {
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
    if (A.SKIP.indexOf(el.tagName.toLowerCase()) >= 0) {
        return;
    }
    A.emit(el, depth, lines);
    count.n += 1;
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
    return A.head() + '\n' + lines.join('\n');
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
    var cs = getComputedStyle(el);
    var out = [];
    out.push('node ' + A.label(el) + ' path=' + A.path(el));
    out.push(A.head());
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
        var ccs = getComputedStyle(cur);
        chain.push(A.label(cur) + ' w=' + Math.round(cr.width) + ' overflow=' + ccs.overflow + ' path=' + A.path(cur));
        if (!narrow && Math.round(cr.width) < window.innerWidth - 1) {
            narrow = A.label(cur) + ' w=' + Math.round(cr.width) + ' < viewport ' + window.innerWidth
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
    var cs = getComputedStyle(el);
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
    if (r.bottom < 0 || r.right < 0 || r.top > window.innerHeight || r.left > window.innerWidth) {
        reasons.push('outside viewport (rect=' + A.rectOf(el) + ' viewport=' + window.innerWidth + 'x' + window.innerHeight + ') — may just need scrolling');
    }
    var cur = el.parentElement;
    while (cur) {
        var ccs = getComputedStyle(cur);
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
        var cx = Math.min(Math.max(r.left + r.width / 2, 1), window.innerWidth - 1);
        var cy = Math.min(Math.max(r.top + r.height / 2, 1), window.innerHeight - 1);
        var top = document.elementFromPoint(cx, cy);
        if (top && top !== el && !el.contains(top) && !top.contains(el)) {
            reasons.push('covered at its center by ' + A.label(top) + ' (z-index ' + getComputedStyle(top).zIndex + ') path=' + A.path(top));
        }
    }
    if (reasons.length === 0) {
        reasons.push('nothing hides it: rect=' + A.rectOf(el) + ', it is laid out and visible. Check that this is the node the user means, or whether it is scrolled out of the visible area.');
    }
    return 'node ' + A.label(el) + ' path=' + A.path(el) + '\n' + A.head() + '\n- ' + reasons.join('\n- ');
};

"""#

    private static let probeJSMisc = #"""
A.probe = function (x, y, boundsWidth) {
    var ratio = (window.innerWidth && boundsWidth) ? (window.innerWidth / boundsWidth) : 1;
    var cx = x * ratio;
    var cy = y * ratio;
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
