#if canImport(UIKit) && canImport(WebKit)
import XCTest
import UIKit
import WebKit
import ObjectiveC.runtime
@testable import AppAgent

/// Real HTML and UIKit overlays. Hosted runners use UIWindow; hostless runners inject
/// one UIView root. Production scene selection remains separate from fixture discovery.
@MainActor
final class WebInspectViewTests: XCTestCase {

    /// Hold real WebKit results to force clear/cancel/reselect before a late callback.
    @MainActor private final class GeometryGate {
        var holdGeometry = false
        var heldGeometry: [() -> Void] = []

        func receive(_ callback: @escaping @MainActor () -> Void) {
            if holdGeometry {
                heldGeometry.append(callback)
            } else {
                callback()
            }
        }

        func deliverGeometry() {
            let callbacks = heldGeometry
            heldGeometry.removeAll()
            for callback in callbacks {
                callback()
            }
        }
    }

    @MainActor private final class Page: NSObject, WKNavigationDelegate {
        let window: UIView
        let web: WKWebView
        let geometry = GeometryGate()
        let provider: DefaultWebInspectProvider
        let context: HostInspectionContext
        let id: String
        var loaded = false

        init(window: UIView) {
            self.window = window
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            window.addSubview(web)
            let binding = UUID().uuidString
            context = HostInspectionContext(scope: .host, sceneIdentifier: binding)
            provider = DefaultWebInspectProvider(testingRoot: window, binding: binding)
            id = DefaultWebInspectProvider.identity(for: web)
            super.init()
            WebInspectHighlight.controller(for: web).geometryDelivery = { [weak geometry] callback in
                if let geometry {
                    geometry.receive(callback)
                } else {
                    callback()
                }
            }
            web.navigationDelegate = self
            window.isHidden = false
            window.layoutIfNeeded()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
        }

        func close() {
            provider.stopAllInspections()
            WebInspectHighlight.existingController(for: web)?.stop()
            geometry.holdGeometry = false
            geometry.deliverGeometry()
            web.stopLoading()
            web.navigationDelegate = nil
            web.removeFromSuperview()
            window.isHidden = true
        }

        func highlight(selector: String? = "#target", path: String? = nil) async -> String {
            await provider.highlight(webviewId: id, selector: selector, path: path, context: context)
        }
    }

    private func page() async throws -> Page {
        let scene = UIApplication.shared.connectedScenes.compactMap { scene in
            scene as? UIWindowScene
        }.first { scene in
            scene.activationState == .foregroundActive
        }
        let window: UIView
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        }
        let page = Page(window: window)
        page.web.loadHTMLString(Self.html, baseURL: URL(string: "https://webinspect.invalid/"))
        do {
            try await eventually(attempts: 1500) {
                page.loaded && !page.web.isLoading
            }
        } catch {
            page.close()
            throw error
        }
        return page
    }

    private func eventually(attempts: Int = 250, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for WebKit/overlay state")
        throw NSError(domain: "WebInspectViewTests", code: 1)
    }

    private func js(_ source: String, in web: WKWebView) async throws {
        let message: String? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(source) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        XCTAssertNil(message)
    }

    func testIdentityContractAndRegistryDoNotRetainWebView() async throws {
        weak var weakWeb: WKWebView?
        weak var weakControl: WKWebView?
        weak var weakController: WebInspectHighlight?
        var firstID: String?
        autoreleasepool {
            let control = WKWebView()
            weakControl = control
            let web = WKWebView()
            weakWeb = web
            weakController = WebInspectHighlight.controller(for: web)
            let key = unsafeBitCast(NSSelectorFromString("appagent.webview.identity.v1"), to: UnsafeRawPointer.self)
            let externalID = NSUUID().uuidString
            objc_setAssociatedObject(web, key, externalID as NSString, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            firstID = DefaultWebInspectProvider.identity(for: web)
            XCTAssertEqual(firstID, externalID, "Reuse the ID written by an independent component")
            XCTAssertEqual(DefaultWebInspectProvider.identity(for: web), externalID)
        }
        // WebKit schedules initialization/teardown on later run-loop turns. An immediate
        // weak-nil check fails even for the untouched control. A bounded wait still detects
        // a registry/controller retain cycle rather than removing the lifecycle assertion.
        try await eventually {
            weakControl == nil && weakWeb == nil && weakController == nil
        }
        XCTAssertNil(weakControl)
        XCTAssertNil(weakWeb)
        XCTAssertNil(weakController)
        let another = WKWebView()
        let anotherID = DefaultWebInspectProvider.identity(for: another)
        XCTAssertNotEqual(anotherID, firstID)
        XCTAssertNotNil(UUID(uuidString: anotherID))
    }

    func testDOMPathsAttributesAndIframeShadowBoundaries() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        let summary = await page.provider.domSummary(webviewId: page.id, path: nil, maxNodes: 30, context: page.context)
        XCTAssertTrue(summary.contains("open shadow root: path=2/shadow"), summary)
        XCTAssertTrue(summary.contains("same-origin iframe: path=1/frame"), summary)
        let detail = await page.provider.domQuery(webviewId: page.id, selector: "#inside", path: "1/frame", context: page.context)
        XCTAssertTrue(detail.contains("path=1/frame/0"), detail)
        XCTAssertTrue(detail.contains("\"data-fixture\":\"iframe\""), detail)
        XCTAssertTrue(detail.contains("owner-document layout viewport"), detail)
        let shadow = await page.provider.domQuery(webviewId: page.id, selector: nil, path: "2/shadow/0", context: page.context)
        XCTAssertTrue(shadow.contains("button#shadow-button"), shadow)
        let closed = await page.provider.domQuery(webviewId: page.id, selector: nil, path: "3/shadow/0", context: page.context)
        XCTAssertTrue(closed.hasPrefix("JS error: Unsupported closed"), closed)
        let crossOrigin = await page.provider.domQuery(webviewId: page.id, selector: nil, path: "4/frame/0", context: page.context)
        XCTAssertTrue(crossOrigin.contains("Unsupported cross-origin or sandboxed"), crossOrigin)
        for path in ["1/frame/0", "2/shadow/0"] {
            let result = await page.highlight(selector: nil, path: path)
            XCTAssertTrue(result.hasPrefix("OK."), result)
            XCTAssertNotNil(WebInspectHighlight.existingController(for: page.web)?.overlay?.outline.path)
        }
    }

    func testNativeOutlineIsAccurateTouchTransparentAndDoesNotMutateDOM() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        try await js("window.mutations = 0; new MutationObserver(function () { window.mutations++; }).observe(document.body, {subtree:true, childList:true, attributes:true});", in: page.web)
        let point = CGPoint(x: 45, y: 320)
        let before = page.web.hitTest(point, with: nil)
        XCTAssertNotNil(before, "Touch transparency must compare actual hit targets")
        let result = await page.highlight()
        XCTAssertTrue(result.hasPrefix("OK."), result)
        let overlay = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web)?.overlay)
        let rect = try XCTUnwrap(overlay.outline.path?.boundingBoxOfPath)
        XCTAssertEqual(rect.minX, 20, accuracy: 2)
        XCTAssertEqual(rect.minY, 300, accuracy: 2)
        XCTAssertEqual(rect.width, 100, accuracy: 2)
        XCTAssertEqual(rect.height, 40, accuracy: 2)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertNil(overlay.hitTest(point, with: nil))
        XCTAssertTrue(page.web.hitTest(point, with: nil) === before)
        let mutationCount = await page.provider.eval(webviewId: page.id, script: "return window.mutations;", inPageWorld: true, context: page.context)
        XCTAssertEqual(mutationCount, "0")
        _ = await page.provider.clearHighlight(webviewId: page.id, context: page.context)
        XCTAssertNil(overlay.superview)
    }

    func testScrollLayoutAndNavigationClearAndLateSamplesCannotRedraw() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        let result = await page.highlight()
        XCTAssertTrue(result.hasPrefix("OK."), result)
        let controller = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web))
        try await js("window.scrollTo(0, 100);", in: page.web)
        try await eventually {
            guard let rect = controller.overlay?.outline.path?.boundingBoxOfPath else {
                return false
            }
            return abs(rect.minY - 200) < 3
        }
        try await js("document.getElementById('target').style.width = '140px';", in: page.web)
        try await eventually {
            guard let rect = controller.overlay?.outline.path?.boundingBoxOfPath else {
                return false
            }
            return abs(rect.width - 140) < 3
        }
        page.web.frame.size.width = 340
        try await eventually {
            controller.overlay?.frame.width == 340
        }
        controller.refresh()
        page.loaded = false
        page.web.loadHTMLString("<body><button id='target'>new document</button></body>", baseURL: nil)
        try await eventually {
            page.loaded && controller.overlay == nil
        }
        // Drain WebKit's queue after the old sample and verify that it stayed cleared.
        _ = await page.provider.domSummary(webviewId: page.id, path: nil, maxNodes: 10, context: page.context)
        XCTAssertNil(controller.overlay)
    }

    func testHiddenDetachedAndScopeChangedTargetsCannotDraw() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        let result = await page.highlight()
        XCTAssertTrue(result.hasPrefix("OK."), result)
        let controller = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web))
        controller.refresh()
        page.window.isHidden = true
        controller.refresh()
        XCTAssertNil(controller.overlay)
        let hidden = await page.highlight()
        XCTAssertTrue(hidden.hasPrefix("Inspection denied:"), hidden)
        let defaultResult = await page.provider.domQuery(webviewId: nil, selector: "#target", path: nil, context: page.context)
        XCTAssertFalse(defaultResult.contains("data-fixture"), "A default query must not select this hidden fixture")
        page.window.isHidden = false
        let outsideScope = await page.provider.domQuery(webviewId: page.id, selector: "#target", path: nil,
                                                       context: .init(scope: .appagent, sceneIdentifier: page.context.sceneIdentifier))
        XCTAssertTrue(outsideScope.hasPrefix("Inspection denied:"), outsideScope)
        _ = await page.highlight()
        page.web.removeFromSuperview()
        controller.refresh()
        XCTAssertNil(controller.overlay)
    }

    func testClearInvalidatesOutstandingGeometry() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        let result = await page.highlight()
        XCTAssertTrue(result.hasPrefix("OK."), result)
        let controller = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web))
        page.geometry.holdGeometry = true
        controller.refresh()
        try await eventually {
            !page.geometry.heldGeometry.isEmpty
        }
        let clear = await page.provider.clearHighlight(webviewId: page.id, context: page.context)
        XCTAssertTrue(clear.hasPrefix("OK."), clear)
        page.geometry.deliverGeometry()
        XCTAssertNil(controller.overlay, "The old asynchronous geometry must not resurrect a cleared selection")
    }

    func testPendingSelectionCancellationAndReplacementIgnoreLateResults() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        page.geometry.holdGeometry = true
        var firstResult: String?
        let first = Task { @MainActor in
            firstResult = await page.highlight()
        }
        defer {
            first.cancel()
        }
        try await eventually {
            page.geometry.heldGeometry.count == 1
        }
        first.cancel()
        try await eventually {
            firstResult != nil
        }
        XCTAssertTrue(try XCTUnwrap(firstResult).hasPrefix("Inspection denied:"))
        let controller = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web))
        XCTAssertNil(controller.overlay)
        page.geometry.holdGeometry = false
        let secondResult = await page.highlight(selector: nil, path: "2/shadow/0")
        XCTAssertTrue(secondResult.hasPrefix("OK."), secondResult)
        let overlay = try XCTUnwrap(controller.overlay)
        let rect = overlay.outline.path?.boundingBoxOfPath
        page.geometry.deliverGeometry()
        XCTAssertTrue(controller.overlay === overlay)
        XCTAssertEqual(overlay.outline.path?.boundingBoxOfPath, rect)
        let statePath = await page.provider.eval(
            webviewId: page.id, script: "return window.__appagentHighlight.node.id;",
            inPageWorld: false, context: page.context
        )
        XCTAssertEqual(statePath, "shadow-button")
    }

    func testScopeChangeDeactivationAndDOMReplacementClearSelection() async throws {
        let page = try await page()
        defer {
            page.close()
        }
        let result = await page.highlight()
        XCTAssertTrue(result.hasPrefix("OK."), result)
        let controller = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web))
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(controller.overlay)
        _ = await page.highlight()
        try await js("document.getElementById('target').outerHTML = '<div id=\"target\">replacement</div>';", in: page.web)
        try await eventually {
            controller.overlay == nil
        }
        let replacement = await page.highlight()
        XCTAssertTrue(replacement.hasPrefix("OK."), replacement)
        page.geometry.holdGeometry = true
        controller.refresh()
        try await eventually {
            !page.geometry.heldGeometry.isEmpty
        }
        HostInspectionUIKit.markAppAgentOwned(page.window)
        page.geometry.deliverGeometry()
        XCTAssertNil(controller.overlay, "A host sample must not draw after ownership changes")
        let denied = await page.highlight()
        XCTAssertTrue(denied.hasPrefix("Inspection denied:"), denied)
    }

    func testStopAllInspectionsClearsKnownHighlightsAndOwnConsoleWithoutLateRevival() async throws {
        let page = try await page()
        let other = try await self.page()
        defer {
            page.close()
            other.close()
        }
        let hostScript = WKUserScript(source: "window.hostMarker = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let content = page.web.configuration.userContentController
        content.addUserScript(hostScript)
        let armed = await page.provider.consoleStart(webviewId: page.id, context: page.context)
        XCTAssertTrue(armed.hasPrefix("OK."), armed)
        let otherArmed = await other.provider.consoleStart(webviewId: other.id, context: other.context)
        XCTAssertTrue(otherArmed.hasPrefix("OK."), otherArmed)
        let selected = await page.highlight()
        XCTAssertTrue(selected.hasPrefix("OK."), selected)
        let otherSelected = await other.highlight()
        XCTAssertTrue(otherSelected.hasPrefix("OK."), otherSelected)
        try await js("console.log('before-reset');", in: page.web)
        try await eventually {
            DefaultWebInspectProvider.consoleStore.read(webviewId: page.id, limit: 10, sinceSeq: nil)
                .contains { record in
                    record.line.contains("before-reset")
                }
        }
        let history = DefaultWebInspectProvider.consoleStore.read(webviewId: page.id, limit: 10, sinceSeq: nil).map(\.line)
        let scripts = content.userScripts.map(\.source)
        let controller = try XCTUnwrap(WebInspectHighlight.existingController(for: page.web))
        let overlay = try XCTUnwrap(controller.overlay)
        page.geometry.holdGeometry = true
        controller.refresh()
        try await eventually {
            !page.geometry.heldGeometry.isEmpty
        }
        // A view added after discovery must neither be inspected nor gain a controller.
        let unknown = WKWebView(frame: .zero)
        page.window.addSubview(unknown)
        page.provider.stopAllInspections()
        page.provider.stopAllInspections()
        XCTAssertNil(controller.overlay)
        XCTAssertNil(overlay.superview, "Removal must happen before stopAllInspections returns")
        XCTAssertNil(WebInspectHighlight.existingController(for: unknown))
        XCTAssertNotNil(WebInspectHighlight.existingController(for: other.web)?.overlay)
        XCTAssertEqual(content.userScripts.map(\.source), scripts)
        page.geometry.deliverGeometry()
        XCTAssertNil(controller.overlay)
        try await js("console.log('after-reset');", in: page.web)
        try await js("console.log('other-still-armed');", in: other.web)
        try await eventually {
            DefaultWebInspectProvider.consoleStore.read(webviewId: other.id, limit: 10, sinceSeq: nil)
                .contains { record in
                    record.line.contains("other-still-armed")
                }
        }
        XCTAssertEqual(DefaultWebInspectProvider.consoleStore.read(webviewId: page.id, limit: 10, sinceSeq: nil).map(\.line), history)

        // Reset also resolves an initial selection whose real WebKit reply is held.
        var pendingResult: String?
        let pending = Task { @MainActor in
            pendingResult = await page.highlight()
        }
        defer {
            pending.cancel()
        }
        try await eventually {
            !page.geometry.heldGeometry.isEmpty
        }
        page.provider.stopAllInspections()
        XCTAssertNil(controller.overlay)
        try await eventually {
            pendingResult != nil
        }
        XCTAssertTrue(try XCTUnwrap(pendingResult).hasPrefix("Inspection denied:"))
        page.geometry.holdGeometry = false
        let nextSelection = await page.highlight(selector: nil, path: "2/shadow/0")
        XCTAssertTrue(nextSelection.hasPrefix("OK."), nextSelection)
        let nextOverlay = try XCTUnwrap(controller.overlay)
        let nextRect = nextOverlay.outline.path?.boundingBoxOfPath
        page.geometry.deliverGeometry()
        XCTAssertTrue(controller.overlay === nextOverlay)
        XCTAssertEqual(nextOverlay.outline.path?.boundingBoxOfPath, nextRect)
        let rearmed = await page.provider.consoleStart(webviewId: page.id, context: page.context)
        XCTAssertTrue(rearmed.hasPrefix("OK."), rearmed)
        XCTAssertEqual(content.userScripts.map(\.source), scripts, "Rearming must not duplicate or remove scripts")
        try await js("console.log('rearmed');", in: page.web)
        try await eventually {
            DefaultWebInspectProvider.consoleStore.read(webviewId: page.id, limit: 10, sinceSeq: nil)
                .contains { record in
                    record.line.contains("rearmed")
                }
        }
        unknown.removeFromSuperview()
    }

    func testActiveHighlightDoesNotRetainRemovedPage() async throws {
        var loadedPage: Page? = try await page()
        weak var weakWeb = loadedPage?.web
        weak var weakWindow = loadedPage?.window
        weak var weakController: WebInspectHighlight?
        weak var weakOverlay: WebInspectHighlightView?
        if let page = loadedPage {
            let result = await page.highlight()
            XCTAssertTrue(result.hasPrefix("OK."), result)
            weakController = WebInspectHighlight.existingController(for: page.web)
            weakOverlay = weakController?.overlay
            XCTAssertNotNil(weakOverlay)
            // Do not call stop/close: detaching the selected view must clean up.
            page.web.removeFromSuperview()
            try await eventually {
                weakController?.overlay == nil
            }
        }
        loadedPage = nil
        try await eventually {
            weakWeb == nil && weakWindow == nil && weakController == nil && weakOverlay == nil
        }
    }

    private static let html = #"""
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    body { margin: 0; height: 1800px; }
    #target { position: absolute; left: 20px; top: 300px; width: 100px; height: 40px; }
    iframe { position: absolute; left: 10px; top: 10px; width: 200px; height: 90px; }
    #open { position: absolute; top: 150px; left: 10px; }
    </style></head><body>
    <div id="target" data-fixture="main">Target</div>
    <iframe srcdoc="<body><button id='inside' data-fixture='iframe'>Inside</button></body>"></iframe>
    <div id="open"></div>
    <div id="closed"></div>
    <iframe sandbox srcdoc="<body>Opaque origin</body>" style="top:500px"></iframe>
    <script>
    document.getElementById('open').attachShadow({mode:'open'}).innerHTML = '<button id="shadow-button">Shadow</button>';
    document.getElementById('closed').attachShadow({mode:'closed'}).innerHTML = '<button>Closed</button>';
    </script></body></html>
    """#
}
#endif
