//
//  DefaultRuntimeInspectProvider.swift
//  AppAgent — Liji 集成层
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
            guard let window = Self.keyWindow() else { return "(no key window)" }
            var out = "Window: \(type(of: window)) frame=\(window.frame)\n"
            if let root = window.rootViewController {
                out += "RootViewController:\n"
                Self.describe(viewController: root, indent: 1, into: &out)
            }
            out += "\nView tree:\n"
            Self.describe(view: window, indent: 0, into: &out)
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
        guard let cls: AnyClass = NSClassFromString(className) else { return ["(class not found: \(className))"] }
        var result: [String] = []
        result.append(contentsOf: Self.methods(of: cls, isClassMethod: false))
        if let meta: AnyClass = object_getClass(cls) {
            result.append(contentsOf: Self.methods(of: meta, isClassMethod: true))
        }
        return result.isEmpty ? ["(no methods)"] : result
    }

    // MARK: - Properties / ivars

    public func propertyList(ofClass className: String) async -> [String] {
        guard let cls: AnyClass = NSClassFromString(className) else { return ["(class not found: \(className))"] }
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
            guard NSClassFromString(className) != nil else {
                return "(class not found: \(className))"
            }
            let sel = NSSelectorFromString(selector)
            // 优先对栈顶页面（若为该类实例）调用实例方法；否则当作类方法调用。
            let target: NSObject?
            if let top = Self.kvcTarget(className: className) as? NSObject, top.responds(to: sel) {
                target = top
            } else if let clsObj = NSClassFromString(className) as AnyObject as? NSObject, clsObj.responds(to: sel) {
                target = clsObj
            } else {
                return "(selector \(selector) not found on \(className) instance/class)"
            }
            guard let obj = target else { return "(no target)" }
            let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [Any] ?? []
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

    // MARK: - Helpers

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
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
        if let top = topViewController(), NSStringFromClass(type(of: top)) == className { return top }
        return NSClassFromString(className) as AnyObject?
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

    /// 对单个视图应用一次属性修改（view_set 与 JS 桥共用；已在主线程）。
    @MainActor
    static func applyValue(to view: UIView, key: String, value: String) -> String {
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
                return "OK (KVC). \(key) = \(readBack)"
            } catch {
                return "Failed to set \(key): \(error.localizedDescription)"
            }
        }
    }

    /// 解析路径下的视图：`"root"`（或空）为 keyWindow，`"0/2"` 为 window.subviews[0].subviews[2]。
    /// 也支持从任意根视图出发（测试用）。
    static func view(atPath path: String, root: UIView? = nil) -> UIView? {
        guard let start = root ?? keyWindow() else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "root" { return start }
        var current = start
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
}
#endif
