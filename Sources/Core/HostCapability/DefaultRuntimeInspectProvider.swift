//
//  DefaultRuntimeInspectProvider.swift
//  AppAgent — 宿主能力层
//
//  基于 ObjC runtime + KVC + UIKit 的通用 RuntimeInspectProvider 默认实现。
//  任意 UIKit 宿主 app 都可直接注册使用，无需自行实现内省逻辑。
//  能力较强（可读类/方法/属性、KVC 读写、反射调用），默认关闭，
//  由宿主显式注册 RuntimeInspectTool 时才生效。
//

#if canImport(UIKit)
import Foundation
import UIKit
import ObjectiveC.runtime

/// 无实例存储属性：唯一类型级存储是不可变的 `chromePrefixes`，所有摸 UIKit 的入口都在
/// `MainActor.run` / `@MainActor` 里执行。所以这里是真 `Sendable`，不需要 `@unchecked` 豁免；
/// 以后要加实例可变状态，先决定谁来串行化，别把标注放宽回去。
public final class DefaultRuntimeInspectProvider: RuntimeInspectProvider, Sendable {

    public init() {}

    // MARK: - UI Hierarchy

    public func uiHierarchy(context: HostInspectionContext) async -> String {
        await MainActor.run {
            do {
                let windows = try HostInspectionUIKit.sceneWindows(context: context)
                var out = ""
                for window in windows {
                    for root in HostInspectionUIKit.inspectionRoots(in: window, context: context) {
                        guard let path = Self.addressablePath(of: root, context: context) else { continue }
                        out += "[\(path)] \(type(of: root)) frame=\(root.frame)\n"
                        Self.describeAddressable(view: root, path: path, depth: 0, maxDepth: 100,
                                                 context: context, into: &out)
                    }
                    if let controller = window.rootViewController {
                        Self.describe(viewController: controller, indent: 1, context: context, into: &out)
                    }
                }
                return out.isEmpty ? "(no windows)" : out
            } catch {
                return error.localizedDescription
            }
        }
    }

    // MARK: - Class list

    public func classList(matching filter: String?, context: HostInspectionContext) async -> [String] {
        let names = Self.withRuntimeClasses { classes in
            Self.scopedClassCandidates(in: classes, matching: { name in
                guard let filter, !filter.isEmpty else { return true }
                return name.range(of: filter, options: .caseInsensitive) != nil
            }, context: context)?.map(\.name).sorted() ?? []
        }
        return Task.isCancelled ? [] : names
    }

    // MARK: - Methods

    public func methodList(ofClass className: String, context: HostInspectionContext) async -> [String] {
        guard let cls = Self.resolveClass(className, context: context),
              Self.classIncluded(cls, context: context) else {
            return ["(class not found or outside inspection scope: \(className))"]
        }
        var result: [String] = []
        result.append(contentsOf: Self.methods(of: cls, isClassMethod: false))
        if let meta: AnyClass = object_getClass(cls) {
            result.append(contentsOf: Self.methods(of: meta, isClassMethod: true))
        }
        return result.isEmpty ? ["(no methods)"] : result
    }

    // MARK: - Properties / ivars

    public func propertyList(ofClass className: String, context: HostInspectionContext) async -> [String] {
        guard let cls = Self.resolveClass(className, context: context),
              Self.classIncluded(cls, context: context) else {
            return ["(class not found or outside inspection scope: \(className))"]
        }
        var out: [String] = []
        var pCount: UInt32 = 0
        if let props = class_copyPropertyList(cls, &pCount) {
            for i in 0..<Int(pCount) {
                let name = String(cString: property_getName(props[i]))
                let attrs = property_getAttributes(props[i]).map { String(cString: $0) } ?? ""
                out.append("@property \(name)  \(attrs)")
            }
            free(props)
        }
        var iCount: UInt32 = 0
        if let ivars = class_copyIvarList(cls, &iCount) {
            for i in 0..<Int(iCount) {
                if let namePtr = ivar_getName(ivars[i]) {
                    let name = String(cString: namePtr)
                    let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? ""
                    out.append("ivar \(name)  \(type)")
                }
            }
            free(ivars)
        }
        return out.isEmpty ? ["(no properties/ivars)"] : out
    }

    // MARK: - KVC read

    public func propertyValue(keyPath: String, ofClass className: String?, context: HostInspectionContext) async -> String? {
        await MainActor.run {
            guard let target = Self.kvcTarget(className: className, context: context) as? NSObject else {
                return "(no target object for KVC; className=\(className ?? "top page"))"
            }
            return Self.readProperty(from: target, keyPath: keyPath, context: context)
        }
    }

    // MARK: - KVC write

    public func setPropertyValue(keyPath: String, value: String, ofClass className: String?, context: HostInspectionContext) async -> String {
        await MainActor.run {
            guard let target = Self.kvcTarget(className: className, context: context) as? NSObject else {
                return "(no target object for KVC; className=\(className ?? "top page"))"
            }
            let before = Self.pageFingerprint(context: context)
            let result = Self.writeProperty(on: target, keyPath: keyPath, value: value, context: context)
            guard result.hasPrefix("OK.") else { return result }
            return result + Self.pageChangeNote(from: before, context: context)
        }
    }

    // MARK: - Reflection invoke

    public func invoke(className: String, selector: String, argumentsJSON: String, context: HostInspectionContext) async -> String {
        await MainActor.run {
            guard let cls = Self.resolveClass(className, context: context) else {
                return "(class not found: \(className))"
            }
            let sel = NSSelectorFromString(selector)
            // 优先对栈顶页面（若为该类实例）调用实例方法；否则当作类方法调用。
            let target: NSObject?
            if let top = Self.kvcTarget(className: className, context: context) as? NSObject, top.responds(to: sel) {
                target = top
            } else if context.scope == .all, let clsObj = cls as AnyObject as? NSObject, clsObj.responds(to: sel) {
                target = clsObj
            } else {
                return "(selector \(selector) not found on \(className) instance/class)"
            }
            guard let obj = target else { return "(no target)" }
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [Any] ?? []
            if let rejection = Self.selectorRejection(sel, on: obj, argCount: args.count, context: context) { return rejection }
            do {
                let result = try ObjCExceptionCatcher.performReturning {
                    Self.performSelector(sel, on: obj, args: args, context: context)
                }
                guard let result else { return "(void/nil)" }
                return try Self.inspectedDescription(of: result, context: context)
            } catch let error as UIKitInspectionError {
                return error.localizedDescription
            } catch {
                // NSException.reason can embed an excluded object's description.
                return "Invoke failed: Objective-C invocation failed."
            }
        }
    }

    // MARK: - 按路径寻址视图

    public func viewTree(maxDepth: Int, context: HostInspectionContext) async -> String {
        await MainActor.run {
            guard let window = Self.keyWindow(context: context) else { return "(no key window)" }
            var out = "路径 root = scoped default window；子视图路径保留实际 subviews 下标\n"
            Self.describeAddressable(view: window, path: "root", depth: 0, maxDepth: maxDepth, context: context, into: &out)
            return out
        }
    }

    public func viewInfo(path: String, context: HostInspectionContext) async -> String {
        await MainActor.run {
            guard let view = Self.view(atPath: path, context: context) else { return "(no view at path '\(path)')" }
            return Self.describeState(of: view, path: path, context: context)
        }
    }

    public func setViewValue(path: String, key: String, value: String, context: HostInspectionContext) async -> String {
        await MainActor.run {
            guard let view = Self.view(atPath: path, context: context) else { return "(no view at path '\(path)')" }
            let before = Self.pageFingerprint(context: context)
            let result = Self.applyValue(to: view, key: key, value: value, context: context)
            guard result.hasPrefix("OK.") else { return result }
            return result + Self.pageChangeNote(from: before, context: context)
        }
    }

    public func invokeOnView(path: String, selector: String, argumentsJSON: String, context: HostInspectionContext) async -> String {
        await MainActor.run {
            guard let view = Self.view(atPath: path, context: context) else { return "(no view at path '\(path)')" }
            let sel = NSSelectorFromString(selector)
            guard view.responds(to: sel) else {
                return "(selector \(selector) not found on \(type(of: view)))"
            }
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [Any] ?? []
            if let rejection = Self.selectorRejection(sel, on: view, argCount: args.count, context: context) { return rejection }
            do {
                let result = try ObjCExceptionCatcher.performReturning {
                    Self.performSelector(sel, on: view, args: args, context: context)
                }
                guard let result else { return "(void/nil)" }
                return try Self.inspectedDescription(of: result, context: context)
            } catch let error as UIKitInspectionError {
                return error.localizedDescription
            } catch {
                // Keep exception details out of the model-visible inspection channel.
                return "Invoke failed: Objective-C invocation failed."
            }
        }
    }

    // MARK: - 模拟用户操作（语义级）

    public func activateView(path: String, event: String?, context: HostInspectionContext) async -> String {
        await MainActor.run { Self.activate(path: path, event: event, context: context) }
    }

    public func navigatePage(target: String, context: HostInspectionContext) async -> String {
        await MainActor.run { Self.navigate(target: target, context: context) }
    }

    public func scrollPage(path: String?, direction: String, amount: Double?, context: HostInspectionContext) async -> String {
        await MainActor.run { Self.scroll(path: path, direction: direction, amount: amount, context: context) }
    }

    /// 只做「按 path 找到视图 + 查方法签名 + 对作用域白名单」，一行运行时状态都不改 ——
    /// `selectorRejection` 本来就是这三件事，这里只是把它提到授权之前调一次。
    ///
    /// 只覆盖 `view_invoke`（真机那次浪费掉的 4 次调用全是它）。类方法版 `invoke` 的目标解析
    /// 牵涉元类与单例，判定条件不止签名，留给执行阶段报准确的错。
    public func invocationRejection(path: String?, className: String?, selector: String,
                                    argumentCount: Int, context: HostInspectionContext) async -> String? {
        guard let path, !path.isEmpty, className == nil else { return nil }
        return await MainActor.run {
            // 找不到视图就不在这里下结论：让执行阶段去报 "(no view at path …)"，
            // 免得前置校验把「路径写错」和「选择器不让调」两种错误混成一种。
            guard let view = Self.view(atPath: path, context: context) else { return nil }
            let sel = NSSelectorFromString(selector)
            guard view.responds(to: sel) else {
                return "(selector \(selector) not found on \(type(of: view)))"
            }
            return Self.selectorRejection(sel, on: view, argCount: argumentCount, context: context)
        }
    }

    // MARK: - 分层摘要：先给地图，细节按需二次调用

    public func uiHierarchySummary(context: HostInspectionContext) async -> String {
        await MainActor.run { Self.hierarchySummary(context: context) }
    }

    public func viewSubtree(path: String, maxDepth: Int, context: HostInspectionContext) async -> String {
        await MainActor.run {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "root" {
                guard let window = Self.keyWindow(context: context) else { return "(no windows)" }
                var out = "路径根 = scoped default window；子视图路径保留实际 subviews 下标\n"
                Self.describeAddressable(view: window, path: "root", depth: 0, maxDepth: maxDepth, context: context, into: &out)
                return out
            }
            guard let view = Self.view(atPath: trimmed, context: context) else { return "(no view at path '\(trimmed)')" }
            var out = "从 [\(trimmed)] 展开，maxDepth=\(maxDepth)\n"
            Self.describeAddressable(view: view, path: trimmed, depth: 0, maxDepth: maxDepth, context: context, into: &out)
            return out
        }
    }

    // MARK: - Helpers

    /// 页面指纹：判断一次操作到底有没有产生用户看得见的页面变化。
    /// 只取「栈顶 VC + 容器位置 + 标题」——足够区分换页，又不必全树遍历。
    struct PageFingerprint: Equatable, Sendable {
        var topController: String
        var containers: [String]
        var title: String?
    }

    /// 沿「当前可见」的容器链收集 VC：present > tab 选中项 > nav 栈顶 > 最后一个 child。
    /// 页面指纹和容器导航共用它，避免两处各写一份「谁是当前页」的判断。
    @MainActor
    static func visibleControllerChain(context: HostInspectionContext = .init()) -> [UIViewController] {
        var chain: [UIViewController] = []
        var node = keyWindow(context: context)?.rootViewController
        var visited = Set<ObjectIdentifier>()
        while let current = node, visited.insert(ObjectIdentifier(current)).inserted {
            guard HostInspectionUIKit.includes(current, context: context) else { break }
            chain.append(current)
            if let presented = current.presentedViewController {
                node = presented
            } else if let tab = current as? UITabBarController {
                node = tab.selectedViewController
            } else if let nav = current as? UINavigationController {
                node = nav.topViewController
            } else {
                node = current.children.last
            }
        }
        return chain
    }

    @MainActor
    static func pageFingerprint(context: HostInspectionContext = .init()) -> PageFingerprint {
        let chain = visibleControllerChain(context: context)
        var containers: [String] = []
        for controller in chain {
            if let tab = controller as? UITabBarController {
                containers.append("tab \(tab.selectedIndex)")
            } else if let nav = controller as? UINavigationController {
                containers.append("nav 深度 \(nav.viewControllers.count)")
            } else if controller.presentedViewController != nil {
                containers.append("present")
            }
        }
        let top = chain.last
        return PageFingerprint(
            topController: top.map { "\(type(of: $0))" } ?? "(none)",
            containers: containers,
            title: top?.title ?? top?.tabBarItem?.title
        )
    }

    /// 把「属性改了」和「页面真的动了」分开说清楚。一次没生效的修改如果只回 `OK.`，
    /// 模型会当成功，然后得再花一轮 ui_hierarchy 才发现白改了——真机上那一轮 32 秒。
    @MainActor
    static func pageChangeNote(from before: PageFingerprint, context: HostInspectionContext = .init()) -> String {
        let after = pageFingerprint(context: context)
        guard after != before else { return " · 页面未变化（仍 \(describePage(before))）" }
        return " · 页面已变化：\(describePage(before)) → \(describePage(after))"
    }

    static func describePage(_ fingerprint: PageFingerprint) -> String {
        var parts = [fingerprint.topController]
        if !fingerprint.containers.isEmpty { parts.append(fingerprint.containers.joined(separator: " / ")) }
        if let title = fingerprint.title, !title.isEmpty { parts.append("\"\(clip(title))\"") }
        return parts.joined(separator: " ")
    }

    // MARK: 语义级激活

    /// 按「越接近用户真实点击」的顺序降级，并如实报告走了哪条路径。
    /// 真正的触摸注入要自己构造 UITouch / IOHID 事件（私有 API），这里不做：
    /// 做不到的情况直接报错，绝不返回一个让模型以为点过了的 `OK.`。
    @MainActor
    static func activate(path: String, event: String?, context: HostInspectionContext) -> String {
        guard let hit = view(atPath: path, context: context) else { return "(no view at path '\(path)')" }
        guard let controlEvent = controlEvent(named: event) else {
            return "(unknown event '\(event ?? "")'; use touchUpInside / touchDown / touchUpOutside "
                + "/ valueChanged / primaryActionTriggered)"
        }
        let before = pageFingerprint(context: context)
        // 1) 最近的 UIControl 祖先。点中的往往是 label / icon 这种叶子，用户真正点的是它的按钮祖先。
        if let found = nearestControl(from: hit, context: context) {
            guard found.control.isEnabled else {
                return "(control \(type(of: found.control)) at '\(path)' is disabled)"
            }
            found.control.sendActions(for: controlEvent)
            return "OK. 已激活 \(location(path: path, hops: found.hops, object: found.control)) "
                + "via sendActions(\(eventName(controlEvent)))"
                + pageChangeNote(from: before, context: context)
        }
        // 2) 无障碍激活：自定义控件只要实现了 accessibilityActivate，就会走它本该走的分支。
        //    指定了具体 control 事件时不降级到这里——语义不一样，不能悄悄换。
        if event == nil, let activated = accessibilityActivated(from: hit, context: context) {
            return "OK. 已激活 \(location(path: path, hops: activated.hops, object: activated.view)) "
                + "via accessibilityActivate()"
                + pageChangeNote(from: before, context: context)
        }
        return "(no activatable target at or above '\(path)': 没有 UIControl 祖先，accessibilityActivate() 也不接受。"
            + "只挂手势识别器的视图无法可靠触发——页面跳转请用 page_navigate，其它状态改动用 view_set / property_set)"
    }

    @MainActor
    private static func nearestControl(
        from view: UIView, context: HostInspectionContext
    ) -> (control: UIControl, hops: Int)? {
        var node: UIView? = view
        var hops = 0
        // 6 层足够从图标/文字走到按钮，再往上就容易误伤整个 cell 或容器了。
        while let current = node, hops <= 6 {
            if let control = current as? UIControl, HostInspectionUIKit.includes(control, context: context) {
                return (control, hops)
            }
            node = current.superview
            hops += 1
        }
        return nil
    }

    @MainActor
    private static func accessibilityActivated(
        from view: UIView, context: HostInspectionContext
    ) -> (view: UIView, hops: Int)? {
        var node: UIView? = view
        var hops = 0
        while let current = node, hops <= 6 {
            if HostInspectionUIKit.includes(current, context: context), current.accessibilityActivate() {
                return (current, hops)
            }
            node = current.superview
            hops += 1
        }
        return nil
    }

    @MainActor
    private static func location(path: String, hops: Int, object: NSObject) -> String {
        hops == 0 ? "[\(path)] \(type(of: object))" : "[\(path)] 往上第 \(hops) 层的 \(type(of: object))"
    }

    static func controlEvent(named name: String?) -> UIControl.Event? {
        guard let name, !name.isEmpty else { return .touchUpInside }
        switch name {
        case "touchUpInside": return .touchUpInside
        case "touchDown": return .touchDown
        case "touchUpOutside": return .touchUpOutside
        case "valueChanged": return .valueChanged
        case "primaryActionTriggered": return .primaryActionTriggered
        default: return nil
        }
    }

    static func eventName(_ event: UIControl.Event) -> String {
        switch event {
        case .touchDown: return "touchDown"
        case .touchUpOutside: return "touchUpOutside"
        case .valueChanged: return "valueChanged"
        case .primaryActionTriggered: return "primaryActionTriggered"
        default: return "touchUpInside"
        }
    }

    // MARK: 容器级导航

    /// 走容器 VC 的公开入口，并让 delegate 回调照常发生 —— 宿主监听 tab 切换做的事
    /// （埋点、灰度、未登录拦截）不能因为「这次是 agent 点的」就被跳过。
    @MainActor
    static func navigate(target: String, context: HostInspectionContext) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let key = trimmed.lowercased()
        let before = pageFingerprint(context: context)
        let chain = visibleControllerChain(context: context)
        if key.hasPrefix("tab:") {
            return selectTab(
                key: String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces),
                in: chain, before: before, context: context
            )
        }
        switch key {
        case "pop", "poptoroot":
            guard let nav = chain.compactMap({ $0 as? UINavigationController }).last else {
                return "(no UINavigationController in the scoped window)"
            }
            let popped = key == "poptoroot"
                ? nav.popToRootViewController(animated: true)
                : nav.popViewController(animated: true).map { [$0] }
            guard let popped, !popped.isEmpty else { return "(already at the root of the navigation stack)" }
            // 出栈/关闭是带动画的，此刻界面还在过渡，拿指纹下结论会得到假的「未变化」。
            return "OK. 已出栈 \(popped.count) 层（起点 \(describePage(before))；"
                + "动画进行中，要确认结果就再调一次 ui_hierarchy）"
        case "dismiss":
            guard let presenter = chain.last(where: { $0.presentedViewController != nil }) else {
                return "(nothing is presented modally)"
            }
            presenter.dismiss(animated: true)
            return "OK. 已关闭模态页（动画进行中，要确认结果就再调一次 ui_hierarchy）"
        default:
            return "(unknown target '\(target)'; use tab:<索引或标题> / pop / popToRoot / dismiss)"
        }
    }

    /// 索引和标题都收：用户说的是「profile」，模型不该被迫自己猜索引。
    @MainActor
    private static func selectTab(
        key: String, in chain: [UIViewController], before: PageFingerprint, context: HostInspectionContext
    ) -> String {
        guard let tab = chain.compactMap({ $0 as? UITabBarController }).last else {
            return "(no UITabBarController in the scoped window)"
        }
        let children = tab.viewControllers ?? []
        guard !children.isEmpty else { return "(the tab bar controller has no view controllers)" }
        let index: Int
        if let parsed = Int(key), children.indices.contains(parsed) {
            index = parsed
        } else if let matched = children.firstIndex(where: {
            let title = $0.tabBarItem?.title ?? $0.title ?? ""
            return !title.isEmpty
                && title.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            index = matched
        } else {
            let list = children.enumerated()
                .map { "\($0.offset)=\"\($0.element.tabBarItem?.title ?? $0.element.title ?? "(无标题)")\"" }
                .joined(separator: ", ")
            return "(no tab matches '\(key)'; available: \(list))"
        }
        guard HostInspectionUIKit.includes(children[index], context: context) else {
            return "(tab \(index) is outside the current inspection scope)"
        }
        guard index != tab.selectedIndex else {
            return "OK. 已经在 tab \(index)，未做改动 · \(describePage(before))"
        }
        // 先问 delegate。跳过这一步就不是「模拟用户点击」而是绕开宿主自己的规则了。
        if let delegate = tab.delegate,
           delegate.tabBarController?(tab, shouldSelect: children[index]) == false {
            return "(the host's UITabBarControllerDelegate refused to select tab \(index))"
        }
        tab.selectedIndex = index
        // 程序化改 selectedIndex 时 UIKit 不会发 didSelect，用户点击时会——补上才算等价。
        tab.delegate?.tabBarController?(tab, didSelect: children[index])
        return "OK. 已切到 tab \(index)" + pageChangeNote(from: before, context: context)
    }

    // MARK: 滚动

    /// scrollView 直接改 contentOffset —— 比伪造手势确定得多，而且 UIKit 会照常发
    /// scrollViewDidScroll。没有 scrollView 的容器交给无障碍滚动。翻页单位是「屏」。
    @MainActor
    static func scroll(path: String?, direction: String, amount: Double?, context: HostInspectionContext) -> String {
        let screens = amount ?? 1
        guard screens > 0 else { return "(amount must be greater than 0)" }
        let start: UIView
        if let path, !path.isEmpty, path != "root" {
            guard let found = view(atPath: path, context: context) else { return "(no view at path '\(path)')" }
            start = found
        } else {
            guard let window = keyWindow(context: context) else { return "(no key window)" }
            start = window
        }
        guard let scrollView = nearestScrollView(from: start, context: context) else {
            guard let axis = accessibilityScrollDirection(direction) else {
                return "(unknown direction '\(direction)'; use up / down / left / right)"
            }
            guard start.accessibilityScroll(axis) else {
                return "(nothing scrollable at or under the given path, and accessibilityScroll() was refused)"
            }
            return "OK. 已按无障碍滚动翻一页（\(direction)）"
        }
        let size = scrollView.bounds.size
        let content = scrollView.contentSize
        let inset = scrollView.adjustedContentInset
        var offset = scrollView.contentOffset
        switch direction.lowercased() {
        case "down": offset.y += size.height * CGFloat(screens)
        case "up": offset.y -= size.height * CGFloat(screens)
        case "right": offset.x += size.width * CGFloat(screens)
        case "left": offset.x -= size.width * CGFloat(screens)
        default: return "(unknown direction '\(direction)'; use up / down / left / right)"
        }
        offset.y = min(max(offset.y, -inset.top), max(-inset.top, content.height + inset.bottom - size.height))
        offset.x = min(max(offset.x, -inset.left), max(-inset.left, content.width + inset.right - size.width))
        let previous = scrollView.contentOffset
        guard offset != previous else { return "OK. 已经到 \(direction) 方向的尽头，未做改动" }
        scrollView.setContentOffset(offset, animated: true)
        return "OK. \(type(of: scrollView)) 往 \(direction) 滚 \(screens) 屏："
            + "contentOffset (\(Int(previous.x)), \(Int(previous.y))) → (\(Int(offset.x)), \(Int(offset.y)))"
    }

    /// 先往上找（path 指进了某个 scrollView 内部），再往下找（path 给的是窗口或容器，
    /// 能滚的那个在子树里）。往下只认「内容确实超出可视区」的，否则会选中一堆不能滚的壳。
    @MainActor
    private static func nearestScrollView(from view: UIView, context: HostInspectionContext) -> UIScrollView? {
        var node: UIView? = view
        while let current = node {
            if let scrollView = current as? UIScrollView,
               HostInspectionUIKit.includes(scrollView, context: context) { return scrollView }
            node = current.superview
        }
        var queue = [view]
        var index = 0
        while index < queue.count, index < 4096 {
            let current = queue[index]
            index += 1
            guard HostInspectionUIKit.canTraverse(current, context: context) else { continue }
            if let scrollView = current as? UIScrollView,
               HostInspectionUIKit.includes(scrollView, context: context),
               scrollView.contentSize.height > scrollView.bounds.height + 1
                   || scrollView.contentSize.width > scrollView.bounds.width + 1 {
                return scrollView
            }
            queue.append(contentsOf: current.subviews)
        }
        return nil
    }

    static func accessibilityScrollDirection(_ direction: String) -> UIAccessibilityScrollDirection? {
        switch direction.lowercased() {
        case "down": return .down
        case "up": return .up
        case "left": return .left
        case "right": return .right
        default: return nil
        }
    }

    @MainActor
    static func keyWindow(context: HostInspectionContext = .init()) -> UIWindow? {
        guard let windows = try? HostInspectionUIKit.sceneWindows(context: context) else { return nil }
        return HostInspectionUIKit.defaultWindow(in: windows, context: context)
    }

    /// Only in-scope windows in the selected scene. Array indices are NOT W<n> handles.
    @MainActor
    static func allWindows(context: HostInspectionContext = .init()) -> [UIWindow] {
        (try? HostInspectionUIKit.sceneWindows(context: context))?
            .filter { HostInspectionUIKit.includes($0, context: context) } ?? []
    }

    static func classIncluded(_ cls: AnyClass, context: HostInspectionContext = .init()) -> Bool {
        // An authorized all-scope query does not need to initialize class metadata for ownership.
        if context.scope == .all { return true }
        return context.scope.includes(appAgentOwned: HostInspectionUIKit.isAppAgentClass(cls))
    }

    /// Keep the ObjC snapshot local; never cache negative lookups or ownership across calls.
    private static func withRuntimeClasses<Result>(
        _ body: (UnsafeBufferPointer<AnyClass>) -> Result
    ) -> Result {
        guard !Task.isCancelled else { return body(UnsafeBufferPointer(start: nil, count: 0)) }
        let count = objc_getClassList(nil, 0)
        guard count > 0, !Task.isCancelled else { return body(UnsafeBufferPointer(start: nil, count: 0)) }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let realCount = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buffer), count)
        return body(UnsafeBufferPointer(start: buffer, count: min(Int(realCount), Int(count))))
    }

    /// Name matching is ONLY a cheap candidate filter, never an ownership decision.
    /// class_getName reads ObjC metadata without messaging the class. NSStringFromClass and
    /// Swift protocol casts can initialize unrelated classes (including CoreData internals),
    /// so ownership/superclass checks must run only after this filter, even for denied results.
    /// The injected check lets tests count candidates without timing the whole process.
    /// nil means cancellation: do not return partial lists or resolve a partly scanned short name.
    static func scopedClassCandidates<Classes: Sequence>(
        in classes: Classes,
        matching matchesName: (String) -> Bool,
        context: HostInspectionContext,
        scopeCheck: (AnyClass, HostInspectionContext) -> Bool = { classIncluded($0, context: $1) }
    ) -> [(cls: AnyClass, name: String)]? where Classes.Element == AnyClass {
        guard !Task.isCancelled else { return nil }
        var candidates: [(cls: AnyClass, name: String)] = []
        for cls in classes {
            guard !Task.isCancelled else { return nil }
            let name = String(cString: class_getName(cls))
            guard matchesName(name) else { continue }
            guard !Task.isCancelled else { return nil }
            // objc_getClassList writes raw ObjC class pointers into the buffer; it does not
            // bridge each entry to Swift's canonical metatype (ObjC-only classes need a wrapper).
            // Normalize ONLY matching names, before protocol casts/identity checks and returning.
            // A vanished candidate must fail the scan, not make an ambiguous short name unique.
            guard let candidate: AnyClass = objc_lookUpClass(name), !Task.isCancelled else { return nil }
            if scopeCheck(candidate, context) { candidates.append((candidate, name)) }
        }
        return Task.isCancelled ? nil : candidates
    }

    /// Resolve a class by name, tolerating Swift's module-qualified runtime names.
    ///
    /// `objc_lookUpClass("HostTabBarController")` fails for Swift classes because
    /// their Objective-C name is `"<Module>.HostTabBarController"`. The agent only
    /// ever knows the short name, so fall back to scanning the class list for a
    /// unique `*.name` match.
    static func resolveClass(_ name: String, context: HostInspectionContext = .init()) -> AnyClass? {
        guard !name.isEmpty, !Task.isCancelled else { return nil }
        // Unlike Foundation name conversion, lookup does not send +class / initialize the class.
        if let cls = objc_lookUpClass(name) {
            guard !Task.isCancelled, classIncluded(cls, context: context), !Task.isCancelled else { return nil }
            return cls
        }
        let suffix = "." + name
        return withRuntimeClasses { classes in
            guard let candidates = scopedClassCandidates(
                in: classes, matching: { $0.hasSuffix(suffix) }, context: context
            ), candidates.count == 1, !Task.isCancelled else { return nil }
            // Ambiguous in-scope short names still fail closed.
            return candidates[0].cls
        }
    }

    @MainActor
    static func topViewController(context: HostInspectionContext = .init()) -> UIViewController? {
        guard var vc = keyWindow(context: context)?.rootViewController,
              HostInspectionUIKit.includes(vc, context: context) else { return nil }
        while true {
            let candidates = [vc.presentedViewController, (vc as? UINavigationController)?.topViewController,
                              (vc as? UITabBarController)?.selectedViewController]
            if let next = candidates.compactMap({ $0 }).first(where: { HostInspectionUIKit.includes($0, context: context) }) {
                vc = next
                continue
            }
            break
        }
        return vc
    }

    /// Limited scopes never fall back to a class object/singleton to escape scene/ownership checks.
    @MainActor
    static func kvcTarget(className: String?, context: HostInspectionContext = .init()) -> AnyObject? {
        guard let className, !className.isEmpty else { return topViewController(context: context) }
        guard let cls = resolveClass(className, context: context) else { return nil }
        if let top = topViewController(context: context), top.isKind(of: cls) { return top }
        return context.scope == .all ? cls as AnyObject : nil
    }

    // MARK: - Scoped KVC

    /// Walk one key at a time. value(forKeyPath:) would execute the whole chain, including
    /// getters on excluded objects and collection operators, before we could check ownership.
    @MainActor
    private static func propertyTarget(
        _ target: NSObject, keyPath: String, context: HostInspectionContext
    ) throws -> (NSObject, String) {
        let keys = keyPath.components(separatedBy: ".")
        guard !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty && !$0.contains("@") }) else {
            throw UIKitInspectionError.unsafeObjectChain
        }
        var current = target
        for (index, key) in keys.enumerated() {
            try validatePropertyTarget(current, context: context)
            if context.scope != .all {
                // These synthesize object graphs/descriptions instead of exposing a property.
                guard !key.hasPrefix("_"),
                      !["description", "debugDescription", "recursiveDescription", "class", "superclass",
                        "self", "nextResponder", "subviews", "windows", "connectedScenes",
                        "children", "childViewControllers", "viewControllers", "layer",
                        "delegate", "dataSource", "accessibilityElements"].contains(key) else {
                    throw UIKitInspectionError.unsafeObjectChain
                }
            }
            if index == keys.count - 1 { return (current, key) }
            let next = try ObjCExceptionCatcher.performReturning { current.value(forKey: key) }
            guard let object = next as? NSObject else { throw UIKitInspectionError.unsafeObjectChain }
            try validatePropertyTarget(object, context: context)
            current = object
        }
        throw UIKitInspectionError.unsafeObjectChain
    }

    @MainActor
    private static func validatePropertyTarget(_ object: NSObject, context: HostInspectionContext) throws {
        guard HostInspectionUIKit.includes(object, context: context) else { throw UIKitInspectionError.outsideScope }
        if context.scope != .all {
            // Class objects, collections and arbitrary non-UI intermediates could expose global
            // singletons or describe nested SDK objects. Use a scoped view path instead.
            guard object is UIView || object is UIViewController,
                  let cls = object_getClass(object), !class_isMetaClass(cls) else {
                throw UIKitInspectionError.unsafeObjectChain
            }
        }
    }

    /// Never ask an arbitrary object/collection for its description in a limited scope.
    /// A UI object is represented only by its class, after checking inherited ownership.
    @MainActor
    static func inspectedDescription(of value: Any?, context: HostInspectionContext = .init()) throws -> String {
        guard let value else { return "(nil)" }
        if let object = value as? NSObject {
            guard HostInspectionUIKit.includes(object, context: context) || (
                context.scope == .appagent && isScalarValue(object) && !HostInspectionUIKit.isAppAgentOwned(object)
            ) else { throw UIKitInspectionError.outsideScope }
        }
        if context.scope == .all { return String(describing: value) }
        if let object = value as? NSObject, HostInspectionUIKit.isAppAgentOwned(object),
           context.scope == .host { throw UIKitInspectionError.outsideScope }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let color = value as? UIColor { return hexString(of: color) }
        if let boxed = value as? NSValue, isScalarValue(boxed) { return boxed.description }
        if let view = value as? UIView { return "<\(NSStringFromClass(type(of: view)))>" }
        if let controller = value as? UIViewController { return "<\(NSStringFromClass(type(of: controller)))>" }
        throw UIKitInspectionError.unsafeObjectChain
    }

    private static func isScalarValue(_ object: NSObject) -> Bool {
        if object is NSString || object is NSNumber || object is UIColor { return true }
        if let value = object as? NSValue {
            let encoding = String(cString: value.objCType)
            return encoding.hasPrefix("{CGRect=") || encoding.hasPrefix("{CGPoint=")
                || encoding.hasPrefix("{CGSize=") || encoding.hasPrefix("{UIEdgeInsets=")
        }
        return false
    }

    @MainActor
    static func readProperty(
        from target: NSObject, keyPath: String, context: HostInspectionContext = .init()
    ) -> String {
        do {
            let (object, key) = try propertyTarget(target, keyPath: keyPath, context: context)
            let value = try ObjCExceptionCatcher.performReturning { object.value(forKey: key) }
            return try inspectedDescription(of: value, context: context)
        } catch let error as UIKitInspectionError {
            return error.localizedDescription
        } catch {
            // NSException.reason can contain the excluded object's description. Do not echo it.
            // 类名本身不敏感，而「读的是谁」恰恰是模型最缺的信息：真机上它为了猜
            // selectedIndex 挂在哪个对象上，连着烧了两轮共 167 秒。
            return "Failed to read \(keyPath) on \(type(of: target)): KVC access failed."
                + containerHint(for: target)
        }
    }

    /// 读写失败时补一句「当前目标是谁 + 容器怎么走」。默认目标是最内层可见页面，
    /// 对 tab 应用来说那是选中的子页，容器属性必须显式走 `tabBarController.…`。
    @MainActor
    static func containerHint(for target: NSObject) -> String {
        guard let controller = target as? UIViewController else { return "" }
        var hints: [String] = []
        if controller.tabBarController != nil { hints.append("tabBarController.<key>") }
        if controller.navigationController != nil { hints.append("navigationController.<key>") }
        if controller.parent != nil { hints.append("parent.<key>") }
        guard !hints.isEmpty else { return "" }
        return " 它是当前最内层可见页面；要读容器的属性请走 " + hints.joined(separator: " / ") + "。"
    }

    @MainActor
    static func writeProperty(
        on target: NSObject, keyPath: String, value: String, context: HostInspectionContext = .init()
    ) -> String {
        do {
            let (object, key) = try propertyTarget(target, keyPath: keyPath, context: context)
            // Validate the old value before invoking a setter on an object-valued property.
            // This also prevents a successful write from leaking an excluded rollback value.
            if context.scope != .all {
                let view = (object as? UIView) ?? (object as? UIViewController)?.viewIfLoaded
                if let view, containsExcludedView(view, context: context) {
                    throw UIKitInspectionError.outsideScope
                }
                let old = try ObjCExceptionCatcher.performReturning { object.value(forKey: key) }
                _ = try inspectedDescription(of: old, context: context)
                if old is UIView || old is UIViewController { throw UIKitInspectionError.unsafeObjectChain }
            }
            try ObjCExceptionCatcher.perform { object.setValue(boxedValue(from: value), forKey: key) }
            let updated = try ObjCExceptionCatcher.performReturning { object.value(forKey: key) }
            return "OK. \(keyPath) = \(try inspectedDescription(of: updated, context: context))"
        } catch let error as UIKitInspectionError {
            return error.localizedDescription
        } catch {
            return "Failed to set \(keyPath) on \(type(of: target)): KVC access failed."
                + containerHint(for: target)
        }
    }

    static func boxedValue(from string: String) -> Any {
        if let i = Int(string) { return NSNumber(value: i) }
        if let d = Double(string) { return NSNumber(value: d) }
        switch string.lowercased() {
        case "true", "yes": return NSNumber(value: true)
        case "false", "no": return NSNumber(value: false)
        default: return string
        }
    }

    // MARK: 路径与值解析（纯函数，便于单测）

    /// 单个视图的运行时状态快照（viewInfo 与 JS 桥共用）。
    @MainActor
    static func describeState(of view: UIView, path: String, context: HostInspectionContext = .init()) -> String {
        guard HostInspectionUIKit.includes(view, context: context) else {
            return UIKitInspectionError.outsideScope.localizedDescription
        }
        var out = "path=\(path)\nclass=\(type(of: view))\n"
        out += "frame=\(view.frame)\nbounds=\(view.bounds)\ncenter=\(view.center)\n"
        out += "alpha=\(view.alpha) hidden=\(view.isHidden) userInteractionEnabled=\(view.isUserInteractionEnabled)\n"
        out += "backgroundColor=\(view.backgroundColor.map { "\($0)" } ?? "nil")\n"
        out += "cornerRadius=\(view.layer.cornerRadius) tag=\(view.tag)\n"
        out += "superclass=\(view.superclass.map { "\($0)" } ?? "nil")\n"
        let parent = view.superview.flatMap { HostInspectionUIKit.includes($0, context: context) ? $0 : nil }
        let childCount = view.subviews.filter { HostInspectionUIKit.includes($0, context: context) }.count
        out += "superview=\(parent.map { "\(type(of: $0))" } ?? "nil/out-of-scope") subviews=\(childCount)\n"
        if let label = view as? UILabel { out += "text=\"\(label.text ?? "")\"\n" }
        if let field = view as? UITextField { out += "text=\"\(field.text ?? "")\"\n" }
        if let button = view as? UIButton { out += "title=\"\(button.title(for: .normal) ?? "")\"\n" }
        return out
    }

    /// 改之前的原值，格式与 `applyValue` 接受的 value 一致 —— 所以模型把它原样写回去
    /// 就完成了回滚。`view_set` 之前是单向的：改坏了没有任何撤销路径（我自己撞过一次，
    /// 自检把 demo 的 tab bar 改成了半透明蓝块）。
    @MainActor
    static func readValue(from view: UIView, key: String, context: HostInspectionContext = .init()) -> String {
        guard HostInspectionUIKit.includes(view, context: context) else {
            return UIKitInspectionError.outsideScope.localizedDescription
        }
        func rect(_ r: CGRect) -> String {
            String(format: "%.1f,%.1f,%.1f,%.1f", r.origin.x, r.origin.y, r.width, r.height)
        }
        switch key {
        case "frame": return rect(view.frame)
        case "bounds": return rect(view.bounds)
        case "center": return String(format: "%.1f,%.1f", view.center.x, view.center.y)
        case "alpha": return "\(view.alpha)"
        case "hidden", "isHidden": return "\(view.isHidden)"
        case "cornerRadius": return "\(view.layer.cornerRadius)"
        case "backgroundColor": return view.backgroundColor.map { hexString(of: $0) } ?? "clear"
        case "text", "title":
            if let label = view as? UILabel { return label.text ?? "" }
            if let field = view as? UITextField { return field.text ?? "" }
            if let button = view as? UIButton { return button.title(for: .normal) ?? "" }
            return ""
        default:
            return readProperty(from: view, keyPath: key, context: context)
        }
    }

    /// UIColor → `#RRGGBBAA`，正好是 `parseColor` 的输入格式。
    @MainActor
    static func hexString(of color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "\(color)" }
        let clamp: (CGFloat) -> Int = { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", clamp(r), clamp(g), clamp(b), clamp(a))
    }

    /// 对单个视图应用一次属性修改（view_set 与 JS 桥共用；已在主线程）。
    /// 成功时附带改前的原值，调用方把它写回同一个 key 即可回滚。
    @MainActor
    static func applyValue(to view: UIView, key: String, value: String, context: HostInspectionContext = .init()) -> String {
        guard HostInspectionUIKit.includes(view, context: context) else {
            return UIKitInspectionError.outsideScope.localizedDescription
        }
        if context.scope != .all, containsExcludedView(view, context: context) {
            return "Inspection denied: mutation target contains an out-of-scope subtree."
        }
        let previous = readValue(from: view, key: key, context: context)
        if previous.hasPrefix("Inspection denied:") || previous.hasPrefix("Failed to read ") { return previous }
        let result = applyValueWithoutRollbackHint(to: view, key: key, value: value, context: context)
        guard result.hasPrefix("OK.") else { return result }
        return result + "  (previous: \(previous) — write it back to the same key to undo)"
    }

    @MainActor
    private static func applyValueWithoutRollbackHint(to view: UIView, key: String, value: String,
                                                     context: HostInspectionContext) -> String {
        switch key {
        case "frame", "bounds":
            guard let rect = parseRect(value) else {
                return "Invalid rect '\(value)'. Use \"x,y,width,height\"."
            }
            if key == "frame" { view.frame = rect } else { view.bounds = rect }
            return "OK. \(key) = \(key == "frame" ? view.frame : view.bounds)"
        case "center":
            guard let point = parsePoint(value) else {
                return "Invalid point '\(value)'. Use \"x,y\"."
            }
            view.center = point
            return "OK. center = \(view.center)"
        case "alpha":
            guard let alpha = Double(value) else { return "Invalid alpha '\(value)'." }
            view.alpha = CGFloat(alpha)
            return "OK. alpha = \(view.alpha)"
        case "hidden", "isHidden":
            view.isHidden = parseBool(value)
            return "OK. hidden = \(view.isHidden)"
        case "cornerRadius":
            guard let radius = Double(value) else { return "Invalid cornerRadius '\(value)'." }
            view.layer.cornerRadius = CGFloat(radius)
            view.layer.masksToBounds = radius > 0
            return "OK. cornerRadius = \(view.layer.cornerRadius)"
        case "backgroundColor":
            guard let color = parseColor(value) else {
                return "Invalid color '\(value)'. Use #RRGGBB / #RRGGBBAA / red|green|blue|clear|white|black."
            }
            view.backgroundColor = color
            return "OK. backgroundColor = \(color)"
        case "text", "title":
            if let label = view as? UILabel { label.text = value; return "OK. text = \"\(value)\"" }
            if let field = view as? UITextField { field.text = value; return "OK. text = \"\(value)\"" }
            if let button = view as? UIButton { button.setTitle(value, for: .normal); return "OK. title = \"\(value)\"" }
            return "\(type(of: view)) has no text/title to set."
        default:
            return writeProperty(on: view, keyPath: key, value: value, context: context)
        }
    }

    /// 解析路径下的视图：`"root"`（或空）为 keyWindow，`"0/2"` 为 window.subviews[0].subviews[2]。
    /// 也支持从任意根视图出发（测试用）。
    @MainActor
    static func view(atPath path: String, root: UIView? = nil, context: HostInspectionContext = .init()) -> UIView? {
        var indices = path.trimmingCharacters(in: .whitespaces)
        var start = root ?? keyWindow(context: context)
        // `W2:0/1` —— 指定第几个 window 为根。没有前缀时沿用 keyWindow，
        // 否则 overlay window 里的视图根本没法寻址。
        if indices.hasPrefix("W"), let colon = indices.firstIndex(of: ":") {
            let digits = indices[indices.index(after: indices.startIndex)..<colon]
            guard let windowIndex = Int(digits) else { return nil }
            guard windowIndex >= 0 else { return nil }
            start = HostInspectionUIKit.window(handle: windowIndex, context: context)
            indices = String(indices[indices.index(after: colon)...])
        }
        guard var current = start else { return nil }
        let trimmed = indices.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "root" {
            return HostInspectionUIKit.includes(current, context: context) ? current : nil
        }
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard HostInspectionUIKit.canTraverse(current, context: context) else { return nil }
            guard let index = Int(component), index >= 0, index < current.subviews.count else { return nil }
            current = current.subviews[index]
        }
        return HostInspectionUIKit.includes(current, context: context) ? current : nil
    }

    /// `"x,y,w,h"` → CGRect（允许空格）。
    static func parseRect(_ string: String) -> CGRect? {
        let parts = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// `"x,y"` → CGPoint。
    static func parsePoint(_ string: String) -> CGPoint? {
        let parts = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    static func parseBool(_ string: String) -> Bool {
        ["true", "yes", "1"].contains(string.lowercased())
    }

    /// `#RRGGBB` / `#RRGGBBAA` / 常用颜色名 → UIColor。
    static func parseColor(_ string: String) -> UIColor? {
        let raw = string.trimmingCharacters(in: .whitespaces).lowercased()
        switch raw {
        case "clear", "transparent": return .clear
        case "white": return .white
        case "black": return .black
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "orange": return .orange
        case "gray", "grey": return .gray
        default: break
        }
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
        return UIColor(
            red: CGFloat((value >> 24) & 0xFF) / 255,
            green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255
        )
    }

    /// 递归打印带路径的视图树。
    @MainActor
    static func describeAddressable(
        view: UIView, path: String, depth: Int, maxDepth: Int,
        context: HostInspectionContext = .init(), into out: inout String
    ) {
        guard HostInspectionUIKit.canTraverse(view, context: context) else { return }
        if !HostInspectionUIKit.includes(view, context: context) {
            for (index, sub) in view.subviews.enumerated() {
                let childPath = childPath(parent: path, index: index)
                describeAddressable(view: sub, path: childPath, depth: depth, maxDepth: maxDepth,
                                    context: context, into: &out)
            }
            return
        }
        let pad = String(repeating: "  ", count: depth)
        var extra = ""
        if let label = view as? UILabel { extra = " text=\"\(label.text ?? "")\"" }
        else if let button = view as? UIButton { extra = " title=\"\(button.title(for: .normal) ?? "")\"" }
        else if let field = view as? UITextField { extra = " text=\"\(field.text ?? "")\"" }
        let hidden = view.isHidden ? " hidden" : ""
        out += "\(pad)[\(path)] \(type(of: view)) frame=\(view.frame)\(extra)\(hidden)\n"
        guard depth < maxDepth else {
            let count = view.subviews.filter { HostInspectionUIKit.includes($0, context: context) }.count
            if count > 0 { out += "\(pad)  … \(count) more subviews (raise maxDepth)\n" }
            return
        }
        for (index, sub) in view.subviews.enumerated() {
            let childPath = childPath(parent: path, index: index)
            describeAddressable(view: sub, path: childPath, depth: depth + 1, maxDepth: maxDepth,
                                context: context, into: &out)
        }
    }

    private static func childPath(parent: String, index: Int) -> String {
        if parent == "root" { return "\(index)" }
        if parent.hasSuffix(":root") { return String(parent.dropLast(4)) + "\(index)" }
        if parent.hasSuffix(":") { return "\(parent)\(index)" }
        return "\(parent)/\(index)"
    }

    /// Explicit trailing-context form for bridge callers that already pass `into:` last.
    @MainActor
    static func describeAddressable(
        view: UIView, path: String, depth: Int, maxDepth: Int, into out: inout String,
        context: HostInspectionContext
    ) {
        describeAddressable(view: view, path: path, depth: depth, maxDepth: maxDepth,
                            context: context, into: &out)
    }

    static func methods(of cls: AnyClass, isClassMethod: Bool) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        var out: [String] = []
        for i in 0..<Int(count) {
            let m = list[i]
            let name = NSStringFromSelector(method_getName(m))
            let argc = method_getNumberOfArguments(m)
            let prefix = isClassMethod ? "+ " : "- "
            out.append("\(prefix)\(name)  (args: \(Int(argc) - 2))")
        }
        return out.sorted()
    }

    /// `perform(_:with:)` 只会**按对象指针**传参、**按对象指针**读返回值。碰上原始
    /// 类型就是一次 ABI 不匹配的调用：`setTag:` 收的是 NSInteger，传进去的 NSNumber
    /// 指针会被当成整数写进 tag（实测写进去的是个天文数字，而不是模型要的 7）；
    /// `isHidden` 返回 BOOL，把 1 当对象指针 `takeUnretainedValue()` 直接崩；返回结构体
    /// （`frame`）的 ABI 走 sret，更是必崩。所以先按 ObjC 类型编码筛一遍：只放行
    /// 「参数全是对象、返回 void 或对象」的选择器，原始类型的属性让模型改走
    /// `view_set` / `property_set`（KVC 会正确装箱）。
    ///
    /// 返回 nil = 可以调；返回字符串 = 拒绝理由（以 `(selector ` 起头，工具层按前缀判失败）。
    @MainActor
    static func selectorRejection(
        _ sel: Selector, on obj: NSObject, argCount: Int, context: HostInspectionContext = .init()
    ) -> String? {
        let name = NSStringFromSelector(sel)
        guard HostInspectionUIKit.includes(obj, context: context) else {
            return "Inspection denied: selector target is outside scope."
        }
        // 实例对象给出它的类；类对象（invoke 走类方法时）给出元类，元类上的
        // “实例方法”正是它的类方法。两种情形用同一个查询。
        guard let cls: AnyClass = object_getClass(obj),
              let method = class_getInstanceMethod(cls, sel) else {
            return "(selector \(name) has no inspectable signature; dynamic forwarding is not supported)"
        }
        let declared = Int(method_getNumberOfArguments(method)) - 2
        guard argCount <= 2 else { return "(selector \(name): at most two arguments are supported)" }
        guard declared == argCount else {
            return "(selector \(name) takes \(declared) argument(s), got \(argCount))"
        }
        for i in 0..<declared {
            var buffer = [CChar](repeating: 0, count: 64)
            method_getArgumentType(method, UInt32(i + 2), &buffer, 64)
            // 运行时写进来的是 NUL 结尾的类型编码，64 字节缓冲区尾部全是填充的 0；
            // 必须先截到第一个 NUL 再解码，否则 `type` 会拖着一串 `\0`，跟 "@" 这类编码比不上。
            // （`method_getArgumentType` 只收 `CChar` 缓冲区，所以这里按位重解释成 UTF-8 字节。）
            let type = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isObjectEncoding(type) else {
                return "(selector \(name) argument #\(i + 1) is ObjC type '\(type)', not an object — "
                    + "reflection can only pass objects. Use view_set / property_set for primitives.)"
            }
        }
        let returnPointer = method_copyReturnType(method)
        let returnType = String(cString: returnPointer)
        free(returnPointer)
        guard returnType == "v" || isObjectEncoding(returnType) else {
            return "(selector \(name) returns ObjC type '\(returnType)', not an object — "
                + "reading it as one would crash. Use property_value / view_info to read primitives.)"
        }
        if context.scope != .all {
            // Arbitrary host selectors can reach global state; target filtering is not a sandbox.
            // Limited scopes expose only these local UIKit invalidation/structural operations.
            let local: Set<String> = ["setNeedsLayout", "setNeedsDisplay", "layoutIfNeeded", "removeFromSuperview"]
            guard obj is UIView, local.contains(name), declared == 0, returnType == "v" else {
                return "(selector \(name) requires all scope; arbitrary selectors cannot be scope-isolated)"
            }
            if let view = obj as? UIView, containsExcludedView(view, context: context) {
                return "(selector \(name) would act on an out-of-scope subtree)"
            }
        }
        return nil
    }

    /// `@`（id）、`@?`（block）、`@"NSString"`（带类名）、`#`（Class）都算对象。
    private static func isObjectEncoding(_ type: String) -> Bool {
        type.hasPrefix("@") || type == "#"
    }

    @MainActor
    static func performSelector(
        _ sel: Selector, on obj: NSObject, args: [Any], context: HostInspectionContext = .init()
    ) -> Any? {
        if let rejection = selectorRejection(sel, on: obj, argCount: args.count, context: context) {
            return rejection
        }
        // The caller still needs ObjCExceptionCatcher for an exception thrown by host code.
        // A void-returning IMP has no object result: never dereference its return register.
        guard let cls = object_getClass(obj), let method = class_getInstanceMethod(cls, sel) else {
            return "(selector has no inspectable signature)"
        }
        let returnType = method_copyReturnType(method)
        let returnsVoid = String(cString: returnType) == "v"
        free(returnType)
        let result: Unmanaged<AnyObject>?
        switch args.count {
        case 0:
            result = obj.perform(sel)
        case 1:
            result = obj.perform(sel, with: args[0])
        default:
            result = obj.perform(sel, with: args[0], with: args[1])
        }
        return returnsVoid ? nil : result?.takeUnretainedValue()
    }

    @MainActor
    static func describe(viewController vc: UIViewController, indent: Int,
                         context: HostInspectionContext = .init(), into out: inout String) {
        guard HostInspectionUIKit.includes(vc, context: context) else {
            if context.scope == .appagent {
                for child in vc.children {
                    describe(viewController: child, indent: indent, context: context, into: &out)
                }
                if let presented = vc.presentedViewController {
                    describe(viewController: presented, indent: indent, context: context, into: &out)
                }
            }
            return
        }
        let pad = String(repeating: "  ", count: indent)
        out += "\(pad)- \(type(of: vc)) title=\(vc.title ?? "nil")\n"
        for child in vc.children {
            describe(viewController: child, indent: indent + 1, context: context, into: &out)
        }
        if let presented = vc.presentedViewController, HostInspectionUIKit.includes(presented, context: context) {
            out += "\(pad)  (presented)\n"
            describe(viewController: presented, indent: indent + 1, context: context, into: &out)
        }
    }

    @MainActor
    static func describe(view: UIView, indent: Int, context: HostInspectionContext = .init(), into out: inout String) {
        guard HostInspectionUIKit.canTraverse(view, context: context) else { return }
        guard HostInspectionUIKit.includes(view, context: context) else {
            for sub in view.subviews { describe(view: sub, indent: indent, context: context, into: &out) }
            return
        }
        let pad = String(repeating: "  ", count: indent)
        var extra = ""
        if let label = view as? UILabel { extra = " text=\"\(label.text ?? "")\"" }
        else if let button = view as? UIButton { extra = " title=\"\(button.title(for: .normal) ?? "")\"" }
        else if let field = view as? UITextField { extra = " text=\"\(field.text ?? "")\" placeholder=\"\(field.placeholder ?? "")\"" }
        let hidden = view.isHidden ? " hidden" : ""
        out += "\(pad)• \(type(of: view)) frame=\(view.frame)\(extra)\(hidden)\n"
        for sub in view.subviews {
            describe(view: sub, indent: indent + 1, context: context, into: &out)
        }
    }

    @MainActor
    private static func containsExcludedView(_ view: UIView, context: HostInspectionContext) -> Bool {
        !HostInspectionUIKit.includes(view, context: context)
            || view.subviews.contains { containsExcludedView($0, context: context) }
    }

    // MARK: - 摘要引擎
    //
    // 全量层级在真实 app 里动辄几十 KB（本仓库 demo 三个空 window 已经 19 KB），
    // 一次塞给模型就把上下文吃光了。所以首次调用只给「地图」：
    //   骨架用 VC 树（页面栈才是 agent 真正想问的东西），
    //   视图只列语义锚点，UIKit 包装层穿透不占行，
    //   大子树折叠成统计并附上可直接二次调用的 path。

    /// 摘要档位。调大 = 更全但更贵。
    private enum Summary {
        static let anchorDepth = 4       // 锚点最多嵌套几层
        static let collapseAbove = 12    // 子树视图数超过它就折叠成统计
        static let anchorsPerLevel = 8   // 同层最多列几个锚点
        static let textPreview = 40      // 文本预览截断
    }

    /// UIKit 自己的包装层：出现在层级里只是噪音，摘要里穿透。
    private static let chromePrefixes = [
        "_UI", "UITransitionView", "UIDropShadowView", "UILayoutContainerView",
        "UIViewControllerWrapperView", "UINavigationTransitionView"
    ]

    @MainActor
    static func isChrome(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        return chromePrefixes.contains { name.hasPrefix($0) }
    }
    /// 值得在摘要里单独占一行的视图：能被人/agent 指认的东西。
    @MainActor
    static func isAnchor(_ view: UIView, context: HostInspectionContext = .init()) -> Bool {
        guard HostInspectionUIKit.includes(view, context: context) else { return false }
        if view is UIWindow { return false }        // window 自己在标题行
        if isChrome(view) { return false }
        if view.accessibilityIdentifier?.isEmpty == false { return true }
        if view.accessibilityLabel?.isEmpty == false { return true }
        if view is UIControl || view is UIScrollView { return true }
        if view is UITextView || view is UIImageView { return true }
        if let label = view as? UILabel { return label.text?.isEmpty == false }
        // 宿主 / SDK 自定义视图（不在系统命名空间里）
        let name = String(describing: type(of: view))
        return !name.hasPrefix("UI") && !name.hasPrefix("NS") && !name.hasPrefix("CA")
    }

    /// 子树规模画像，用于决定「展开还是折叠」以及折叠后显示什么。
    struct SubtreeStats {
        var views = 0, labels = 0, controls = 0, scrolls = 0, images = 0, anchors = 0
        var depth = 0
    }

    /// 深度是相对于传入节点的。
    @MainActor
    static func stats(of view: UIView, context: HostInspectionContext = .init()) -> SubtreeStats {
        var s = SubtreeStats()
        guard HostInspectionUIKit.canTraverse(view, context: context) else { return s }
        let included = HostInspectionUIKit.includes(view, context: context)
        if included {
            s.views = 1
            if view is UIControl { s.controls += 1 }
            if view is UIScrollView { s.scrolls += 1 }
            if view is UIImageView { s.images += 1 }
            if let label = view as? UILabel, label.text?.isEmpty == false { s.labels += 1 }
            if isAnchor(view, context: context) { s.anchors += 1 }
        }
        for sub in view.subviews {
            let c = stats(of: sub, context: context)
            s.views += c.views; s.labels += c.labels; s.controls += c.controls
            s.scrolls += c.scrolls; s.images += c.images; s.anchors += c.anchors
            if c.views > 0 { s.depth = max(s.depth, c.depth + (included ? 1 : 0)) }
        }
        return s
    }

    static func clip(_ text: String, _ max: Int = Summary.textPreview) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }

    /// 一行里跟在类名后面的可辨识信息：文本、占位符、a11y、异常状态。
    @MainActor
    static func inlineLabel(of view: UIView, context: HostInspectionContext = .init()) -> String {
        guard HostInspectionUIKit.includes(view, context: context) else { return "" }
        var bits: [String] = []
        if let label = view as? UILabel, let t = label.text, !t.isEmpty {
            bits.append("\"\(clip(t))\"")
        }
        if let field = view as? UITextField {
            if let t = field.text, !t.isEmpty { bits.append("\"\(clip(t))\"") }
            else if let p = field.placeholder, !p.isEmpty { bits.append("placeholder=\"\(clip(p))\"") }
        }
        if let button = view as? UIButton, let t = button.title(for: .normal), !t.isEmpty {
            bits.append("\"\(clip(t))\"")
        }
        if let id = view.accessibilityIdentifier, !id.isEmpty { bits.append("id=\(id)") }
        else if let a11y = view.accessibilityLabel, !a11y.isEmpty { bits.append("a11y=\"\(clip(a11y))\"") }
        if view.isHidden { bits.append("hidden") }
        if view.alpha < 0.99 { bits.append(String(format: "alpha=%.2f", view.alpha)) }
        return bits.isEmpty ? "" : " " + bits.joined(separator: " ")
    }

    /// 视图 → 可寻址路径（`W0:0/1/2`）。摘要给 VC 挂钻取句柄用。
    @MainActor
    static func addressablePath(of view: UIView, context: HostInspectionContext = .init()) -> String? {
        guard HostInspectionUIKit.includes(view, context: context) else { return nil }
        var indices: [Int] = []
        var node = view
        while let parent = node.superview {
            guard let index = parent.subviews.firstIndex(of: node) else { return nil }
            indices.append(index)
            node = parent
        }
        guard let window = node as? UIWindow,
              let windows = try? HostInspectionUIKit.sceneWindows(context: context),
              windows.contains(where: { $0 === window }) else { return nil }
        let windowIndex = HostInspectionUIKit.handle(for: window)
        let tail = indices.reversed().map(String.init).joined(separator: "/")
        return tail.isEmpty ? "W\(windowIndex):root" : "W\(windowIndex):\(tail)"
    }
    /// VC 骨架：页面栈才是 agent 真正在问的「app 现在有哪些页面」。
    /// 关键约束：`isViewLoaded == false` 的 VC 绝不碰它的 `view` —— 内省不该反过来触发 loadView。
    @MainActor
    static func describeVCSkeleton(_ vc: UIViewController, indent: Int,
                                   context: HostInspectionContext = .init(), into out: inout String) {
        guard HostInspectionUIKit.includes(vc, context: context) else {
            if context.scope == .appagent {
                for child in vc.children {
                    describeVCSkeleton(child, indent: indent, context: context, into: &out)
                }
                if let presented = vc.presentedViewController {
                    describeVCSkeleton(presented, indent: indent, context: context, into: &out)
                }
            }
            return
        }
        let pad = String(repeating: "  ", count: indent)
        var line = "\(pad)- \(type(of: vc))"
        if let title = vc.title, !title.isEmpty { line += " title=\"\(clip(title))\"" }
        guard vc.isViewLoaded else {
            out += line + "  (view 未加载)\n"
            return
        }
        if let path = addressablePath(of: vc.view, context: context) { line += "  view=[\(path)]" }
        out += line + "\n"

        if let nav = vc as? UINavigationController {
            let visible = nav.viewControllers.filter { HostInspectionUIKit.includes($0, context: context) }
            let top = visible.last.map { "\(type(of: $0))" } ?? "nil"
            out += "\(pad)  页面栈 \(visible.count) 层，栈顶 = \(top)\n"
            for child in visible {
                describeVCSkeleton(child, indent: indent + 2, context: context, into: &out)
            }
        } else if let tab = vc as? UITabBarController {
            let all = tab.viewControllers ?? []
            let visible = all.enumerated().filter { HostInspectionUIKit.includes($0.element, context: context) }
            let selected = visible.contains(where: { $0.offset == tab.selectedIndex }) ? "\(tab.selectedIndex)" : "out-of-scope"
            out += "\(pad)  \(visible.count) 个 tab，当前 = \(selected)\n"
            for (index, child) in visible {
                // 标签文字是模型把用户说的「profile 页」对上索引的唯一线索。未加载的子 VC
                // 只会打印类名（三个 tab 都是同一个占位类时完全无从分辨），所以标题必须带上。
                let title = child.tabBarItem?.title ?? child.title
                let label = title.map { " \"\(clip($0))\"" } ?? ""
                out += "\(pad)  [tab \(index)\(label)\(index == tab.selectedIndex ? " ← 可见" : "")]\n"
                describeVCSkeleton(child, indent: indent + 2, context: context, into: &out)
            }
        } else {
            for child in vc.children {
                describeVCSkeleton(child, indent: indent + 1, context: context, into: &out)
            }
        }
        if let presented = vc.presentedViewController, HostInspectionUIKit.includes(presented, context: context) {
            out += "\(pad)  present 出 ↓\n"
            describeVCSkeleton(presented, indent: indent + 1, context: context, into: &out)
        }
    }

    /// 只列锚点：非锚点直接穿透（不占行但路径继续累积），
    /// 子树太大或已到深度上限就折叠成统计 + 钻取 path。
    @MainActor
    static func emitAnchors(of view: UIView, path: String, anchorDepth: Int,
                            indent: Int, context: HostInspectionContext = .init(), into out: inout String) {
        guard HostInspectionUIKit.canTraverse(view, context: context) else { return }
        let pad = String(repeating: "  ", count: indent)
        var shown = 0
        var collapsedViews = 0

        for (index, sub) in view.subviews.enumerated() {
            guard HostInspectionUIKit.canTraverse(sub, context: context) else { continue }
            let subPath = childPath(parent: path, index: index)
            let subStats = stats(of: sub, context: context)

            guard isAnchor(sub, context: context) else {
                // 包装层 / 无信息量的容器：穿透，路径不断
                if subStats.anchors > 0 {
                    emitAnchors(of: sub, path: subPath, anchorDepth: anchorDepth,
                                indent: indent, context: context, into: &out)
                } else {
                    collapsedViews += subStats.views
                }
                continue
            }

            if shown >= Summary.anchorsPerLevel {
                collapsedViews += subStats.views
                continue
            }
            shown += 1

            var line = "\(pad)• \(type(of: sub))\(inlineLabel(of: sub, context: context)) [\(subPath)]"
            let inside = subStats.views - 1
            let tooBig = inside > Summary.collapseAbove
            let tooDeep = anchorDepth + 1 >= Summary.anchorDepth

            if inside > 0 && (tooBig || tooDeep) {
                var parts: [String] = []
                if subStats.labels > 0 { parts.append("\(subStats.labels) labels") }
                if subStats.controls > 0 { parts.append("\(subStats.controls) controls") }
                if subStats.scrolls > 0 { parts.append("\(subStats.scrolls) scrolls") }
                if subStats.images > 0 { parts.append("\(subStats.images) images") }
                line += "  ⊞ \(inside) views"
                if !parts.isEmpty { line += "（" + parts.joined(separator: "、") + "）" }
                line += " depth=\(subStats.depth)"
                out += line + "\n"
            } else {
                out += line + "\n"
                emitAnchors(of: sub, path: subPath, anchorDepth: anchorDepth + 1,
                            indent: indent + 1, context: context, into: &out)
            }
        }

        if collapsedViews > 0 {
            out += "\(pad)… 另有 \(collapsedViews) 个无文本/无交互的视图（已省略）\n"
        }
    }

    @MainActor
    static func hierarchySummary(context: HostInspectionContext = .init()) -> String {
        let windows: [UIWindow]
        do { windows = try HostInspectionUIKit.sceneWindows(context: context) }
        catch { return error.localizedDescription }
        var out = "UI 摘要 · 只列关键节点。⊞ = 已折叠子树，用 view_tree(path:\"…\") 展开\n"
        var found = false
        for window in windows {
            let roots = HostInspectionUIKit.inspectionRoots(in: window, context: context)
            guard !roots.isEmpty else { continue }
            found = true
            for root in roots {
                guard let path = addressablePath(of: root, context: context) else { continue }
                let total = stats(of: root, context: context)
                out += "\n[\(path)] \(type(of: root))\(inlineLabel(of: root, context: context))"
                out += " · 共 \(total.views) 视图 / depth \(total.depth)\n"
                out += "  视图锚点：\n"
                emitAnchors(of: root, path: path, anchorDepth: 0, indent: 2, context: context, into: &out)
            }
            if let root = window.rootViewController {
                describeVCSkeleton(root, indent: 2, context: context, into: &out)
            }
        }
        guard found else { return "(no windows)" }
        out += "\n钻取：view_tree(path:\"W0:0/1\") 展开子树 · view_info(path:…) 看单个视图 · "
        out += "ui_hierarchy(detail:\"full\") 拿全量（体积大，慎用）\n"
        return out
    }
}
#endif
