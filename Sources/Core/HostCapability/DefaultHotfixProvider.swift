//
//  DefaultHotfixProvider.swift
//  AppAgent — 宿主能力层
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
        let context: HostInspectionContext

        func isAccessible(in requested: HostInspectionContext) -> Bool {
            (requested.scope == .all || requested.scope == context.scope)
                && requested.sceneIdentifier == context.sceneIdentifier
        }
    }

    private let lock = ReadersWriterLock()
    private var slots: [String: Slot] = [:]
    private var order: [String] = []

    public init() {}

    // MARK: - HotfixProvider

    public func apply(name: String, javascript: String, applyMode: String, summary: String, context: HostInspectionContext = .init()) async -> HotfixApplyResult {
        guard let context = await Self.boundContext(context), !Task.isCancelled else {
            return HotfixApplyResult(success: false, applyMode: applyMode, message: "No unambiguous active scene for this patch.", needsRestart: false)
        }
        let accepted = lock.writeSync { () -> Bool in
            if let existing = slots[name], !existing.isAccessible(in: context) { return false }
            if slots[name] == nil { order.append(name) }
            slots[name] = Slot(javascript: javascript, enabled: true, summary: summary, applyMode: applyMode, context: context)
            return true
        }
        guard accepted, !Task.isCancelled else {
            return HotfixApplyResult(success: false, applyMode: applyMode, message: "Patch unavailable in this scope.", needsRestart: false)
        }
        let output = await Self.evaluate(javascript, inspection: context)
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

    public func setEnabled(name: String, enabled: Bool, context: HostInspectionContext = .init()) async -> Bool {
        guard let context = await Self.boundContext(context), !Task.isCancelled else { return false }
        // 「槽位不存在」和「关掉了」必须分开报。原来两种都走 `script == nil`
        // 那条路、再 `return slots[name] != nil || !enabled`，于是 toggle 一个
        // 不存在的补丁名也会报成功（`!enabled` 恒真），模型据此以为改生效了；
        // 而且那次 `slots[name]` 还是在锁外读的。
        enum Outcome { case missing, disabled, reenable(Slot) }
        let outcome: Outcome = lock.writeSync {
            guard var slot = slots[name], slot.isAccessible(in: context) else { return .missing }
            slot.enabled = enabled
            slots[name] = slot
            return enabled ? .reenable(slot) : .disabled
        }
        switch outcome {
        case .missing:
            return false
        case .disabled:
            return true
        case .reenable(let slot):
            // 重新开启 = 重新 eval 一遍，JS 报错就算没开成功。
            guard !Task.isCancelled else { return false }
            return !(await Self.evaluate(slot.javascript, inspection: slot.context)).hasPrefix("JS error")
        }
    }

    public func list(context: HostInspectionContext = .init()) async -> [HotfixPatchInfo] {
        guard let context = await Self.boundContext(context), !Task.isCancelled else { return [] }
        return lock.read {
            order.compactMap { name in
                guard let slot = slots[name], slot.isAccessible(in: context) else { return nil }
                return HotfixPatchInfo(
                    name: name, enabled: slot.enabled, summary: slot.summary, applyMode: slot.applyMode
                )
            }
        }
    }

    public func remove(name: String, context: HostInspectionContext = .init()) async -> Bool {
        guard let context = await Self.boundContext(context), !Task.isCancelled else { return false }
        return lock.writeSync {
            guard let slot = slots[name], slot.isAccessible(in: context) else { return false }
            slots.removeValue(forKey: name)
            order.removeAll { $0 == name }
            return true
        }
    }

    // MARK: - JS 执行 + 运行时桥

    /// A stored patch keeps its original scene even when the caller did not bind one.
    /// Explicit identifiers are checked by each UI bridge access, not by pure JS evaluation.
    @MainActor
    private static func boundContext(_ context: HostInspectionContext) -> HostInspectionContext? {
        if context.sceneIdentifier != nil { return context }
        guard let scene = try? HostInspectionUIKit.activeScene(context: context) else { return nil }
        return HostInspectionContext(scope: context.scope, sceneIdentifier: scene.session.persistentIdentifier)
    }

    /// 在主线程新建 JSContext、注入 `appagent` 桥并 eval 脚本，返回结果或错误描述。
    /// `root` permits detached-tree tests without UIWindow; production calls use scene lookup.
    @MainActor
    static func evaluate(_ script: String, inspection: HostInspectionContext = .init(), root: UIView? = nil) -> String {
        guard !Task.isCancelled else { return "JS error: cancelled" }
        guard let context = JSContext() else { return "JS error: cannot create JSContext" }
        var thrown: String?
        // Per evaluation, not per slot. Ignoring/catching the bridge result cannot clear this.
        var bridgeFailure: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown"
        }
        installBridge(into: context, inspection: inspection, root: root) { message in
            if bridgeFailure == nil { bridgeFailure = message }
            return message
        }
        let value = context.evaluateScript(script)
        // toString can itself execute JS (and call the bridge), so check failures afterwards.
        let output = value?.toString() ?? "(void)"
        if let bridgeFailure { return "JS error: bridge: \(bridgeFailure)" }
        if let thrown = thrown { return "JS error: \(thrown)" }
        return output
    }

    /// `appagent.*`：视图树 / 视图信息 / 改视图 / 视图反射调用 / KVC 读写 / 类反射调用 / 日志。
    @MainActor
    private static func installBridge(
        into context: JSContext, inspection: HostInspectionContext, root: UIView?,
        reject: @escaping (String) -> String
    ) {
        let bridge = NSMutableDictionary()
        let resolveView: (String) -> UIView? = { path in
            if let root {
                return DefaultRuntimeInspectProvider.view(atPath: path, root: root, context: inspection)
            }
            return DefaultRuntimeInspectProvider.view(atPath: path, context: inspection)
        }

        let uiTree: @convention(block) (Int) -> String = { maxDepth in
            guard let window = root ?? DefaultRuntimeInspectProvider.keyWindow(context: inspection) else {
                return reject("(no window in scope)")
            }
            var out = ""
            DefaultRuntimeInspectProvider.describeAddressable(
                view: window, path: "root", depth: 0, maxDepth: max(1, maxDepth), context: inspection, into: &out
            )
            return out
        }
        let uiInfo: @convention(block) (String) -> String = { path in
            guard let view = resolveView(path) else {
                return reject("(no view at path '\(path)' in scope)")
            }
            return DefaultRuntimeInspectProvider.describeState(of: view, path: path, context: inspection)
        }
        let uiSet: @convention(block) (String, String, String) -> String = { path, key, value in
            guard let view = resolveView(path) else {
                return reject("(no view at path '\(path)' in scope)")
            }
            let result = DefaultRuntimeInspectProvider.applyValue(to: view, key: key, value: value, context: inspection)
            // Share the runtime mutation success contract; do not maintain a failure-prefix list.
            return result.hasPrefix("OK.") ? result : reject(result)
        }
        let uiInvoke: @convention(block) (String, String, String) -> String = { path, selector, argsJSON in
            guard let view = resolveView(path) else {
                return reject("(no view at path '\(path)' in scope)")
            }
            let sel = NSSelectorFromString(selector)
            guard view.responds(to: sel) else {
                return reject("(selector \(selector) not found on \(type(of: view)))")
            }
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [Any] ?? []
            // JS 桥和 view_invoke 共用同一条反射路径，也得过同一道类型闸门
            // （见 DefaultRuntimeInspectProvider.selectorRejection：原始类型的参数会被
            // 当指针写进去、原始类型的返回值按对象解引用会崩）。
            if let rejection = DefaultRuntimeInspectProvider.selectorRejection(
                sel, on: view, argCount: args.count, context: inspection
            ) { return reject(rejection) }
            do {
                let result = try ObjCExceptionCatcher.performReturning {
                    DefaultRuntimeInspectProvider.performSelector(sel, on: view, args: args, context: inspection)
                }
                return try DefaultRuntimeInspectProvider.inspectedDescription(of: result, context: inspection)
            } catch {
                return reject("Invoke failed: result unavailable in this scope or selector raised an exception.")
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
