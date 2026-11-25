import Foundation
import AppKit
import WebKit

// This harness exercises the four portable production helpers, not the UIKit controller's
// receiveBridgeMessage/store authorization gates. Do not duplicate those gates in a test fake.

/// Only captures the transport callbacks. All URL validation and response creation are production code.
final class H5SchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    var response: HTTPURLResponse?
    var data = Data()
    var error: Error?

    init(_ url: URL, method: String = "GET") {
        var request = URLRequest(url: url)
        request.httpMethod = method
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        events.append("response")
        self.response = response as? HTTPURLResponse
    }

    func didReceive(_ data: Data) {
        events.append("data")
        self.data.append(data)
    }

    func didFinish() {
        events.append("finish")
    }

    func didFailWithError(_ error: Error) {
        events.append("error")
        self.error = error
    }
}

@MainActor
final class H5Browser: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let handler: AppAgentWorkspaceSchemeHandler
    let webView: WKWebView
    let window: NSWindow
    var messages: [[String: Any]] = []
    var navigationFinished = false
    var navigationError: Error?

    init(content: AppAgentWorkspaceH5Content, state: [String: String] = [:]) throws {
        handler = AppAgentWorkspaceSchemeHandler(content: content)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: AppAgentWorkspaceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(WKUserScript(
            source: try AppAgentWorkspaceBridgeScript.source(documentID: handler.documentID, state: state),
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: configuration)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 800),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        super.init()
        configuration.userContentController.add(self, name: AppAgentWorkspaceBridgeScript.messageHandlerName)
        webView.navigationDelegate = self

        // A real window and AppKit event pumping are needed for requestAnimationFrame.
        window.orderFrontRegardless()
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: AppAgentWorkspaceBridgeScript.messageHandlerName)
        handler.invalidate()
        window.orderOut(nil)
    }

    func load() throws {
        webView.load(URLRequest(url: handler.documentURL))
        try wait("WKWebView navigation", timeout: 15) {
            self.navigationFinished || self.navigationError != nil
        }
        if let navigationError {
            throw navigationError
        }
        try wait("bridge ready") {
            self.messages.contains {
                $0["type"] as? String == "ready"
            }
        }
    }

    func wait(_ description: String, timeout: TimeInterval = 5, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            while let event = NSApplication.shared.nextEvent(
                matching: .any, until: Date(), inMode: .default, dequeue: true
            ) {
                NSApplication.shared.sendEvent(event)
            }
            NSApplication.shared.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try require(condition(), "timeout waiting for \(description)")
    }

    func evaluate(_ source: String) throws -> Any? {
        var done = false
        var result: Any?
        var failure: Error?
        webView.evaluateJavaScript(source) { value, error in
            result = value
            failure = error
            done = true
        }
        try wait("evaluateJavaScript") {
            done
        }
        if let failure {
            throw failure
        }
        return result
    }

    func assertJS(_ expression: String) throws {
        let result = try evaluate(expression)
        try require(result as? Bool == true, "JS returned \(String(describing: result)): \(expression)")
    }

    func waitForJS(_ expression: String) throws {
        try wait("JavaScript condition: \(expression)") {
            (try? self.evaluate(expression)) as? Bool == true
        }
    }

    func layout(epoch: Int = 7, active: Bool = true, hasSlot: Bool = true) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "epoch": epoch, "active": active, "hasSlot": hasSlot, "width": 400, "height": 800
        ])
        let json = String(decoding: data, as: UTF8.self)
        _ = try evaluate("window.__appAgentWorkspaceLayout(\(json)); null")
    }

    func messages(ofType type: String) -> [[String: Any]] {
        messages.filter {
            $0["type"] as? String == type
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            messages.append(body)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError = error
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
    }
}

@MainActor
extension H5Tests {
    /// 页面文件 + 插槽层开关拼成内容。html 是 index.html，resources 是其余文件。
    static func page(_ html: String = "<p>ok</p>", resources: [String: String] = [:], slot: Bool = false) throws
        -> AppAgentWorkspaceH5Content {
        var files = resources
        files["index.html"] = html
        return try content(files: files, slot: slot)
    }

    static func webKitTests() {
        run("webkit/real custom-scheme HTML, external JS/CSS/SVG, initial bridge state") {
            let browser = try H5Browser(content: page("""
                <link rel="stylesheet" href="assets/main.css">
                <script src="assets/main.js"></script>
                <body><div id="fixture">hello</div><img id="icon" src="assets/icon.svg"></body>
                """, resources: [
                    "assets/main.js": """
                    window.resourceLoaded = true;
                    window.stateAtLoad = window.appAgent.workspace.state.initial;
                    window.layoutEvents = [];
                    window.addEventListener("appagent:layout", event => {
                        window.layoutEvents.push(event.detail);
                    });
                    """,
                    "assets/main.css": """
                    #fixture {
                        color: rgb(12, 34, 56);
                    }
                    """,
                    "assets/icon.svg": """
                    <svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"></svg>
                    """
                ], slot: true), state: ["initial": "中文", "nested": "{\"value\":1}"])
            defer {
                browser.close()
            }
            try browser.load()
            try browser.assertJS("""
            window.resourceLoaded === true && window.stateAtLoad === "中文"
                && getComputedStyle(document.getElementById("fixture")).color === "rgb(12, 34, 56)"
                && document.getElementById("icon").naturalWidth === 2
                && getComputedStyle(document.body).backgroundColor === "rgba(0, 0, 0, 0)"
            """)
            schemeTests(webView: browser.webView)
            bridgeTests(browser)
            cspTests(browser)
        }
        run("bridge/auto passthrough: transparent areas reach the slot view, painted elements keep touches") {
            let browser = try H5Browser(content: page("""
                <div id="wrap" style="position:absolute;inset:0">
                    <div id="card" style="position:absolute;top:0;left:0;right:0;height:60px;
                        background:linear-gradient(#fff, rgba(255,255,255,0))">标题</div>
                    <div id="hint" style="position:absolute;top:300px;left:0;right:0;height:40px;
                        pointer-events:none;background:#fff">不挡地图</div>
                    <button id="go" style="position:absolute;bottom:20px;left:20px;width:100px;height:40px">导航</button>
                </div>
                """, slot: true))
            defer {
                browser.close()
            }
            try browser.load()
            try browser.layout()
            let latestAuto = { @MainActor () -> [String: Any]? in
                browser.messages(ofType: "setTouchRegions").last { message in
                    (message["rects"] as? [Any])?.isEmpty == false
                }
            }
            try browser.wait("automatic touch regions") {
                latestAuto() != nil
            }
            guard let message = latestAuto(),
                  let revision = message["revision"] as? Int,
                  let rects = message["rects"] as? [[Double]],
                  let blocks = message["blocks"] as? [[Double]] else {
                throw H5TestFailure(description: "malformed automatic payload")
            }
            try require(rects == [[0, 0, 400, 800]], "auto mode hands the whole viewport to the slot view: \(rects)")
            var policy = AppAgentWorkspaceUIPolicy()
            for _ in 0..<7 {
                policy.invalidate(size: CGSize(width: 400, height: 800))
            }
            let toRect = { (values: [Double]) -> CGRect in
                CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            }
            try require(policy.accept(epoch: 7, revision: revision, viewport: CGSize(width: 400, height: 800),
                                      rects: rects.map(toRect), blocks: blocks.map(toRect)))
            let size = policy.nativeSize
            try require(policy.resolve(.touch(point: CGPoint(x: 200, y: 450), size: size, occlusions: [])) == .slot, "empty area → slot")
            try require(policy.resolve(.touch(point: CGPoint(x: 200, y: 320), size: size, occlusions: [])) == .slot, "pointer-events:none → slot")
            try require(policy.resolve(.touch(point: CGPoint(x: 200, y: 30), size: size, occlusions: [])) == .web, "card keeps touches")
            try require(policy.resolve(.touch(point: CGPoint(x: 60, y: 760), size: size, occlusions: [])) == .web, "button keeps touches")

            // 页面自己上报后接管：之后的内容变化既不撤销页面的区域，也不再自动上报。
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[0, 100, 400, 100]]) === true")
            try require(browser.messages(ofType: "setTouchRegions").last?["blocks"] as? [Any] != nil)
            let count = browser.messages(ofType: "setTouchRegions").count
            _ = try browser.evaluate("document.getElementById('card').textContent = '改了'; null")
            let deadline = Date().addingTimeInterval(0.5)
            try browser.wait("animation frames") {
                Date() >= deadline
            }
            try require(browser.messages(ofType: "setTouchRegions").count == count,
                        "manual mode stops automatic reports and keeps page regions")
        }
    }

    static func schemeTests(webView: WKWebView) {
        run("scheme/GET bytes, MIME, headers and exact callback sequence") {
            let handler = AppAgentWorkspaceSchemeHandler(content: try page("<main>page</main>", resources: [
                "a.js": "window.a=1;", "a.css": "body { color: red; }",
                "a.json": "{\"ok\":true}", "a.svg": "<svg/>"
            ]))
            for (path, mime, body) in [
                ("a.js", "application/javascript", "window.a=1;"),
                ("a.css", "text/css", "body { color: red; }"),
                ("a.json", "application/json", "{\"ok\":true}"),
                ("a.svg", "image/svg+xml", "<svg/>"),
                ("index.html", "text/html", "")
            ] {
                let task = H5SchemeTask(handler.documentURL.deletingLastPathComponent().appendingPathComponent(path))
                handler.webView(webView, start: task)
                try require(task.events == ["response", "data", "finish"], "\(path): \(task.events)")
                try require(task.response?.statusCode == 200 && task.response?.mimeType == mime)
                try require(task.response?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                try require(task.response?.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
                try require(task.response?.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
                try require(task.response?.value(forHTTPHeaderField: "Content-Security-Policy") != nil)
                if path == "index.html" {
                    try require(String(decoding: task.data, as: UTF8.self).contains("<main>page</main>"))
                } else {
                    try require(task.data == Data(body.utf8))
                }
            }
        }
        run("scheme/reject cross-document, network, path traversal, query, auth and non-GET") {
            let handler = AppAgentWorkspaceSchemeHandler(content: try page(resources: ["a.js": "secret"]))
            let other = AppAgentWorkspaceSchemeHandler(content: try page())
            let origin = "\(AppAgentWorkspaceSchemeHandler.scheme)://\(handler.documentID)"
            let urls = [
                other.documentURL.absoluteString, "https://example.invalid/a.js",
                "file:///a.js", "\(origin)/missing.js", "\(origin)/../a.js",
                "\(origin)/%2e%2e/a.js", "\(origin)/%252e%252e/a.js",
                "\(origin)/a%2ejs", "\(origin)//a.js", "\(origin)/./a.js",
                "\(origin)/a.js?q=1", "\(origin)/a.js#fragment",
                "\(AppAgentWorkspaceSchemeHandler.scheme)://user@\(handler.documentID)/a.js",
                "\(AppAgentWorkspaceSchemeHandler.scheme)://\(handler.documentID):80/a.js"
            ]
            for text in urls {
                guard let url = URL(string: text) else {
                    throw H5TestFailure(description: "invalid test URL: \(text)")
                }
                let task = H5SchemeTask(url)
                handler.webView(webView, start: task)
                try require(task.events == ["error"] && task.data.isEmpty && task.response == nil, text)
            }
            for method in ["POST", "HEAD", "PUT"] {
                let task = H5SchemeTask(handler.documentURL, method: method)
                handler.webView(webView, start: task)
                try require(task.events == ["error"], method)
            }
        }
        run("scheme/invalidation revokes old page and resources without affecting new handler") {
            let first = AppAgentWorkspaceSchemeHandler(content: try page(resources: ["a.js": "old"]))
            let second = AppAgentWorkspaceSchemeHandler(content: try page(resources: ["a.js": "new"]))
            try require(first.documentID != second.documentID)
            first.invalidate()
            for path in ["index.html", "a.js"] {
                let task = H5SchemeTask(first.documentURL.deletingLastPathComponent().appendingPathComponent(path))
                first.webView(webView, start: task)
                try require(task.events == ["error"] && task.data.isEmpty)
            }
            let task = H5SchemeTask(second.documentURL.deletingLastPathComponent().appendingPathComponent("a.js"))
            second.webView(webView, start: task)
            try require(task.data == Data("new".utf8) && task.events.last == "finish")
        }
    }

    static func bridgeTests(_ browser: H5Browser) {
        run("bridge/state copy isolation, read-only API and pending pre-layout state") {
            try browser.assertJS("""
            (() => {
                const copy = window.appAgent.workspace.state;
                copy.initial = "changed";
                return window.appAgent.workspace.state.initial === "中文"
                    && Object.isFrozen(window.appAgent) && Object.isFrozen(window.appAgent.workspace)
                    && Object.isFrozen(window.hostApp)
                    && Object.getOwnPropertyDescriptor(window, "appAgent").writable === false
                    && Object.getOwnPropertyDescriptor(window, "hostApp").writable === false
                    && window.appWorkspace === undefined;
            })()
            """)
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[1, 2, 30, 40]]) === false")
            _ = try browser.evaluate("""
            window.appAgent.workspace.setState("queued", "1");
            window.appAgent.workspace.setState("queued", "2");
            null
            """)
            try require(browser.messages(ofType: "setState").isEmpty)
            try browser.layout()
            try browser.wait("pending state flushed") {
                !browser.messages(ofType: "setState").isEmpty
            }
            let states = browser.messages(ofType: "setState")
            try require(states.count == 1 && states[0]["key"] as? String == "queued" && states[0]["value"] as? String == "2")
            try require(states[0]["documentID"] as? String == browser.handler.documentID)
            try browser.assertJS("window.layoutEvents.at(-1).epoch === 7")
        }
        run("bridge/setState is text by key: message, delete, type and byte limits") {
            let initialCount = browser.messages(ofType: "setState").count
            _ = try browser.evaluate("window.appAgent.workspace.setState(\"text\", \"中文\"); null")
            try browser.wait("setState") {
                browser.messages(ofType: "setState").count > initialCount
            }
            let message = browser.messages(ofType: "setState").last!
            try require(message["key"] as? String == "text" && message["value"] as? String == "中文")
            _ = try browser.evaluate("window.appAgent.workspace.setState(\"text\", null); null")
            try browser.wait("delete") {
                browser.messages(ofType: "setState").last?["value"] is NSNull
            }
            try browser.assertJS("""
            (() => {
                if ("text" in window.appAgent.workspace.state) {
                    return false;
                }
                for (const [key, value] of [["", "x"], [1, "x"], ["k", 1], ["k", {}], ["k", undefined]]) {
                    try {
                        window.appAgent.workspace.setState(key, value);
                        return false;
                    } catch (error) {
                        if (!(error instanceof TypeError)) {
                            return false;
                        }
                    }
                }
                try {
                    window.appAgent.workspace.setState("p", "a".repeat(131072));
                    return false;
                } catch (error) {
                    return error instanceof RangeError && !("p" in window.appAgent.workspace.state);
                }
            })()
            """)
        }
        run("bridge/state pushed from native replaces state and fires appagent:state without reload") {
            _ = try browser.evaluate("""
            window.stateEvents = [];
            window.addEventListener("appagent:state", event => {
                window.stateEvents.push(event.detail);
            });
            window.__appAgentWorkspaceState({"tab": "2"});
            null
            """)
            try browser.assertJS("""
            window.appAgent.workspace.state.tab === "2" && !("initial" in window.appAgent.workspace.state)
                && window.stateEvents.length === 1 && window.stateEvents[0].tab === "2"
                && window.resourceLoaded === true
            """)
        }
        run("bridge/invoke posts one call at a time and resolves only on its own callID") {
            let count = browser.messages(ofType: "invoke").count
            _ = try browser.evaluate("""
            window.invokeResults = [];
            window.hostApp.invoke("open_page", {route: "search", params: {query: "咖啡"}})
                .then(result => window.invokeResults.push(result));
            window.hostApp.invoke("open_page", {route: "search", params: {query: "第二次"}})
                .then(result => window.invokeResults.push(result));
            null
            """)
            try browser.wait("invoke message") {
                browser.messages(ofType: "invoke").count > count
            }
            let message = browser.messages(ofType: "invoke").last!
            let args = message["args"] as? [String: Any]
            let params = args?["params"] as? [String: String]
            guard let callID = message["callID"] as? Int,
                  message["tool"] as? String == "open_page",
                  params?["query"] == "咖啡" else {
                throw H5TestFailure(description: "malformed invoke payload: \(message)")
            }
            try browser.waitForJS("window.invokeResults.length === 1 && window.invokeResults[0].ok === false")
            try require(browser.messages(ofType: "invoke").count == count + 1)
            _ = try browser.evaluate("window.__appAgentInvokeResult(\(callID + 100), {ok: true, result: 'stale'}); null")
            _ = try browser.evaluate("window.__appAgentInvokeResult(\(callID), {ok: true, result: 'opened'}); null")
            try browser.waitForJS("window.invokeResults.length === 2 && window.invokeResults[1].result === 'opened'")
        }
        run("bridge/send posts without a pending call and rejects non-object args") {
            let count = browser.messages(ofType: "send").count
            try browser.assertJS("""
            window.hostApp.send("log_event", {name: "open"}) === true
                && window.hostApp.send("log_event", [1]) === false
                && window.hostApp.send("", {}) === false
            """)
            try browser.wait("send message") {
                browser.messages(ofType: "send").count > count
            }
            let message = browser.messages(ofType: "send").last!
            let args = message["args"] as? [String: String]
            guard message["tool"] as? String == "log_event", args?["name"] == "open", message["callID"] == nil else {
                throw H5TestFailure(description: "malformed send payload: \(message)")
            }
            try require(browser.messages(ofType: "send").count == count + 1)
        }
        run("bridge/real touch message accepted by native policy, stale replay revoked") {
            let count = browser.messages(ofType: "setTouchRegions").count
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[10, 20, 100, 150]]) === true")
            try browser.wait("touch message") {
                browser.messages(ofType: "setTouchRegions").count > count
            }
            let message = browser.messages(ofType: "setTouchRegions").last!
            try require(message["documentID"] as? String == browser.handler.documentID)
            try require(message["epoch"] as? Int == 7)
            guard let revision = message["revision"] as? Int,
                  let viewport = message["viewport"] as? [String: Double],
                  let width = viewport["width"], let height = viewport["height"],
                  let rects = message["rects"] as? [[Double]], rects == [[10, 20, 100, 150]] else {
                throw H5TestFailure(description: "malformed touch payload: \(message)")
            }
            var policy = AppAgentWorkspaceUIPolicy()
            for _ in 0..<7 {
                policy.invalidate(size: CGSize(width: width, height: height))
            }
            let converted = rects.map {
                CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3])
            }
            try require(policy.accept(epoch: 7, revision: revision,
                                      viewport: CGSize(width: width, height: height), rects: converted))
            try require(policy.resolve(.touch(point: CGPoint(x: 20, y: 30), size: policy.nativeSize, occlusions: [])) == .slot)
            try require(!policy.accept(epoch: 7, revision: revision,
                                       viewport: CGSize(width: width, height: height), rects: converted))
            try require(policy.regions.isEmpty)
        }
        run("bridge/viewport resize and visualViewport changes revoke manual regions") {
            for event in [
                "window.dispatchEvent(new Event('resize'))",
                "window.visualViewport.dispatchEvent(new Event('resize'))",
                "window.visualViewport.dispatchEvent(new Event('scroll'))"
            ] {
                try browser.assertJS("window.appAgent.workspace.setTouchRegions([[10, 20, 30, 40]]) === true")
                let count = browser.messages(ofType: "setTouchRegions").count
                _ = try browser.evaluate(event + "; null")
                try browser.wait("layout invalidation after \(event)") {
                    browser.messages(ofType: "setTouchRegions").count > count
                }
                try require((browser.messages(ofType: "setTouchRegions").last?["rects"] as? [Any])?.isEmpty == true)
            }
        }
        run("bridge/manual regions survive DOM mutation and scroll until the page updates them") {
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[10, 20, 30, 40]]) === true")
            let count = browser.messages(ofType: "setTouchRegions").count
            _ = try browser.evaluate("""
            window.layoutEvents.length = 0;
            document.getElementById('fixture').textContent = 'changed';
            window.dispatchEvent(new Event('scroll'));
            null
            """)
            try browser.waitForJS("window.layoutEvents.length > 0")
            try require(browser.messages(ofType: "setTouchRegions").count == count,
                        "content changes must not revoke page-owned regions")
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[50, 60, 70, 80]]) === true")
            try require(browser.messages(ofType: "setTouchRegions").last?["rects"] as? [[Int]] == [[50, 60, 70, 80]])
        }
        run("bridge/DOM mutation requests a fresh layout event on animation frame") {
            _ = try browser.evaluate("""
            window.layoutEvents.length = 0;
            window.frameProbe = false;
            requestAnimationFrame(() => {
                window.frameProbe = true;
                document.getElementById("fixture").setAttribute("data-test", "changed");
            });
            null
            """)
            do {
                try browser.waitForJS("window.layoutEvents.length > 0")
            } catch {
                let diagnostic = try? browser.evaluate("""
                JSON.stringify({
                    visibility: document.visibilityState,
                    frameFired: window.frameProbe,
                    events: window.layoutEvents.length
                })
                """)
                throw H5TestFailure(description: "\(error); browser=\(String(describing: diagnostic)); "
                    + "windowVisible=\(browser.window.isVisible), occlusion=\(browser.window.occlusionState.rawValue)")
            }
            try browser.assertJS("""
            window.layoutEvents.at(-1).epoch === 7
                && window.layoutEvents.at(-1).active === true
                && document.getElementById("fixture").getAttribute("data-test") === "changed"
            """)
        }
        run("bridge/animation: manual regions honored, automatic mode suppressed until end") {
            for (start, end) in [("animationstart", "animationend"), ("transitionrun", "transitioncancel")] {
                _ = try browser.evaluate("""
                document.dispatchEvent(new Event("\(start)"));
                window.appAgent.workspace.setTouchRegions([[10, 20, 30, 40]]);
                null
                """)
                try require(browser.messages(ofType: "setTouchRegions").last?["rects"] as? [[Int]] == [[10, 20, 30, 40]])
                try browser.assertJS("window.appAgent.workspace.useAutoTouchRegions() === true")
                try require((browser.messages(ofType: "setTouchRegions").last?["rects"] as? [Any])?.isEmpty == true,
                            "automatic report stays empty while animating")
                _ = try browser.evaluate("""
                document.dispatchEvent(new Event("\(end)"));
                null
                """)
                try browser.wait("automatic report after \(end)") {
                    (browser.messages(ofType: "setTouchRegions").last?["rects"] as? [Any])?.isEmpty == false
                }
            }
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[10, 20, 30, 40]]) === true")
        }
        run("bridge/polygon regions reach native policy with even-odd hit testing") {
            try browser.assertJS("""
            window.appAgent.workspace.setTouchRegions([
                [0, 0, 50, 50],
                {points: [[100, 100], [300, 100], [200, 300]]}
            ]) === true
            """)
            let message = browser.messages(ofType: "setTouchRegions").last!
            guard let revision = message["revision"] as? Int,
                  let rects = message["rects"] as? [[Double]],
                  let polygons = message["polygons"] as? [[[Double]]], polygons.count == 1 else {
                throw H5TestFailure(description: "malformed polygon payload: \(message)")
            }
            var policy = AppAgentWorkspaceUIPolicy()
            for _ in 0..<7 {
                policy.invalidate(size: CGSize(width: 400, height: 800))
            }
            let points = polygons[0].map { pair in
                CGPoint(x: pair[0], y: pair[1])
            }
            let rect = CGRect(x: rects[0][0], y: rects[0][1], width: rects[0][2], height: rects[0][3])
            try require(policy.accept(epoch: 7, revision: revision, viewport: CGSize(width: 400, height: 800),
                                      rects: [rect], polygons: [points]))
            let size = policy.nativeSize
            try require(policy.resolve(.touch(point: CGPoint(x: 10, y: 10), size: size, occlusions: [])) == .slot, "rect region")
            try require(policy.resolve(.touch(point: CGPoint(x: 200, y: 150), size: size, occlusions: [])) == .slot, "inside triangle")
            try require(policy.resolve(.touch(point: CGPoint(x: 110, y: 280), size: size, occlusions: [])) == .web, "outside triangle")
            try require(!policy.accept(epoch: 7, revision: revision + 1, viewport: CGSize(width: 400, height: 800),
                                       rects: [], polygons: [[CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]]),
                        "polygon needs at least 3 points")
            try require(!policy.accept(epoch: 7, revision: revision + 2, viewport: CGSize(width: 400, height: 800),
                                       rects: [], polygons: [[CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0),
                                                              CGPoint(x: 0, y: 10)]]),
                        "polygon must stay inside the viewport")
        }
        run("bridge/inactive old page suppressed, h5 disallows slot regions, epoch resync") {
            try browser.layout(epoch: 8, active: false)
            let count = browser.messages.count
            _ = try browser.evaluate("window.appAgent.workspace.setState(\"inactive\", \"1\"); null")
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[1, 2, 3, 4]]) === false")
            try require(browser.messages.count == count)
            try browser.layout(epoch: 9, hasSlot: false)
            try browser.assertJS("window.appAgent.workspace.setTouchRegions([[1, 2, 3, 4]]) === false")
            try browser.layout(epoch: 10)
            let latest = browser.messages(ofType: "setTouchRegions").last
            try require(latest?["epoch"] as? Int == 10)
            try browser.assertJS("""
            window.layoutEvents.at(-1).epoch === 10
                && window.layoutEvents.at(-1).width === 400
                && window.layoutEvents.every(event => event.active === true)
            """)
            let other = try H5Browser(content: page(slot: true), state: ["page": "2"])
            defer {
                other.close()
            }
            try other.load()
            try other.layout()
            _ = try other.evaluate("window.appAgent.workspace.setState(\"page\", \"3\"); null")
            try require(other.messages(ofType: "setState").last?["documentID"] as? String == other.handler.documentID)
            try require(other.handler.documentID != browser.handler.documentID)
            try browser.assertJS("window.appAgent.workspace.state.inactive === \"1\"")
            try other.assertJS("window.appAgent.workspace.state.page === \"3\"")
        }
        run("bridge/layout event detail cannot mutate native layout epoch") {
            _ = try browser.evaluate("""
            window.addEventListener("appagent:layout", event => {
                event.detail.epoch = -100;
            }, {
                once: true
            });
            null
            """)
            try browser.layout(epoch: 11)
            let count = browser.messages(ofType: "setTouchRegions").count
            _ = try browser.evaluate("window.appAgent.workspace.setTouchRegions([[1, 2, 3, 4]]); null")
            try browser.wait("touch with native epoch") {
                browser.messages(ofType: "setTouchRegions").count > count
            }
            try require(browser.messages(ofType: "setTouchRegions").last?["epoch"] as? Int == 11)
        }
    }

    static func cspTests(_ browser: H5Browser) {
        run("csp/browser rejects network fetch/script/image/frame with violation events") {
            _ = try browser.evaluate("""
            window.cspViolations = [];
            document.addEventListener("securitypolicyviolation", event => {
                window.cspViolations.push({
                    directive: event.effectiveDirective,
                    blocked: event.blockedURI
                });
            });
            window.fetchBlocked = false;
            fetch("https://workspace-test.invalid/data").catch(() => {
                window.fetchBlocked = true;
            });
            const remoteScript = document.createElement("script");
            remoteScript.src = "https://workspace-test.invalid/evil.js";
            document.body.appendChild(remoteScript);
            const remoteImage = document.createElement("img");
            remoteImage.src = "https://workspace-test.invalid/image.png";
            document.body.appendChild(remoteImage);
            const remoteFrame = document.createElement("iframe");
            remoteFrame.src = "https://workspace-test.invalid/frame";
            document.body.appendChild(remoteFrame);
            null
            """)
            var observed = false
            try browser.wait("four browser CSP violations") {
                observed = (try? browser.evaluate("""
                window.fetchBlocked && ["connect-src", "script-src-elem", "img-src", "frame-src"].every(
                    directive => window.cspViolations.some(item => item.directive === directive)
                )
                """)) as? Bool == true
                return observed
            }
            try require(observed)
        }
        run("csp/browser rejects resources belonging to an old document origin") {
            let old = AppAgentWorkspaceSchemeHandler(content: try page())
            let encoded = String(decoding: try JSONEncoder().encode(old.documentURL.absoluteString), as: UTF8.self)
            _ = try browser.evaluate("""
            window.crossOriginBlocked = false;
            fetch(\(encoded)).catch(() => {
                window.crossOriginBlocked = true;
            });
            null
            """)
            try browser.wait("cross-document fetch rejection") {
                (try? browser.evaluate("window.crossOriginBlocked")) as? Bool == true
            }
            try browser.assertJS("""
            window.cspViolations.some(item => item.directive === "connect-src"
                && item.blocked.includes("\(old.documentID)"))
            """)
        }
    }
}
