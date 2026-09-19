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

public final class DefaultRuntimeInspectProvider: RuntimeInspectProvider, @unchecked Sendable {

    public init() {}

    // MARK: - UI Hierarchy

    public func uiHierarchy() async -> String {
        await MainActor.run {
            let windows = Self.allWindows()
            guard !windows.isEmpty else { return "(no windows)" }
            // 一个 app 常常有多个 window（本 SDK 的对话 UI 就挂在独立 overlay window
            // 上），只看 keyWindow 会整层漏掉，所以按 windowLevel 全量列出。
            var out = ""
            for window in windows {
                out += "Window: \(type(of: window)) frame=\(window.frame)"
                out += " level=\(window.windowLevel.rawValue)"
                out += window.isKeyWindow ? " [key]" : ""
                out += window.isHidden ? " [hidden]" : ""
                out += "\n"
                if let root = window.rootViewController {
                    out += "RootViewController:\n"
                    Self.describe(viewController: root, indent: 1, into: &out)
                }
                out += "View tree:\n"
                Self.describe(view: window, indent: 0, into: &out)
                out += "\n"
            }
            return out
        }
    }

    // MARK: - Class list

    public func classList(matching filter: String?) async -> [String] {
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return [] }
        let classes = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { classes.deallocate() }
        let autoreleasing = AutoreleasingUnsafeMutablePointer<AnyClass>(classes)
        let realCount = objc_getClassList(autoreleasing, count)
        var names: [String] = []
        names.reserveCapacity(Int(realCount))
        for i in 0..<Int(realCount) {
            let name = NSStringFromClass(classes[i])
            if let filter, !filter.isEmpty {
                if name.range(of: filter, options: .caseInsensitive) != nil { names.append(name) }
            } else {
                names.append(name)
            }
        }
        return names.sorted()
    }

    // MARK: - Methods

    public func methodList(ofClass className: String) async -> [String] {
        guard let cls = Self.resolveClass(className) else { return ["(class not found: \(className))"] }
        var result: [String] = []
        result.append(contentsOf: Self.methods(of: cls, isClassMethod: false))
        if let meta: AnyClass = object_getClass(cls) {
            result.append(contentsOf: Self.methods(of: meta, isClassMethod: true))
        }
        return result.isEmpty ? ["(no methods)"] : result
    }

    // MARK: - Properties / ivars

    public func propertyList(ofClass className: String) async -> [String] {
        guard let cls = Self.resolveClass(className) else { return ["(class not found: \(className))"] }
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

    public func propertyValue(keyPath: String, ofClass className: String?) async -> String? {
        await MainActor.run {
            guard let target = Self.kvcTarget(className: className) as? NSObject else {
                return "(no target object for KVC; className=\(className ?? "top page"))"
            }
            do {
                let value = try ObjCExceptionCatcher.performReturning {
                    target.value(forKeyPath: keyPath)
                }
                guard let value else { return "(nil)" }
                return "\(value)"
            } catch {
                return "Failed to read \(keyPath): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - KVC write

    public func setPropertyValue(keyPath: String, value: String, ofClass className: String?) async -> String {
        await MainActor.run {
            guard let target = Self.kvcTarget(className: className) as? NSObject else {
                return "(no target object for KVC; className=\(className ?? "top page"))"
            }
            let boxed = Self.boxedValue(from: value)
            do {
                try ObjCExceptionCatcher.perform {
                    target.setValue(boxed, forKeyPath: keyPath)
                }
                let readBack = (try? ObjCExceptionCatcher.performReturning {
                    target.value(forKeyPath: keyPath)
                })?.map { "\($0)" } ?? "(nil)"
                return "OK. \(keyPath) = \(readBack)"
            } catch {
                return "Failed to set \(keyPath): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Reflection invoke

    public func invoke(className: String, selector: String, argumentsJSON: String) async -> String {
        await MainActor.run {
            guard let cls = Self.resolveClass(className) else {
                return "(class not found: \(className))"
            }
            let sel = NSSelectorFromString(selector)
            // 优先对栈顶页面（若为该类实例）调用实例方法；否则当作类方法调用。
            let target: NSObject?
            if let top = Self.kvcTarget(className: className) as? NSObject, top.responds(to: sel) {
                target = top
            } else if let clsObj = cls as AnyObject as? NSObject, clsObj.responds(to: sel) {
                target = clsObj
            } else {
                return "(selector \(selector) not found on \(className) instance/class)"
            }
            guard let obj = target else { return "(no target)" }
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [Any] ?? []
            if let rejection = Self.selectorRejection(sel, on: obj, argCount: args.count) { return rejection }
            do {
                let result = try ObjCExceptionCatcher.performReturning {
                    Self.performSelector(sel, on: obj, args: args)
                }
                return result.map { "\($0)" } ?? "(void/nil)"
            } catch {
                return "Invoke failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 按路径寻址视图

    public func viewTree(maxDepth: Int) async -> String {
        await MainActor.run {
            guard let window = Self.keyWindow() else { return "(no key window)" }
            var out = "路径 root = keyWindow；子视图路径形如 0/2/1（按 subviews 下标）\n"
            Self.describeAddressable(view: window, path: "root", depth: 0, maxDepth: maxDepth, into: &out)
            return out
        }
    }

    public func viewInfo(path: String) async -> String {
        await MainActor.run {
            guard let view = Self.view(atPath: path) else { return "(no view at path '\(path)')" }
            return Self.describeState(of: view, path: path)
        }
    }

    public func setViewValue(path: String, key: String, value: String) async -> String {
        await MainActor.run {
            guard let view = Self.view(atPath: path) else { return "(no view at path '\(path)')" }
            return Self.applyValue(to: view, key: key, value: value)
        }
    }

    public func invokeOnView(path: String, selector: String, argumentsJSON: String) async -> String {
        await MainActor.run {
            guard let view = Self.view(atPath: path) else { return "(no view at path '\(path)')" }
            let sel = NSSelectorFromString(selector)
            guard view.responds(to: sel) else {
                return "(selector \(selector) not found on \(type(of: view)))"
            }
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [Any] ?? []
            if let rejection = Self.selectorRejection(sel, on: view, argCount: args.count) { return rejection }
            do {
                let result = try ObjCExceptionCatcher.performReturning {
                    Self.performSelector(sel, on: view, args: args)
                }
                return result.map { "\($0)" } ?? "(void/nil)"
            } catch {
                return "Invoke failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 分层摘要：先给地图，细节按需二次调用

    public func uiHierarchySummary() async -> String {
        await MainActor.run { Self.hierarchySummary() }
    }

    public func viewSubtree(path: String, maxDepth: Int) async -> String {
        await MainActor.run {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "root" {
                guard let window = Self.keyWindow() else { return "(no windows)" }
                var out = "路径根 = keyWindow；子视图路径形如 0/2/1，跨 window 用 W1:0/2/1\n"
                Self.describeAddressable(view: window, path: "root", depth: 0, maxDepth: maxDepth, into: &out)
                return out
            }
            guard let view = Self.view(atPath: trimmed) else { return "(no view at path '\(trimmed)')" }
            var out = "从 [\(trimmed)] 展开，maxDepth=\(maxDepth)\n"
            Self.describeAddressable(view: view, path: trimmed, depth: 0, maxDepth: maxDepth, into: &out)
            return out
        }
    }

    // MARK: - Helpers

    static func keyWindow() -> UIWindow? {
        let windows = allWindows()
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// Every window across every connected window scene, ordered back-to-front.
    static func allWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    /// Resolve a class by name, tolerating Swift's module-qualified runtime names.
    ///
    /// `NSClassFromString("HostTabBarController")` fails for Swift classes because
    /// their Objective-C name is `"<Module>.HostTabBarController"`. The agent only
    /// ever knows the short name, so fall back to scanning the class list for a
    /// unique `*.name` match.
    static func resolveClass(_ name: String) -> AnyClass? {
        if let cls: AnyClass = NSClassFromString(name) { return cls }
        let suffix = "." + name
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return nil }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let realCount = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buffer), count)
        for i in 0..<Int(realCount) {
            if NSStringFromClass(buffer[i]).hasSuffix(suffix) { return buffer[i] }
        }
        return nil
    }

    static func topViewController() -> UIViewController? {
        guard var vc = keyWindow()?.rootViewController else { return nil }
        while true {
            if let presented = vc.presentedViewController { vc = presented; continue }
            if let nav = vc as? UINavigationController, let top = nav.topViewController { vc = top; continue }
            if let tab = vc as? UITabBarController, let sel = tab.selectedViewController { vc = sel; continue }
            break
        }
        return vc
    }

    /// KVC 目标：指定类名且栈顶页面正是该类实例则用之，否则回落到类对象；未指定类名则用栈顶页面。
    static func kvcTarget(className: String?) -> AnyObject? {
        guard let className, !className.isEmpty else { return topViewController() }
        guard let cls = resolveClass(className) else { return nil }
        if let top = topViewController(), type(of: top) == cls { return top }
        return cls as AnyObject
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
    static func describeState(of view: UIView, path: String) -> String {
        var out = "path=\(path)\nclass=\(type(of: view))\n"
        out += "frame=\(view.frame)\nbounds=\(view.bounds)\ncenter=\(view.center)\n"
        out += "alpha=\(view.alpha) hidden=\(view.isHidden) userInteractionEnabled=\(view.isUserInteractionEnabled)\n"
        out += "backgroundColor=\(view.backgroundColor.map { "\($0)" } ?? "nil")\n"
        out += "cornerRadius=\(view.layer.cornerRadius) tag=\(view.tag)\n"
        out += "superclass=\(view.superclass.map { "\($0)" } ?? "nil")\n"
        out += "superview=\(view.superview.map { "\(type(of: $0))" } ?? "nil") subviews=\(view.subviews.count)\n"
        if let label = view as? UILabel { out += "text=\"\(label.text ?? "")\"\n" }
        if let field = view as? UITextField { out += "text=\"\(field.text ?? "")\"\n" }
        if let button = view as? UIButton { out += "title=\"\(button.title(for: .normal) ?? "")\"\n" }
        return out
    }

    /// 改之前的原值，格式与 `applyValue` 接受的 value 一致 —— 所以模型把它原样写回去
    /// 就完成了回滚。`view_set` 之前是单向的：改坏了没有任何撤销路径（我自己撞过一次，
    /// 自检把 demo 的 tab bar 改成了半透明蓝块）。
    @MainActor
    static func readValue(from view: UIView, key: String) -> String {
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
            let existing = try? ObjCExceptionCatcher.performReturning { view.value(forKey: key) }
            guard let unwrapped = existing ?? nil else { return "(unreadable)" }
            return "\(unwrapped)"
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
    static func applyValue(to view: UIView, key: String, value: String) -> String {
        let previous = readValue(from: view, key: key)
        let result = applyValueWithoutRollbackHint(to: view, key: key, value: value)
        guard result.hasPrefix("OK.") else { return result }
        return result + "  (previous: \(previous) — write it back to the same key to undo)"
    }

    @MainActor
    private static func applyValueWithoutRollbackHint(to view: UIView, key: String, value: String) -> String {
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
            do {
                try ObjCExceptionCatcher.perform {
                    view.setValue(boxedValue(from: value), forKeyPath: key)
                }
                let readBack = (try? ObjCExceptionCatcher.performReturning {
                    view.value(forKeyPath: key)
                })?.map { "\($0)" } ?? "(nil)"
                // 成功文案统一以 `OK.` 起头：工具层按这个前缀判定写操作是否真的生效，
                // 原来的 "OK (KVC)." 既过不了那道判定，也拿不到下面的回滚提示。
                return "OK. \(key) = \(readBack)  (via KVC)"
            } catch {
                return "Failed to set \(key): \(error.localizedDescription)"
            }
        }
    }

    /// 解析路径下的视图：`"root"`（或空）为 keyWindow，`"0/2"` 为 window.subviews[0].subviews[2]。
    /// 也支持从任意根视图出发（测试用）。
    static func view(atPath path: String, root: UIView? = nil) -> UIView? {
        var indices = path.trimmingCharacters(in: .whitespaces)
        var start = root ?? keyWindow()
        // `W2:0/1` —— 指定第几个 window 为根。没有前缀时沿用 keyWindow，
        // 否则 overlay window 里的视图根本没法寻址。
        if indices.hasPrefix("W"), let colon = indices.firstIndex(of: ":") {
            let digits = indices[indices.index(after: indices.startIndex)..<colon]
            guard let windowIndex = Int(digits) else { return nil }
            let windows = allWindows()
            guard windowIndex >= 0, windowIndex < windows.count else { return nil }
            start = windows[windowIndex]
            indices = String(indices[indices.index(after: colon)...])
        }
        guard var current = start else { return nil }
        let trimmed = indices.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "root" { return current }
        for component in trimmed.split(separator: "/") {
            guard let index = Int(component), index >= 0, index < current.subviews.count else { return nil }
            current = current.subviews[index]
        }
        return current
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
    static func describeAddressable(
        view: UIView, path: String, depth: Int, maxDepth: Int, into out: inout String
    ) {
        let pad = String(repeating: "  ", count: depth)
        var extra = ""
        if let label = view as? UILabel { extra = " text=\"\(label.text ?? "")\"" }
        else if let button = view as? UIButton { extra = " title=\"\(button.title(for: .normal) ?? "")\"" }
        else if let field = view as? UITextField { extra = " text=\"\(field.text ?? "")\"" }
        let hidden = view.isHidden ? " hidden" : ""
        out += "\(pad)[\(path)] \(type(of: view)) frame=\(view.frame)\(extra)\(hidden)\n"
        guard depth < maxDepth else {
            if !view.subviews.isEmpty { out += "\(pad)  … \(view.subviews.count) more subviews (raise maxDepth)\n" }
            return
        }
        for (index, sub) in view.subviews.enumerated() {
            let childPath = (path == "root") ? "\(index)" : "\(path)/\(index)"
            describeAddressable(view: sub, path: childPath, depth: depth + 1, maxDepth: maxDepth, into: &out)
        }
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
    static func selectorRejection(_ sel: Selector, on obj: NSObject, argCount: Int) -> String? {
        let name = NSStringFromSelector(sel)
        // 实例对象给出它的类；类对象（invoke 走类方法时）给出元类，元类上的
        // “实例方法”正是它的类方法。两种情形用同一个查询。
        guard let cls: AnyClass = object_getClass(obj),
              let method = class_getInstanceMethod(cls, sel) else {
            return nil      // 查不到签名就不拦（动态转发等），交给异常捕获兜底
        }
        let declared = Int(method_getNumberOfArguments(method)) - 2
        guard declared == argCount else {
            return "(selector \(name) takes \(declared) argument(s), got \(argCount))"
        }
        for i in 0..<declared {
            var buffer = [CChar](repeating: 0, count: 64)
            method_getArgumentType(method, UInt32(i + 2), &buffer, 64)
            let type = String(cString: buffer)
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
        return nil
    }

    /// `@`（id）、`@?`（block）、`@"NSString"`（带类名）、`#`（Class）都算对象。
    private static func isObjectEncoding(_ type: String) -> Bool {
        type.hasPrefix("@") || type == "#"
    }

    static func performSelector(_ sel: Selector, on obj: NSObject, args: [Any]) -> Any? {
        switch args.count {
        case 0:
            return obj.perform(sel)?.takeUnretainedValue()
        case 1:
            return obj.perform(sel, with: args[0])?.takeUnretainedValue()
        default:
            return obj.perform(sel, with: args[0], with: args[1])?.takeUnretainedValue()
        }
    }

    static func describe(viewController vc: UIViewController, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        out += "\(pad)- \(type(of: vc)) title=\(vc.title ?? "nil")\n"
        for child in vc.children {
            describe(viewController: child, indent: indent + 1, into: &out)
        }
        if let presented = vc.presentedViewController {
            out += "\(pad)  (presented)\n"
            describe(viewController: presented, indent: indent + 1, into: &out)
        }
    }

    static func describe(view: UIView, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        var extra = ""
        if let label = view as? UILabel { extra = " text=\"\(label.text ?? "")\"" }
        else if let button = view as? UIButton { extra = " title=\"\(button.title(for: .normal) ?? "")\"" }
        else if let field = view as? UITextField { extra = " text=\"\(field.text ?? "")\" placeholder=\"\(field.placeholder ?? "")\"" }
        let hidden = view.isHidden ? " hidden" : ""
        out += "\(pad)• \(type(of: view)) frame=\(view.frame)\(extra)\(hidden)\n"
        for sub in view.subviews {
            describe(view: sub, indent: indent + 1, into: &out)
        }
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
    static func isAnchor(_ view: UIView) -> Bool {
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
    static func stats(of view: UIView) -> SubtreeStats {
        var s = SubtreeStats()
        s.views = 1
        if view is UIControl { s.controls += 1 }
        if view is UIScrollView { s.scrolls += 1 }
        if view is UIImageView { s.images += 1 }
        if let label = view as? UILabel, label.text?.isEmpty == false { s.labels += 1 }
        if isAnchor(view) { s.anchors += 1 }
        for sub in view.subviews {
            let c = stats(of: sub)
            s.views += c.views; s.labels += c.labels; s.controls += c.controls
            s.scrolls += c.scrolls; s.images += c.images; s.anchors += c.anchors
            s.depth = max(s.depth, c.depth + 1)
        }
        return s
    }

    static func clip(_ text: String, _ max: Int = Summary.textPreview) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }

    /// 一行里跟在类名后面的可辨识信息：文本、占位符、a11y、异常状态。
    @MainActor
    static func inlineLabel(of view: UIView) -> String {
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
    static func addressablePath(of view: UIView) -> String? {
        var indices: [Int] = []
        var node = view
        while let parent = node.superview {
            guard let index = parent.subviews.firstIndex(of: node) else { return nil }
            indices.append(index)
            node = parent
        }
        guard let window = node as? UIWindow,
              let windowIndex = allWindows().firstIndex(of: window) else { return nil }
        let tail = indices.reversed().map(String.init).joined(separator: "/")
        return tail.isEmpty ? "W\(windowIndex):root" : "W\(windowIndex):\(tail)"
    }
    /// VC 骨架：页面栈才是 agent 真正在问的「app 现在有哪些页面」。
    /// 关键约束：`isViewLoaded == false` 的 VC 绝不碰它的 `view` —— 内省不该反过来触发 loadView。
    @MainActor
    static func describeVCSkeleton(_ vc: UIViewController, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        var line = "\(pad)- \(type(of: vc))"
        if let title = vc.title, !title.isEmpty { line += " title=\"\(clip(title))\"" }
        guard vc.isViewLoaded else {
            out += line + "  (view 未加载)\n"
            return
        }
        if let path = addressablePath(of: vc.view) { line += "  view=[\(path)]" }
        out += line + "\n"

        if let nav = vc as? UINavigationController {
            let top = nav.topViewController.map { "\(type(of: $0))" } ?? "nil"
            out += "\(pad)  页面栈 \(nav.viewControllers.count) 层，栈顶 = \(top)\n"
            for child in nav.viewControllers {
                describeVCSkeleton(child, indent: indent + 2, into: &out)
            }
        } else if let tab = vc as? UITabBarController {
            let all = tab.viewControllers ?? []
            out += "\(pad)  \(all.count) 个 tab，当前 = \(tab.selectedIndex)\n"
            for (index, child) in all.enumerated() {
                out += "\(pad)  [tab \(index)\(index == tab.selectedIndex ? " ← 可见" : "")]\n"
                describeVCSkeleton(child, indent: indent + 2, into: &out)
            }
        } else {
            for child in vc.children {
                describeVCSkeleton(child, indent: indent + 1, into: &out)
            }
        }
        if let presented = vc.presentedViewController {
            out += "\(pad)  present 出 ↓\n"
            describeVCSkeleton(presented, indent: indent + 1, into: &out)
        }
    }

    /// 只列锚点：非锚点直接穿透（不占行但路径继续累积），
    /// 子树太大或已到深度上限就折叠成统计 + 钻取 path。
    @MainActor
    static func emitAnchors(of view: UIView, path: String, anchorDepth: Int,
                            indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        var shown = 0
        var collapsedViews = 0

        for (index, sub) in view.subviews.enumerated() {
            let subPath = path.hasSuffix(":") ? "\(path)\(index)" : "\(path)/\(index)"
            let subStats = stats(of: sub)

            guard isAnchor(sub) else {
                // 包装层 / 无信息量的容器：穿透，路径不断
                if subStats.anchors > 0 {
                    emitAnchors(of: sub, path: subPath, anchorDepth: anchorDepth,
                                indent: indent, into: &out)
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

            var line = "\(pad)• \(type(of: sub))\(inlineLabel(of: sub)) [\(subPath)]"
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
                            indent: indent + 1, into: &out)
            }
        }

        if collapsedViews > 0 {
            out += "\(pad)… 另有 \(collapsedViews) 个无文本/无交互的视图（已省略）\n"
        }
    }

    @MainActor
    static func hierarchySummary() -> String {
        let windows = allWindows()
        guard !windows.isEmpty else { return "(no windows)" }
        var out = "UI 摘要 · 只列关键节点。⊞ = 已折叠子树，用 view_tree(path:\"…\") 展开\n"
        for (index, window) in windows.enumerated() {
            let total = stats(of: window)
            out += "\n[W\(index)] \(type(of: window)) level=\(window.windowLevel.rawValue)"
            out += String(format: " %.0f×%.0f", window.bounds.width, window.bounds.height)
            out += window.isKeyWindow ? " [key]" : ""
            out += window.isHidden ? " [hidden]" : ""
            out += " · 共 \(total.views) 视图 / depth \(total.depth)\n"
            if let root = window.rootViewController {
                out += "  页面：\n"
                describeVCSkeleton(root, indent: 2, into: &out)
            }
            out += "  视图锚点：\n"
            emitAnchors(of: window, path: "W\(index):", anchorDepth: 0, indent: 2, into: &out)
        }
        out += "\n钻取：view_tree(path:\"W0:0/1\") 展开子树 · view_info(path:…) 看单个视图 · "
        out += "ui_hierarchy(detail:\"full\") 拿全量（体积大，慎用）\n"
        return out
    }
}
#endif
