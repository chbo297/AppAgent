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
