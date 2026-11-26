//
//  DefaultHotfixProvider.swift
//  AppAgent — 宿主能力层
//
//  基于 JavaScriptCore 的通用 HotfixProvider 默认实现：把一段 JS 当作「运行时补丁」执行，
//  JS 里通过 `appagent` 桥直接读改运行时（视图树寻址、改 frame/颜色/文本、反射调用、KVC 读写）。
//  补丁按名字存放在槽位里，可开关、可列举、可移除；开关后重新 eval 已启用的槽位。
//  桥里的 hook / hookClass 拦截 ObjC 方法（AppAgentMethodHook），装上的拦截归槽位所有：
//  槽位关闭、移除、重新 apply 时全部恢复原实现。
//  宿主只需要显式选择目标范围和开关，是否能使用由 AppAgent 的安全边界统一控制。
//

#if canImport(UIKit) && canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import UIKit
#if canImport(AppAgentObjCSupport)
import AppAgentObjCSupport
#endif

/// `actor` 而不是「加锁的 class」：槽位表（`slots` / `order`）是真可变状态，而 `HotfixProvider`
/// 的四个要求全是 `async`、调用方本来就带 `await`，所以隔离域天然装得下，不必再手写锁。
/// 手写锁在这里还是个隐患：`apply` / `setEnabled` 里「改槽位」和「eval JS（要跳主线程 await）」
/// 必须分成两段，锁只能保护前一段，剩下的顺序全靠人守；actor 把「谁能同时改槽位」这件事
/// 交给编译器，`@unchecked Sendable` 也就不用要了。
public actor DefaultHotfixProvider: HotfixProvider {

    private struct Slot: Sendable {
        var javascript: String
        var enabled: Bool
        var summary: String
        var applyMode: String
        let context: HostInspectionContext
        /// 当前这次 eval 装上的方法拦截；换掉槽位或关掉时先恢复。
        var hooks: HotfixHookSet

        /// 同步入口装的槽位不绑 scene（拦截对整个进程生效），任何 scene 都能开关。
        func isAccessible(in requested: HostInspectionContext) -> Bool {
            (requested.scope == .all || requested.scope == context.scope)
                && (context.sceneIdentifier == nil || requested.sceneIdentifier == context.sceneIdentifier)
        }
    }

    /// `applySynchronously` 在主线程同步执行，进不了 actor；装好的槽位先放这里，
    /// actor 的每个入口先收进 `slots`，之后的开关 / 移除都看得到它。
    @MainActor
    private final class SyncInbox {
        var pending: [(name: String, slot: Slot)] = []

        nonisolated init() {}

        func take() -> [(name: String, slot: Slot)] {
            let taken = pending
            pending = []
            return taken
        }
    }

    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    private nonisolated let syncInbox = SyncInbox()

    public init() {}

    // MARK: - HotfixProvider

    public func apply(name: String, javascript: String, applyMode: String, summary: String, context: HostInspectionContext = .init()) async -> HotfixApplyResult {
        await adoptSyncSlots()
        guard let context = await Self.boundContext(context), !Task.isCancelled else {
            return HotfixApplyResult(success: false, applyMode: applyMode, message: "No unambiguous active scene for this patch.", needsRestart: false)
        }
        // 槽位读写在 actor 的隔离域里，中间没有挂起点，所以「查得到 → 判范围 → 落库」是一段。
        if let existing = slots[name] {
            guard existing.isAccessible(in: context) else {
                return HotfixApplyResult(success: false, applyMode: applyMode, message: "Patch unavailable in this scope.", needsRestart: false)
            }
            existing.hooks.removeAll()
        }
        if slots[name] == nil {
            order.append(name)
        }
        let hooks = HotfixHookSet()
        slots[name] = Slot(javascript: javascript, enabled: true, summary: summary, applyMode: applyMode,
                           context: context, hooks: hooks)
        guard !Task.isCancelled else {
            return HotfixApplyResult(success: false, applyMode: applyMode, message: "Patch unavailable in this scope.", needsRestart: false)
        }
        let output = await Self.evaluate(javascript, inspection: context, hooks: hooks)
        dropIfReplaced(hooks, name: name)
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
        await adoptSyncSlots()
        guard let context = await Self.boundContext(context), !Task.isCancelled else { return false }
        // 「槽位不存在」和「关掉了」必须分开报。原来两种都走 `script == nil`
        // 那条路、再 `return slots[name] != nil || !enabled`，于是 toggle 一个
        // 不存在的补丁名也会报成功（`!enabled` 恒真），模型据此以为改生效了。
        guard var slot = slots[name], slot.isAccessible(in: context) else { return false }
        // 关掉要恢复被拦截的方法；重新开启前也先恢复，免得同一个方法被拦两次而报错。
        slot.hooks.removeAll()
        let hooks = HotfixHookSet()
        slot.enabled = enabled
        slot.hooks = hooks
        slots[name] = slot
        guard enabled else { return true }
        // 重新开启 = 重新 eval 一遍，JS 报错就算没开成功。
        guard !Task.isCancelled else { return false }
        let output = await Self.evaluate(slot.javascript, inspection: slot.context, hooks: hooks)
        dropIfReplaced(hooks, name: name)
        return !output.hasPrefix("JS error")
    }

    public func list(context: HostInspectionContext = .init()) async -> [HotfixPatchInfo] {
        await adoptSyncSlots()
        guard let context = await Self.boundContext(context), !Task.isCancelled else { return [] }
        return order.compactMap { name in
            guard let slot = slots[name], slot.isAccessible(in: context) else { return nil }
            return HotfixPatchInfo(
                name: name, enabled: slot.enabled, summary: slot.summary, applyMode: slot.applyMode
            )
        }
    }

    public func remove(name: String, context: HostInspectionContext = .init()) async -> Bool {
        await adoptSyncSlots()
        guard let context = await Self.boundContext(context), !Task.isCancelled else { return false }
        guard let slot = slots[name], slot.isAccessible(in: context) else { return false }
        slot.hooks.removeAll()
        slots.removeValue(forKey: name)
        order.removeAll { $0 == name }
        return true
    }

    // MARK: - 同步生效

    /// 在主线程同步执行补丁，返回时拦截已经生效；不经过会话，也不要求前台 scene。什么时候调用由宿主决定
    /// （例如宿主在自己的启动流程里重放已保存的补丁）。没有窗口时 UI 桥会报错，hook / call 不受影响。
    /// 槽位不绑 scene，之后经 `list` / `setEnabled` / `remove` 照常管理。
    /// 同名槽位要先 `remove`：这里拿不到 actor 里的旧槽位，旧拦截还在时同一方法会拒绝再拦。
    @MainActor
    public func applySynchronously(name: String, javascript: String, applyMode: String, summary: String) -> HotfixApplyResult {
        // 同名的上一次同步结果还没被 actor 收走：先恢复它的拦截再装新的。
        syncInbox.pending.removeAll { item in
            guard item.name == name else {
                return false
            }
            item.slot.hooks.removeAll()
            return true
        }
        let context = HostInspectionContext()
        let hooks = HotfixHookSet()
        let output = Self.evaluate(javascript, inspection: context, hooks: hooks)
        let failed = output.hasPrefix("JS error")
        AppAgentDebugLog.shared.record(failed ? .failure : .info, message: "hotfix '\(name)' sync \(output)")
        let slot = Slot(javascript: javascript, enabled: true, summary: summary, applyMode: applyMode,
                        context: context, hooks: hooks)
        syncInbox.pending.append((name: name, slot: slot))
        return HotfixApplyResult(success: !failed, applyMode: applyMode, message: output, needsRestart: false)
    }

    private func adoptSyncSlots() async {
        for item in await syncInbox.take() {
            if let existing = slots[item.name] {
                existing.hooks.removeAll()
            } else {
                order.append(item.name)
            }
            slots[item.name] = item.slot
        }
    }

    /// eval 期间（跨了挂起点）槽位被换掉或移除时，这次装上的拦截不能留着。
    private func dropIfReplaced(_ hooks: HotfixHookSet, name: String) {
        if slots[name]?.hooks !== hooks {
            hooks.removeAll()
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
    /// 脚本装上的方法拦截记进 `hooks`；eval 失败时这次装上的拦截全部恢复，不留半个补丁。
    /// 有拦截时 JSContext 由拦截回调持有，跟着拦截一起活。
    @MainActor
    static func evaluate(
        _ script: String, inspection: HostInspectionContext = .init(), root: UIView? = nil,
        hooks: HotfixHookSet = HotfixHookSet()
    ) -> String {
        guard !Task.isCancelled else { return "JS error: cancelled" }
        guard let context = JSContext() else { return "JS error: cannot create JSContext" }
        var thrown: String?
        // Per evaluation, not per slot. Ignoring/catching the bridge result cannot clear this.
        var bridgeFailure: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown"
        }
        installBridge(into: context, inspection: inspection, root: root, hooks: hooks) { message in
            if bridgeFailure == nil { bridgeFailure = message }
            return message
        }
        let value = context.evaluateScript(script)
        // toString can itself execute JS (and call the bridge), so check failures afterwards.
        let output = value?.toString() ?? "(void)"
        hooks.finishEvaluation()
        // 之后的 JS 只会在被拦截的方法里跑，异常只能记日志。
        context.exceptionHandler = runtimeExceptionHandler()
        let result: String
        if let bridgeFailure {
            result = "JS error: bridge: \(bridgeFailure)"
        } else if let thrown = thrown {
            result = "JS error: \(thrown)"
        } else {
            result = output
        }
        if result.hasPrefix("JS error") {
            hooks.removeAll()
        }
        return result
    }

    /// `appagent.*`：视图树 / 视图信息 / 改视图 / 视图反射调用 / KVC 读写 / 类反射调用 / 方法拦截 / 日志。
    @MainActor
    private static func installBridge(
        into context: JSContext, inspection: HostInspectionContext, root: UIView?, hooks: HotfixHookSet,
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
        installHookBridge(into: bridge, hooks: hooks, reject: reject)
        context.setObject(bridge, forKeyedSubscript: "appagent" as NSString)
    }

    // MARK: - 方法拦截与反射调用桥

    /// `appagent.hook / hookClass / call / callClass / newObject`。
    /// 不放进 `@MainActor` 的 `installBridge`：被拦截的方法可能在任意线程调用，回调不能带主线程隔离；
    /// JSC 自己按 VM 加锁串行执行，这里不跳主线程（后台线程同步等主线程容易死锁）。
    /// 在后台线程触发的拦截回调里不要调 ui* 桥，UIKit 只能在主线程用。
    /// 失败抛 JS 异常；eval 期间同时计入 `reject`，让这次 apply 报失败。
    private static func installHookBridge(
        into bridge: NSMutableDictionary, hooks: HotfixHookSet, reject: @escaping (String) -> String
    ) {
        let fail: (String) -> Void = { message in
            if hooks.isEvaluating {
                _ = reject(message)
            }
            throwJS("bridge: \(message)")
        }
        let install: (Bool, String, String, String, JSValue) -> Void = { classMethod, className, selector, mode, fn in
            guard let hookMode = hookMode(mode) else {
                fail("unknown hook mode '\(mode)', expected before | after | instead")
                return
            }
            guard fn.isObject, fn.hasProperty("call") else {
                fail("hook \(className) \(selector) needs a function")
                return
            }
            do {
                let hook = try AppAgentMethodHook.install(
                    className: className, selector: selector, classMethod: classMethod,
                    mode: hookMode, handler: hookHandler(fn, mode: hookMode)
                )
                hooks.add(hook)
            } catch {
                fail(error.localizedDescription)
            }
        }
        let hook: @convention(block) (String, String, String, JSValue) -> Void = { className, selector, mode, fn in
            install(false, className, selector, mode, fn)
        }
        let hookClass: @convention(block) (String, String, String, JSValue) -> Void = { className, selector, mode, fn in
            install(true, className, selector, mode, fn)
        }
        let call: @convention(block) (JSValue, String, JSValue) -> JSValue? = { target, selector, args in
            do {
                let result = try AppAgentMethodHook.invoke(
                    target: objcValue(target), selector: selector, arguments: objcArguments(args)
                )
                return jsValue(result, in: target.context)
            } catch {
                fail(error.localizedDescription)
                return nil
            }
        }
        let callClass: @convention(block) (String, String, JSValue) -> JSValue? = { className, selector, args in
            guard let cls = NSClassFromString(className) else {
                fail("class \(className) not found")
                return nil
            }
            do {
                let result = try AppAgentMethodHook.invoke(
                    target: cls, selector: selector, arguments: objcArguments(args)
                )
                return jsValue(result, in: args.context)
            } catch {
                fail(error.localizedDescription)
                return nil
            }
        }
        let newObject: @convention(block) (String) -> JSValue? = { className in
            do {
                let object = try AppAgentMethodHook.newObject(className: className)
                return JSContext.current().flatMap { context in
                    jsValue(object, in: context)
                }
            } catch {
                fail(error.localizedDescription)
                return nil
            }
        }
        bridge["hook"] = hook
        bridge["hookClass"] = hookClass
        bridge["call"] = call
        bridge["callClass"] = callClass
        bridge["newObject"] = newObject
    }

    private static func hookMode(_ name: String) -> AppAgentMethodHookMode? {
        switch name {
        case "before":
            return .before
        case "after":
            return .after
        case "instead":
            return .instead
        default:
            return nil
        }
    }

    /// 被拦截的方法每调一次就把 `inv` 交给 JS 函数；instead 模式下函数返回值（非 undefined）即方法返回值。
    private static func hookHandler(_ fn: JSValue, mode: AppAgentMethodHookMode) -> (AppAgentHookInvocation) -> Void {
        return { invocation in
            guard let context = fn.context else {
                return
            }
            let result = fn.call(withArguments: [jsInvocation(invocation, mode: mode, in: context)])
            guard mode == .instead, let result, !result.isUndefined else {
                return
            }
            do {
                try invocation.setReturnValue(objcValue(result))
            } catch {
                logRuntimeFailure("hook return value: \(error.localizedDescription)")
            }
        }
    }

    private static func jsInvocation(
        _ invocation: AppAgentHookInvocation, mode: AppAgentMethodHookMode, in context: JSContext
    ) -> JSValue {
        let object: JSValue = JSValue(newObjectIn: context)
        let setArg: @convention(block) (Int, JSValue) -> Void = { index, value in
            guard index >= 0 else {
                throwJS("inv.setArg: index must be >= 0")
                return
            }
            do {
                try invocation.setArgument(objcValue(value), at: UInt(index))
            } catch {
                throwJS("inv.setArg: \(error.localizedDescription)")
            }
        }
        let getReturnValue: @convention(block) () -> JSValue? = {
            jsValue(invocation.returnValue, in: context)
        }
        let setReturnValue: @convention(block) (JSValue) -> Void = { value in
            do {
                try invocation.setReturnValue(objcValue(value))
            } catch {
                throwJS("inv.setReturnValue: \(error.localizedDescription)")
            }
        }
        let invokeOriginal: @convention(block) () -> JSValue? = {
            do {
                return try jsValue(invocation.invokeOriginal(), in: context)
            } catch {
                throwJS("inv.invokeOriginal: \(error.localizedDescription)")
                return nil
            }
        }
        object.setObject(jsValue(invocation.target, in: context), forKeyedSubscript: "target" as NSString)
        object.setObject(jsValue(invocation.arguments, in: context), forKeyedSubscript: "args" as NSString)
        object.setObject(setArg, forKeyedSubscript: "setArg" as NSString)
        object.setObject(getReturnValue, forKeyedSubscript: "getReturnValue" as NSString)
        object.setObject(setReturnValue, forKeyedSubscript: "setReturnValue" as NSString)
        object.setObject(invokeOriginal, forKeyedSubscript: "invokeOriginal" as NSString)
        return object
    }

    /// JS → ObjC：null / undefined 为 NSNull，包着的 ObjC 对象还原成原对象。
    private static func objcValue(_ value: JSValue) -> Any {
        if value.isUndefined || value.isNull {
            return NSNull()
        }
        return value.toObject() ?? NSNull()
    }

    private static func objcArguments(_ value: JSValue) -> [Any] {
        guard value.isArray else {
            return []
        }
        return value.toArray() ?? []
    }

    private static func jsValue(_ value: Any, in context: JSContext) -> JSValue? {
        if value is NSNull {
            return JSValue(nullIn: context)
        }
        return JSValue(object: value, in: context)
    }

    private static func throwJS(_ message: String) {
        guard let context = JSContext.current() else {
            return
        }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    private static func runtimeExceptionHandler() -> (JSContext?, JSValue?) -> Void {
        return { _, exception in
            logRuntimeFailure(exception?.toString() ?? "unknown")
        }
    }

    private static func logRuntimeFailure(_ message: String) {
        Logger.error("Hotfix.JS", "hook runtime error: \(message)")
        AppAgentDebugLog.shared.record(.failure, message: "hotfix hook runtime error: \(message)")
    }
}

/// 一个槽位一次 eval 装上的方法拦截。eval 在主线程追加，actor 上整组恢复，所以加锁。
final class HotfixHookSet: @unchecked Sendable {

    private let lock = NSLock()
    private var hooks: [AppAgentMethodHook] = []
    private var evaluating = true
    private var removed = false

    /// 还在 eval 脚本：桥的失败要计入这次 eval 的结果；之后只会在被拦截的方法里跑。
    var isEvaluating: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return evaluating
    }

    var count: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return hooks.count
    }

    func add(_ hook: AppAgentMethodHook) {
        lock.lock()
        let keep = !removed
        if keep {
            hooks.append(hook)
        }
        lock.unlock()
        // 整组已经恢复过（槽位关了），之后在拦截回调里新装的也立即恢复。
        if !keep {
            hook.remove()
        }
    }

    func finishEvaluation() {
        lock.lock()
        evaluating = false
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let installed = hooks
        hooks = []
        removed = true
        lock.unlock()
        for hook in installed.reversed() {
            hook.remove()
        }
    }
}
#endif
