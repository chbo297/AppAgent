//
//  RuntimeInspectTool.swift
//  AppAgent — 宿主能力层
//
//  把宿主 app 的运行时内省能力封装为一个多操作工具，供 app agent 灵活调用。
//  仅当 RuntimeInspectProvider 注入且能力开启时才应注册本工具。
//

import Foundation

public struct RuntimeInspectTool: ToolProtocol {
    public let name = "app_runtime_inspect"
    public let description = """
        Inspect and modify the host app runtime. Choose an 'op':
        - 'ui_hierarchy': the map of what is on screen. Default 'detail'="summary" gives every window, \
        the view-controller/page stack, and only the meaningful views (text, controls, host classes) — \
        UIKit wrapper layers are skipped and large subtrees collapse to "⊞ N views" plus the path to expand. \
        Start here, then drill in. 'detail'="full" dumps everything and is large — avoid unless you truly need it.
        - 'view_tree': expand one subtree. Pass the 'path' from a collapsed "⊞" node; omit 'path' for the key \
        window root. Optional 'maxDepth' (default 12). Paths look like "0/2/1" (key window) or "W1:0/2/1" (window #1).
        - 'view_info': dump one view's live state (class, frame, colors, text, subview count) at 'path'
        - 'view_set': change one view at 'path': 'key' = frame|bounds|center|alpha|hidden|cornerRadius|backgroundColor|text \
        (anything else falls back to KVC) with 'value' ("x,y,w,h" for rects, "#RRGGBB" for colors). \
        The result reports the previous value — write that back to the same key to undo the change.
        - 'view_invoke': call 'selector' on the view at 'path' with 'argumentsJSON' \
        (e.g. removeFromSuperview / setNeedsLayout — structural changes). Reflection can only pass and \
        return **objects**: selectors taking or returning primitives (setTag:, isHidden, frame) are \
        rejected — use 'view_set' / 'property_set' / 'view_info' for those.
        - 'class_list': list runtime classes. 'filter' is REQUIRED (the process has tens of thousands) — \
        pass the app's class prefix, e.g. "BM"
        - 'method_list': list methods of 'class' (short Swift names work, e.g. "MyViewController")
        - 'property_list': list properties/ivars of 'class'
        - 'property_value': read a 'keyPath' value (optional 'class', defaults to top page)
        - 'property_set': write a 'keyPath' value via KVC using 'value' (optional 'class', defaults to top page)
        - 'invoke': call 'selector' on 'class' with 'argumentsJSON' (a JSON array). Powerful — use carefully. \
        Object-only, same as 'view_invoke'.
        Typical flow for UI surgery: 'ui_hierarchy' (summary) → 'view_tree' on the interesting path → \
        'view_info' → 'view_set' / 'view_invoke'.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["ui_hierarchy", "view_tree", "view_info", "view_set", "view_invoke",
                                       "class_list", "method_list", "property_list", "property_value", "property_set", "invoke"]),
            "detail": .string(description: "For ui_hierarchy: 'summary' (default, cheap) or 'full' (everything, large).",
                              enumValues: ["summary", "full"],
                              defaultValue: .string("summary")),
            "_why": .string(description: "One sentence on why this is needed. Shown to the user when they are asked to approve; supply it for view_invoke / invoke."),
            "class": .string(description: "Class name for method_list/property_list/property_value/property_set/invoke."),
            "filter": .string(description: "Substring filter for class_list. Required."),
            "path": .string(description: "View path. \"0/2/1\" is relative to the key window, \"W1:0/2/1\" targets window #1, \"root\" is the window itself. Used by view_tree/view_info/view_set/view_invoke."),
            "key": .string(description: "Property name for view_set (frame/alpha/backgroundColor/text/...)."),
            "maxDepth": .integer(description: "Depth limit for view_tree (default 12).", minimum: 1, maximum: 40),
            "keyPath": .string(description: "Key path for property_value/property_set."),
            "value": .string(description: "New value (string) for property_set / view_set."),
            "selector": .string(description: "Selector for invoke/view_invoke."),
            "argumentsJSON": .string(description: "JSON array string of arguments for invoke/view_invoke.")
        ],
        required: ["op"]
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    /// 看和改在这个工具里差别巨大：`ui_hierarchy` 是纯读，`view_set` 会直接改掉线上
    /// 界面，`invoke` 能反射调任意 selector。用同一个静态级别的后果我自己撞过一次
    /// （自检把 demo 的 tab bar 改成了半透明蓝块，全程没有任何拦截）。
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "ui_hierarchy", "view_tree", "view_info",
             "class_list", "method_list", "property_list", "property_value":
            return .safe
        case "view_set", "property_set":
            return .moderate
        case "view_invoke", "invoke":
            return .sensitive
        default:
            return .moderate
        }
    }

    private let provider: RuntimeInspectProvider

    public init(provider: RuntimeInspectProvider) {
        self.provider = provider
    }

    /// The provider reports failures as sentinel strings. Surface those as tool
    /// errors so the model cannot mistake "(class not found: X)" for an answer.
    private func output(_ text: String) -> Tool.Output {
        let failurePrefixes = [
            "(class not found", "(no view at path", "(selector ", "(no target)",
            "(no windows)", "(no key window)", "(no target object for KVC",
            "Invoke failed:", "Failed to set ", "Failed to read "
        ]
        return failurePrefixes.contains(where: { text.hasPrefix($0) }) ? .error(text) : .text(text)
    }

    /// 写类操作（`view_set` / `property_set`）的判定反过来做：**成功必须以 `OK.` 开头**。
    /// 靠「失败前缀清单」认失败太脆——provider 的失败文案有一堆形态
    /// （`Invalid rect '…'`、`Invalid alpha '…'`、`UIView has no text/title to set.`…），
    /// 漏一个就会把一次没生效的修改当成成功交给模型。
    private func mutationOutput(_ text: String) -> Tool.Output {
        text.hasPrefix("OK.") ? .text(text) : .error(text)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let className = arguments["class"]?.stringValue
        switch op {
        case "ui_hierarchy":
            // 默认只给摘要。全量在真实 app 里几十 KB，一次就能把上下文吃光，
            // 需要细节应该顺着摘要里的 path 走 view_tree / view_info 二次调用。
            let detail = arguments["detail"]?.stringValue ?? "summary"
            switch detail {
            case "summary":
                return output(await provider.uiHierarchySummary())
            case "full":
                return output(await provider.uiHierarchy())
            default:
                return .error("Unknown detail '\(detail)'. Use 'summary' (default) or 'full'.")
            }
        case "view_tree":
            let depth = arguments["maxDepth"]?.numberValue.map { Int($0) } ?? 12
            let path = arguments["path"]?.stringValue ?? ""
            return output(await provider.viewSubtree(path: path, maxDepth: depth))
        case "view_info":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_info") }
            return output(await provider.viewInfo(path: path))
        case "view_set":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_set") }
            guard let key = arguments["key"]?.stringValue else { return .error("'key' is required for view_set") }
            guard let value = arguments["value"]?.stringValue else { return .error("'value' is required for view_set") }
            return mutationOutput(await provider.setViewValue(path: path, key: key, value: value))
        case "view_invoke":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_invoke") }
            guard let selector = arguments["selector"]?.stringValue else { return .error("'selector' is required for view_invoke") }
            let argsJSON = arguments["argumentsJSON"]?.stringValue ?? "[]"
            return output(await provider.invokeOnView(path: path, selector: selector, argumentsJSON: argsJSON))

        case "class_list":
            // 无过滤时进程内 ObjC 类是万级规模，直接返回等于烧掉整个上下文。
            let filter = arguments["filter"]?.stringValue
            guard let filter, !filter.isEmpty else {
                let total = (await provider.classList(matching: nil)).count
                return .error("'filter' is required for class_list — the process has \(total) classes. "
                              + "Pass a substring such as the app's class prefix.")
            }
            let list = await provider.classList(matching: filter)
            return .text(list.isEmpty ? "(no class matches '\(filter)')" : list.joined(separator: "\n"))
        case "method_list":
            guard let className else { return .error("'class' is required for method_list") }
            return output((await provider.methodList(ofClass: className)).joined(separator: "\n"))
        case "property_list":
            guard let className else { return .error("'class' is required for property_list") }
            return output((await provider.propertyList(ofClass: className)).joined(separator: "\n"))
        case "property_value":
            guard let keyPath = arguments["keyPath"]?.stringValue else {
                return .error("'keyPath' is required for property_value")
            }
            let value = await provider.propertyValue(keyPath: keyPath, ofClass: className)
            guard let value else { return .text("(nil)") }
            return output(value)
        case "property_set":
            guard let keyPath = arguments["keyPath"]?.stringValue else {
                return .error("'keyPath' is required for property_set")
            }
            guard let value = arguments["value"]?.stringValue else {
                return .error("'value' is required for property_set")
            }
            return mutationOutput(await provider.setPropertyValue(keyPath: keyPath, value: value, ofClass: className))
        case "invoke":
            guard let className, let selector = arguments["selector"]?.stringValue else {
                return .error("'class' and 'selector' are required for invoke")
            }
            let argsJSON = arguments["argumentsJSON"]?.stringValue ?? "[]"
            return output(await provider.invoke(className: className, selector: selector, argumentsJSON: argsJSON))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
