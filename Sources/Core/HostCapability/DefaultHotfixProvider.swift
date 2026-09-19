//
//  DefaultHotfixProvider.swift
//  AppAgent — Liji 集成层
//
//  基于 JavaScriptCore 的通用 HotfixProvider 默认实现：把一段 JS 当作「运行时补丁」执行，
//  JS 里通过 `appagent` 桥直接读改运行时（视图树寻址、改 frame/颜色/文本、反射调用、KVC 读写）。
//  补丁按名字存放在槽位里，可开关、可列举、可移除；开关后重新 eval 已启用的槽位。
//  能力很强，宿主需显式注册 HotfixTool 才会暴露给模型。
//

#if canImport(UIKit) && canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import UIKit

public final class DefaultHotfixProvider: HotfixProvider, @unchecked Sendable {

    private struct Slot {
        var javascript: String
        var enabled: Bool
        var summary: String
        var applyMode: String
    }

    private let lock = ReadersWriterLock()
    private var slots: [String: Slot] = [:]
    private var order: [String] = []

    public init() {}

    // MARK: - HotfixProvider

    public func apply(name: String, javascript: String, applyMode: String, summary: String) async -> HotfixApplyResult {
        lock.writeSync {
            if slots[name] == nil { order.append(name) }
            slots[name] = Slot(javascript: javascript, enabled: true, summary: summary, applyMode: applyMode)
        }
        let output = await Self.evaluate(javascript)
        AppAgentDebugLog.shared.record(
            output.hasPrefix("JS error") ? .failure : .info,
            message: "hotfix '\(name)' \(output)"
        )
        return HotfixApplyResult(
            success: !output.hasPrefix("JS error"),
            applyMode: applyMode,
            message: output,
            needsRestart: applyMode == "restart"
        )
    }

    public func setEnabled(name: String, enabled: Bool) async -> Bool {
        // 「槽位不存在」和「关掉了」必须分开报。原来两种都走 `script == nil`
        // 那条路、再 `return slots[name] != nil || !enabled`，于是 toggle 一个
        // 不存在的补丁名也会报成功（`!enabled` 恒真），模型据此以为改生效了；
        // 而且那次 `slots[name]` 还是在锁外读的。
        enum Outcome { case missing, disabled, reenable(String) }
        let outcome: Outcome = lock.writeSync {
            guard var slot = slots[name] else { return .missing }
            slot.enabled = enabled
            slots[name] = slot
            return enabled ? .reenable(slot.javascript) : .disabled
        }
        switch outcome {
        case .missing:
            return false
        case .disabled:
            return true
        case .reenable(let script):
            // 重新开启 = 重新 eval 一遍，JS 报错就算没开成功。
            return !(await Self.evaluate(script)).hasPrefix("JS error")
        }
    }

    public func list() async -> [HotfixPatchInfo] {
        lock.read {
            order.compactMap { name in
                guard let slot = slots[name] else { return nil }
                return HotfixPatchInfo(
                    name: name, enabled: slot.enabled, summary: slot.summary, applyMode: slot.applyMode
                )
            }
        }
    }

    public func remove(name: String) async -> Bool {
        lock.writeSync {
            guard slots.removeValue(forKey: name) != nil else { return false }
            order.removeAll { $0 == name }
            return true
        }
    }

    // MARK: - JS 执行 + 运行时桥

    /// 在主线程新建 JSContext、注入 `appagent` 桥并 eval 脚本，返回结果或错误描述。
    @MainActor
    static func evaluate(_ script: String) -> String {
        guard let context = JSContext() else { return "JS error: cannot create JSContext" }
        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown"
        }
        installBridge(into: context)
        let value = context.evaluateScript(script)
        if let thrown = thrown { return "JS error: \(thrown)" }
        return value?.toString() ?? "(void)"
    }

    /// `appagent.*`：视图树 / 视图信息 / 改视图 / 视图反射调用 / KVC 读写 / 类反射调用 / 日志。
    @MainActor
    private static func installBridge(into context: JSContext) {
        let bridge = NSMutableDictionary()

        let uiTree: @convention(block) (Int) -> String = { maxDepth in
            guard let window = DefaultRuntimeInspectProvider.keyWindow() else { return "(no key window)" }
            var out = ""
            DefaultRuntimeInspectProvider.describeAddressable(
                view: window, path: "root", depth: 0, maxDepth: max(1, maxDepth), into: &out
            )
            return out
        }
        let uiInfo: @convention(block) (String) -> String = { path in
            guard let view = DefaultRuntimeInspectProvider.view(atPath: path) else {
                return "(no view at path '\(path)')"
            }
            return DefaultRuntimeInspectProvider.describeState(of: view, path: path)
        }
        let uiSet: @convention(block) (String, String, String) -> String = { path, key, value in
            guard let view = DefaultRuntimeInspectProvider.view(atPath: path) else {
                return "(no view at path '\(path)')"
            }
            return DefaultRuntimeInspectProvider.applyValue(to: view, key: key, value: value)
        }
        let uiInvoke: @convention(block) (String, String, String) -> String = { path, selector, argsJSON in
            guard let view = DefaultRuntimeInspectProvider.view(atPath: path) else {
                return "(no view at path '\(path)')"
            }
            let sel = NSSelectorFromString(selector)
            guard view.responds(to: sel) else { return "(selector \(selector) not found on \(type(of: view)))" }
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [Any] ?? []
            // JS 桥和 view_invoke 共用同一条反射路径，也得过同一道类型闸门
            // （见 DefaultRuntimeInspectProvider.selectorRejection：原始类型的参数会被
            // 当指针写进去、原始类型的返回值按对象解引用会崩）。
            if let rejection = DefaultRuntimeInspectProvider.selectorRejection(
                sel, on: view, argCount: args.count
            ) { return rejection }
            do {
                let result = try ObjCExceptionCatcher.performReturning {
                    DefaultRuntimeInspectProvider.performSelector(sel, on: view, args: args)
                }
                return result.map { "\($0)" } ?? "(void/nil)"
            } catch {
                return "Invoke failed: \(error.localizedDescription)"
            }
        }
        let log: @convention(block) (String) -> Void = { message in
            Logger.info("Hotfix.JS", message)
            AppAgentDebugLog.shared.record(.info, message: "JS: \(message)")
        }

        bridge["uiTree"] = uiTree
        bridge["uiInfo"] = uiInfo
        bridge["uiSet"] = uiSet
        bridge["uiInvoke"] = uiInvoke
        bridge["log"] = log
        context.setObject(bridge, forKeyedSubscript: "appagent" as NSString)
    }

}
#endif
