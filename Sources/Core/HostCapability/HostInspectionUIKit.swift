#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime

/// Ownership and scene resolution shared by runtime inspection, screenshots and hotfix.
/// This is an inspection boundary, not a sandbox for arbitrary host code.
@MainActor
public enum HostInspectionUIKit {
    private static var ownershipKey: UInt8 = 0
    private static let windowHandles = HostInspectionHandleRegistry<UIWindow>()

    /// Mark a custom SDK window, view, controller or other NSObject as AppAgent-owned.
    /// Views/controllers propagate ownership to descendants, including plain UIKit descendants.
    /// Mark a controller before embedding it; this does not load its view. No "mark host" override
    /// exists: a descendant cannot opt out of an SDK ancestor's ownership.
    public static func markAppAgentOwned(_ root: NSObject) {
        objc_setAssociatedObject(root, &ownershipKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Module membership and the entire superclass chain matter, not a class-name substring.
    /// BOUIKit and BODragScroll are shared dependencies and are NOT globally SDK-owned.
    public nonisolated static func isAppAgentClass(_ cls: AnyClass) -> Bool {
        if isKnownAppAgentClass(cls) { return true }
        var current: AnyClass? = cls
        while let candidate = current {
            // Keep these fallbacks for already-built framework binaries. Source-integrated
            // SDK types are recognized by the explicit marker above, so a host type whose
            // name merely contains "AppAgent" is never claimed.
            let names = [
                String(cString: class_getName(candidate)),
                String(reflecting: candidate)
            ]
            if names.contains(where: { $0.hasPrefix("AppAgent.") || $0.hasPrefix("AppAgentObjCSupport.") }) {
                return true
            }
            if let image = class_getImageName(candidate) {
                let path = String(cString: image)
                if path.contains("/AppAgent.framework/") || path.contains("/AppAgentObjCSupport.framework/") {
                    return true
                }
            }
            current = class_getSuperclass(candidate)
        }
        return false
    }

    /// Identity-only ownership check. This is deliberately separate from
    /// `isAppAgentClass`: module/image fallbacks are useful for a prebuilt framework,
    /// but cannot distinguish a source-integrated host type with a suggestive name.
    public nonisolated static func isKnownAppAgentClass(_ cls: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let candidate = current {
            if candidate is any AppAgentRuntimeOwned.Type { return true }
            current = class_getSuperclass(candidate)
        }
        return false
    }

    public static func isAppAgentOwned(_ object: NSObject) -> Bool {
        var visited = Set<ObjectIdentifier>()
        return owned(object, visited: &visited)
    }

    private static func owned(_ object: NSObject, visited: inout Set<ObjectIdentifier>) -> Bool {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
        if objc_getAssociatedObject(object, &ownershipKey) != nil { return true }
        if let cls = object_getClass(object), isAppAgentClass(cls) { return true }
        if let view = object as? UIView {
            // A controller's root may be a plain UIView, even when embedded in a host window.
            if let controller = view.next as? UIViewController, owned(controller, visited: &visited) { return true }
            if let parent = view.superview, owned(parent, visited: &visited) { return true }
            if let window = view as? UIWindow, let root = window.rootViewController,
               owned(root, visited: &visited) { return true }
        }
        if let controller = object as? UIViewController {
            if let parent = controller.parent, owned(parent, visited: &visited) { return true }
            if let presenter = controller.presentingViewController, owned(presenter, visited: &visited) { return true }
            if let root = controller.viewIfLoaded {
                if objc_getAssociatedObject(root, &ownershipKey) != nil || isAppAgentClass(type(of: root)) { return true }
                if let parent = root.superview, owned(parent, visited: &visited) { return true }
            }
        }
        return false
    }

    public static func includes(_ object: NSObject, context: HostInspectionContext = .init()) -> Bool {
        guard context.scope.includes(appAgentOwned: isAppAgentOwned(object)) else { return false }
        // Explicitly bound helpers may also be used on direct objects by the JS bridge.
        if let expected = context.sceneIdentifier {
            let actual: String?
            if let view = object as? UIView {
                actual = sceneIdentifier(for: view)
            } else if let controller = object as? UIViewController {
                actual = controller.viewIfLoaded.flatMap { sceneIdentifier(for: $0) }
            } else {
                return true // Non-UI objects have no UIKit scene identity.
            }
            guard actual == expected else { return false }
        }
        return true
    }

    public static func sceneIdentifier(for view: UIView) -> String? {
        (view as? UIWindow ?? view.window)?.windowScene?.session.persistentIdentifier
    }

    /// An explicit binding never falls back to another scene. Without one, exactly one
    /// foreground-active scene is required; inactive/background scenes are not candidates.
    public static func activeScene(context: HostInspectionContext = .init()) throws -> UIWindowScene {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let identifier = try selectSceneIdentifier(
            candidates: scenes.map { ($0.session.persistentIdentifier, $0.activationState == .foregroundActive) },
            requested: context.sceneIdentifier
        )
        guard let scene = scenes.first(where: { $0.session.persistentIdentifier == identifier }) else {
            throw UIKitInspectionError.sceneUnavailable
        }
        return scene
    }

    static func selectSceneIdentifier(candidates: [(id: String, active: Bool)], requested: String?) throws -> String {
        if let requested {
            guard candidates.contains(where: { $0.id == requested && $0.active }) else {
                throw UIKitInspectionError.sceneUnavailable
            }
            return requested
        }
        let active = candidates.filter(\.active)
        guard active.count == 1 else {
            throw active.isEmpty ? UIKitInspectionError.sceneUnavailable : UIKitInspectionError.ambiguousScene
        }
        return active[0].id
    }

    /// All windows of ONE scene. Register every window before scope filtering so handles never
    /// depend on the requested scope. A removed/deallocated window's handle is never recycled.
    static func sceneWindows(context: HostInspectionContext = .init()) throws -> [UIWindow] {
        let scene = try activeScene(context: context)
        // Register all connected scenes in deterministic order on first discovery.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { $0.session.persistentIdentifier < $1.session.persistentIdentifier }
        for item in scenes {
            for window in item.windows { _ = windowHandles.handle(for: window) }
        }
        return scene.windows.sorted {
            if $0.windowLevel != $1.windowLevel { return $0.windowLevel.rawValue < $1.windowLevel.rawValue }
            return windowHandles.handle(for: $0) < windowHandles.handle(for: $1)
        }
    }

    static func handle(for window: UIWindow) -> Int { windowHandles.handle(for: window) }

    static func window(handle: Int, context: HostInspectionContext = .init()) -> UIWindow? {
        guard let windows = try? sceneWindows(context: context),
              let window = windowHandles.object(for: handle),
              windows.contains(where: { $0 === window }) else { return nil }
        return window
    }

    static func defaultWindow(in windows: [UIWindow], context: HostInspectionContext) -> UIWindow? {
        let candidates = windows.map {
            WindowCandidate(appAgentOwned: isAppAgentOwned($0), visible: !$0.isHidden && $0.alpha > 0,
                            key: $0.isKeyWindow, normalLevel: $0.windowLevel == .normal)
        }
        guard let index = defaultWindowIndex(candidates: candidates, scope: context.scope),
              includes(windows[index], context: context) else { return nil }
        return windows[index]
    }

    struct WindowCandidate {
        let appAgentOwned: Bool
        let visible: Bool
        let key: Bool
        let normalLevel: Bool
    }

    static func defaultWindowIndex(candidates: [WindowCandidate], scope: HostInspectionScope) -> Int? {
        let eligible = candidates.indices.filter {
            candidates[$0].visible && scope.includes(appAgentOwned: candidates[$0].appAgentOwned)
        }
        return eligible.first(where: { candidates[$0].key })
            ?? eligible.first(where: { candidates[$0].normalLevel })
            ?? eligible.first
    }

    /// For SDK-only traversal, host ancestors are navigation scaffolding, never output.
    /// Host traversal prunes SDK roots immediately, before collecting text/stats.
    static func canTraverse(_ view: UIView, context: HostInspectionContext) -> Bool {
        context.scope == .appagent || includes(view, context: context)
    }

    static func inspectionRoots(in window: UIWindow, context: HostInspectionContext) -> [UIView] {
        func roots(_ view: UIView) -> [UIView] {
            if includes(view, context: context) { return [view] }
            guard context.scope == .appagent else { return [] }
            return view.subviews.flatMap(roots)
        }
        return roots(window)
    }

    /// Fail closed rather than draw an allowed ancestor containing excluded SDK pixels.
    /// Even hidden/offscreen descendants count: rendering callbacks/layout can reveal them.
    static func screenshotRejection(for view: UIView, context: HostInspectionContext) -> String? {
        guard includes(view, context: context) else { return "Inspection denied: screenshot target is outside scope." }
        if context.scope != .all {
            func containsExcluded(_ node: UIView) -> Bool {
                !includes(node, context: context) || node.subviews.contains(where: containsExcluded)
            }
            if containsExcluded(view) {
                return "Inspection denied: screenshot target contains out-of-scope views. Choose a scope-safe subtree."
            }
            // Backdrop effects can sample pixels outside the selected subtree.
            func containsBackdrop(_ node: UIView) -> Bool {
                node is UIVisualEffectView || node.subviews.contains(where: containsBackdrop)
            }
            if containsBackdrop(view) {
                return "Inspection denied: backdrop effects cannot be isolated in a limited-scope screenshot."
            }
        }
        return nil
    }
}

/// Generic only so lifetime/handle invariants can be tested without constructing UIWindow
/// (which is unsupported by the hostless Mac Catalyst XCTest runner).
@MainActor
final class HostInspectionHandleRegistry<Object: AnyObject>: AppAgentRuntimeOwned {
    private final class Entry: AppAgentRuntimeOwned {
        weak var object: Object?
        let handle: Int
        init(_ object: Object, handle: Int) { self.object = object; self.handle = handle }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextHandle = 0

    static var entryClass: AnyClass { Entry.self }

    func handle(for object: Object) -> Int {
        let key = ObjectIdentifier(object)
        if let entry = entries[key], entry.object === object { return entry.handle }
        entries = entries.filter { $0.value.object != nil }
        let entry = Entry(object, handle: nextHandle)
        nextHandle += 1
        entries[key] = entry
        return entry.handle
    }

    func object(for handle: Int) -> Object? {
        entries.values.first(where: { $0.handle == handle })?.object
    }
}

enum UIKitInspectionError: Error, LocalizedError {
    case sceneUnavailable, ambiguousScene, outsideScope, unsafeObjectChain

    var errorDescription: String? {
        switch self {
        case .sceneUnavailable: return "Inspection denied: the bound scene is unavailable/inactive, or no active scene exists."
        case .ambiguousScene: return "Inspection denied: multiple active scenes; bind the session to a scene."
        case .outsideScope: return "Inspection denied: target is outside the inspection scope."
        case .unsafeObjectChain: return "Inspection denied: unsafe object/collection traversal in a limited scope."
        }
    }
}
#endif
