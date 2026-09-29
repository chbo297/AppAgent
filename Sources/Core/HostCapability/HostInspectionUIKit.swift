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

    /// 归属只认窗口。AppAgent 的 UI 全部活在自己的窗口里（`AppAgentWindow`、调试用的
    /// `AppAgentRegionDebugWindow`，或任何被标记过的窗口），宿主窗口里的一切都归宿主。
    /// 三条规则顺序短路，宿主窗口内的视图只花一次 `view.window`，不再逐层爬类名：
    ///   1. 对象自己被显式标记 —— 宿主把某棵子树交还 SDK 时唯一的后门
    ///   2. 能定位到所在窗口 —— 窗口说了算
    ///   3. 定位不到窗口（游离子树、纯逻辑对象）—— 才回退到类判定 + 祖先传播
    public static func isAppAgentOwned(_ object: NSObject) -> Bool {
        isAppAgentOwned(object, hostingWindow: window(hosting: object))
    }

    private static func isAppAgentOwned(_ object: NSObject, hostingWindow: UIWindow?) -> Bool {
        if isExplicitlyMarked(object) { return true }
        if let hostingWindow { return isAppAgentWindow(hostingWindow) }
        var visited = Set<ObjectIdentifier>()
        return detachedOwner(object, visited: &visited)
    }

    /// 再开新窗口时，让窗口类 conform `AppAgentRuntimeOwned` 或建完调一次
    /// `markAppAgentOwned(window)`，整扇窗口就自动归 AppAgent。
    public static func isAppAgentWindow(_ window: UIWindow) -> Bool {
        if isExplicitlyMarked(window) { return true }
        if let cls: AnyClass = object_getClass(window), isAppAgentClass(cls) { return true }
        // 宿主拿普通 UIWindow 承载 AppAgent 面板时也算 AppAgent 的窗口：一次 root VC
        // 判定就够，代价是常数，换来 agent 不会反过来内省自己的面板。
        guard let root = window.rootViewController else { return false }
        if isExplicitlyMarked(root) { return true }
        guard let rootClass: AnyClass = object_getClass(root) else { return false }
        return isAppAgentClass(rootClass)
    }

    private static func isExplicitlyMarked(_ object: NSObject) -> Bool {
        objc_getAssociatedObject(object, &ownershipKey) != nil
    }

    /// 只读 `viewIfLoaded`：读 `view` 会强制加载并触发 `viewDidLoad`，内省不许有这种副作用。
    /// 未加载的子 VC 沿 parent / presenting 链往上找，所以懒加载的 tab 也能正确归属到宿主窗口。
    static func window(hosting object: NSObject) -> UIWindow? {
        if let window = object as? UIWindow { return window }
        if let view = object as? UIView { return view.window }
        guard var current = object as? UIViewController else { return nil }
        var visited = Set<ObjectIdentifier>()
        while visited.insert(ObjectIdentifier(current)).inserted {
            if let window = current.viewIfLoaded?.window { return window }
            guard let next = current.parent ?? current.presentingViewController else { return nil }
            current = next
        }
        return nil
    }

    /// 仅当对象不属于任何窗口时才走：类判定 + 祖先传播。游离的 SDK 子树（构造中、
    /// 已摘下、单测里的裸树）没有窗口可问，这里是它们唯一的归属来源。
    private static func detachedOwner(_ object: NSObject, visited: inout Set<ObjectIdentifier>) -> Bool {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
        if isExplicitlyMarked(object) { return true }
        if let cls = object_getClass(object), isAppAgentClass(cls) { return true }
        if let view = object as? UIView {
            // A controller's root may be a plain UIView, even when embedded in a host window.
            if let controller = view.next as? UIViewController,
               detachedOwner(controller, visited: &visited) { return true }
            if let parent = view.superview, detachedOwner(parent, visited: &visited) { return true }
            if let window = view as? UIWindow, let root = window.rootViewController,
               detachedOwner(root, visited: &visited) { return true }
        }
        if let controller = object as? UIViewController {
            if let parent = controller.parent, detachedOwner(parent, visited: &visited) { return true }
            if let presenter = controller.presentingViewController,
               detachedOwner(presenter, visited: &visited) { return true }
            if let root = controller.viewIfLoaded, let parent = root.superview,
               detachedOwner(parent, visited: &visited) { return true }
        }
        return false
    }

    public static func includes(_ object: NSObject, context: HostInspectionContext = .init()) -> Bool {
        // 窗口只解析一次：归属和场景身份共用同一个真相来源。
        let hostingWindow = window(hosting: object)
        guard context.scope.includes(
            appAgentOwned: isAppAgentOwned(object, hostingWindow: hostingWindow)
        ) else { return false }
        guard let expected = context.sceneIdentifier else { return true }
        // Non-UI objects have no UIKit scene identity.
        guard object is UIView || object is UIViewController else { return true }
        // 未加载 view 的子 VC 由 `window(hosting:)` 沿 parent 链解析。以前这里直接读
        // `viewIfLoaded` 拿 nil，懒加载的 tab 全被判成「不在本场景」——真机上
        // 3 个 tab 只报出当前那一个，模型据此认定 tab bar 是假皮肤，绕了一大圈。
        return hostingWindow?.windowScene?.session.persistentIdentifier == expected
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
