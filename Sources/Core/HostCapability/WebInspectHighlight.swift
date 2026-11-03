#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import ObjectiveC.runtime

/// Production always resolves an active scene. Tests can inject exactly one weak view root;
/// the injection is internal, requires an explicit binding, and still enforces ownership.
struct WebInspectEnvironment: Sendable {
    let roots: @MainActor @Sendable (HostInspectionContext) throws -> [UIView]

    static let live = WebInspectEnvironment { context in
        try HostInspectionUIKit.sceneWindows(context: context)
    }

    @MainActor
    static func testing(root: UIView, binding: String) -> WebInspectEnvironment {
        WebInspectEnvironment { [weak root] context in
            guard context.sceneIdentifier == binding, let root else {
                throw UIKitInspectionError.sceneUnavailable
            }
            return [root]
        }
    }

    @MainActor
    func root(for view: UIView, context: HostInspectionContext) -> UIView? {
        guard let candidates = try? roots(context) else {
            return nil
        }
        return candidates.first { candidate in
            view === candidate || view.isDescendant(of: candidate)
        }
    }

    @MainActor
    func includes(_ view: UIView, context: HostInspectionContext) -> Bool {
        guard root(for: view, context: context) != nil else {
            return false
        }
        // Root discovery already checked the scene binding.
        return HostInspectionUIKit.includes(view, context: .init(scope: context.scope))
    }
}

@MainActor
enum WebInspectVisibility {

    static func isVisible(_ view: UIView, context: HostInspectionContext, environment: WebInspectEnvironment = .live) -> Bool {
        guard let window = environment.root(for: view, context: context),
              environment.includes(view, context: context) else {
            return false
        }
        var rect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var opacity: CGFloat = 1
        var current: UIView? = view
        while let node = current {
            opacity *= node.alpha
            if node.isHidden || opacity <= 0.01 {
                return false
            }
            if node.clipsToBounds {
                rect = rect.intersection(node.convert(node.bounds, to: window))
            }
            current = node.superview
        }
        return !rect.isNull && rect.width > 1 && rect.height > 1
    }
}

/// A child above WKWebView's scroll view, never a window and never a DOM overlay.
/// Disabling interaction on the root excludes its entire subtree from hit testing.
@MainActor
final class WebInspectHighlightView: UIView, AppAgentRuntimeOwned {
    let outline = CAShapeLayer()
    var onDetach: (() -> Void)?
    private var wasInWindow = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        clipsToBounds = true
        outline.strokeColor = UIColor.red.cgColor
        outline.fillColor = UIColor.clear.cgColor
        outline.lineWidth = 2
        layer.addSublayer(outline)
        HostInspectionUIKit.markAppAgentOwned(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil && wasInWindow {
            onDetach?()
        }
        wasInWindow = window != nil
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil {
            onDetach?()
        }
    }

    func draw(rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = UIBezierPath(rect: rect).cgPath
        CATransaction.commit()
    }
}

/// One selection per WKWebView, shared across provider instances. The web view owns this
/// controller via association; all references back to the web view/window are weak.
@MainActor
final class WebInspectHighlight: NSObject, AppAgentRuntimeOwned {
    private static var associationKey: UInt8 = 0
    private weak var webView: WKWebView?
    private weak var selectedRoot: UIView?
    private var context = HostInspectionContext()
    private var environment = WebInspectEnvironment.live
    private var token: String?
    private var displayLink: CADisplayLink?
    private var observations: [NSKeyValueObservation] = []
    private var inFlight = false
    private var revision: UInt64 = 0
    private var pending: CheckedContinuation<String, Never>?
    private(set) var overlay: WebInspectHighlightView?
    var geometryDelivery: ((@escaping @MainActor () -> Void) -> Void)?

    private struct Geometry: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let path: String
    }

    private struct Viewport: Equatable {
        let bounds: CGRect
        let offset: CGPoint
        let zoom: CGFloat
        let inset: UIEdgeInsets

        @MainActor init(_ view: WKWebView) {
            bounds = view.bounds
            offset = view.scrollView.contentOffset
            zoom = view.scrollView.zoomScale
            inset = view.scrollView.adjustedContentInset
        }
    }

    @MainActor private final class TickTarget: NSObject {
        weak var owner: WebInspectHighlight?

        init(owner: WebInspectHighlight) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.refresh()
        }
    }

    static func existingController(for view: WKWebView) -> WebInspectHighlight? {
        objc_getAssociatedObject(view, &associationKey) as? WebInspectHighlight
    }

    static func controller(for view: WKWebView) -> WebInspectHighlight {
        if let existing = existingController(for: view) {
            return existing
        }
        let controller = WebInspectHighlight(view: view)
        objc_setAssociatedObject(view, &associationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    private init(view: WKWebView) {
        webView = view
        super.init()
    }

    func start(selector: String?, path: String?, context: HostInspectionContext,
               environment: WebInspectEnvironment, webviewId: String) async -> String {
        stop()
        self.environment = environment
        guard !Task.isCancelled, selector != nil || path != nil else {
            return "Inspection denied: highlight requires a selection and a live task."
        }
        let selectionToken = UUID().uuidString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending = continuation
                begin(selector: selector, path: path, context: context, token: selectionToken, webviewId: webviewId)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.token == selectionToken else {
                    return
                }
                self?.stop()
            }
        }
    }

    private func begin(selector: String?, path: String?, context: HostInspectionContext, token: String, webviewId: String) {
        guard !Task.isCancelled, let view = webView,
              WebInspectVisibility.isVisible(view, context: context, environment: environment), !view.isLoading else {
            stop()
            return
        }
        self.context = context
        self.token = token
        selectedRoot = environment.root(for: view, context: context)
        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    if view.isLoading {
                        self?.stop()
                    }
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            },
            view.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.invalidateGeometry()
                }
            },
            view.scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.invalidateGeometry()
                }
            }
        ]
        // Observe ancestor visibility as well: a hide/show between two display ticks must
        // invalidate the selection, not allow an old IPC response to revive it.
        var ancestor: UIView? = view
        while let node = ancestor {
            observations.append(node.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.visibilityChanged()
                }
            })
            observations.append(node.observe(\.alpha, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.visibilityChanged()
                }
            })
            observations.append(node.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.visibilityChanged()
                }
            })
            observations.append(node.observe(\.center, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.visibilityChanged()
                }
            })
            ancestor = node.superview
        }
        let overlay = WebInspectHighlightView()
        overlay.frame = view.bounds
        overlay.onDetach = { [weak self] in
            self?.stop()
        }
        self.overlay = overlay
        view.addSubview(overlay)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
        let link = CADisplayLink(target: TickTarget(owner: self), selector: #selector(TickTarget.tick(_:)))
        link.preferredFramesPerSecond = 15
        displayLink = link
        link.add(to: .main, forMode: .common)
        let call = "return A.selectHighlight(\(DefaultWebInspectProvider.jsString(token)), "
            + "\(DefaultWebInspectProvider.jsString(selector)), \(DefaultWebInspectProvider.jsString(path)));"
        sample(call: call, initialID: webviewId)
    }

    private func invalidateGeometry() {
        revision &+= 1
        overlay?.outline.path = nil
    }

    private func visibilityChanged() {
        if !isValid() {
            stop()
        } else {
            invalidateGeometry()
        }
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== (selectedRoot as? UIWindow)?.windowScene {
            return
        }
        stop()
    }

    private func isValid() -> Bool {
        guard token != nil, let view = webView, let selectedRoot,
              environment.root(for: view, context: context) === selectedRoot, !view.isLoading else {
            return false
        }
        return WebInspectVisibility.isVisible(view, context: context, environment: environment)
    }

    /// Poll only while selected; one outstanding IPC at a time. This also observes CSS animations,
    /// iframe scrolling, visualViewport changes and layout without installing page-world observers.
    func refresh() {
        guard isValid(), let token else {
            stop()
            return
        }
        guard !inFlight else {
            return
        }
        sample(call: "return A.highlightGeometry(\(DefaultWebInspectProvider.jsString(token)));")
    }

    private func sample(call: String, initialID: String? = nil) {
        guard let view = webView, let token else {
            stop()
            return
        }
        inFlight = true
        let viewport = Viewport(view)
        let revision = self.revision
        let script = DefaultWebInspectProvider.highlightScript(call)
        view.evaluateJavaScript(script, in: nil, in: DefaultWebInspectProvider.inspectionWorld) { [weak self] result in
            let text: String
            switch result {
            case .success(let value):
                text = value as? String ?? "JS error: invalid highlight geometry."
            case .failure(let error):
                text = "JS error: \(error.localizedDescription)"
            }
            let deliver: @MainActor () -> Void = { [weak self] in
                self?.receive(text, token: token, revision: revision, viewport: viewport, initialID: initialID)
            }
            if let delivery = self?.geometryDelivery {
                delivery(deliver)
            } else {
                deliver()
            }
        }
    }

    private func receive(_ text: String, token: String, revision: UInt64, viewport: Viewport, initialID: String?) {
        guard self.token == token else {
            return
        }
        inFlight = false
        guard isValid(), let view = webView else {
            stop()
            return
        }
        guard let data = text.data(using: .utf8),
              let geometry = try? JSONDecoder().decode(Geometry.self, from: data),
              [geometry.x, geometry.y, geometry.width, geometry.height].allSatisfy({ value in
                  value.isFinite
              }), geometry.width > 0, geometry.height > 0 else {
            stop(reason: text.hasPrefix("JS error:") ? text : "JS error: invalid highlight geometry.")
            return
        }
        // A native scroll/zoom/layout happened after this sample was requested. Do not paint it.
        guard self.revision == revision, Viewport(view) == viewport else {
            invalidateGeometry()
            return
        }
        let overlay = self.overlay ?? WebInspectHighlightView()
        overlay.onDetach = { [weak self] in
            self?.stop()
        }
        overlay.frame = view.bounds
        if overlay.superview !== view {
            view.addSubview(overlay)
        }
        view.bringSubviewToFront(overlay)
        self.overlay = overlay
        let inset = viewport.inset
        let width = viewport.bounds.width - inset.left - inset.right
        let rect = CGRect(x: inset.left + CGFloat(geometry.x) * width,
                          y: inset.top + CGFloat(geometry.y) * width,
                          width: CGFloat(geometry.width) * width, height: CGFloat(geometry.height) * width)
        overlay.draw(rect: rect)
        if let pending {
            self.pending = nil
            let id = initialID ?? DefaultWebInspectProvider.identity(for: view)
            pending.resume(returning: "OK. highlight webviewId=\(id) path=\(geometry.path); native touch-transparent outline.")
        }
    }

    func stop(reason: String = "Inspection denied: highlight cancelled or target no longer visible.",
              clearPageSelection: Bool = true) {
        let oldToken = token
        token = nil
        revision &+= 1
        inFlight = false
        displayLink?.invalidate()
        displayLink = nil
        observations.removeAll()
        NotificationCenter.default.removeObserver(self)
        overlay?.onDetach = nil
        overlay?.removeFromSuperview()
        overlay = nil
        selectedRoot = nil
        let continuation = pending
        pending = nil
        continuation?.resume(returning: reason)
        if clearPageSelection, let oldToken, let view = webView {
            let tokenJS = DefaultWebInspectProvider.jsString(oldToken)
            let cleanup = """
                (function () {
                    var state = window.__appagentHighlight;
                    if (state && state.token === \(tokenJS)) {
                        delete window.__appagentHighlight;
                    }
                })()
                """
            view.evaluateJavaScript(cleanup, in: nil, in: DefaultWebInspectProvider.inspectionWorld) { _ in
            }
        }
    }
}
#endif
