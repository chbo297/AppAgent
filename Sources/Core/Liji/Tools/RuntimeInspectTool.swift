//
//  RuntimeInspectTool.swift
//  AppAgent — Liji 集成层
//
//  把宿主 app 的运行时内省能力封装为一个多操作工具，供 app agent 灵活调用。
//  仅当 RuntimeInspectProvider 注入且能力开启时才应注册本工具。
//

import Foundation

public struct RuntimeInspectTool: ToolProtocol {
    public let name = "app_runtime_inspect"
    public let description = """
        Inspect and modify the host app runtime. Choose an 'op':
        - 'ui_hierarchy': dump current window view/controller hierarchy
        - 'view_tree': dump the view tree with addressable paths ("0/2/1"); optional 'maxDepth' (default 12)
        - 'view_info': dump one view's live state (class, frame, colors, text, subview count) at 'path'
        - 'view_set': change one view at 'path': 'key' = frame|bounds|center|alpha|hidden|cornerRadius|backgroundColor|text \
        (anything else falls back to KVC) with 'value' ("x,y,w,h" for rects, "#RRGGBB" for colors)
        - 'view_invoke': call 'selector' on the view at 'path' with 'argumentsJSON' \
        (e.g. removeFromSuperview / setNeedsLayout — structural changes)
        - 'class_list': list runtime classes (optional 'filter' substring, e.g. "BM")
        - 'method_list': list methods of 'class'
        - 'property_list': list properties/ivars of 'class'
        - 'property_value': read a 'keyPath' value (optional 'class', defaults to top page)
        - 'property_set': write a 'keyPath' value via KVC using 'value' (optional 'class', defaults to top page)
        - 'invoke': call 'selector' on 'class' with 'argumentsJSON' (a JSON array). Powerful — use carefully.
        Typical flow for UI surgery: 'view_tree' → pick a path → 'view_info' → 'view_set' / 'view_invoke'.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["ui_hierarchy", "view_tree", "view_info", "view_set", "view_invoke",
                                       "class_list", "method_list", "property_list", "property_value", "property_set", "invoke"]),
            "class": .string(description: "Class name for method_list/property_list/property_value/property_set/invoke."),
            "filter": .string(description: "Substring filter for class_list."),
            "path": .string(description: "View path for view_info/view_set/view_invoke, e.g. \"root\" or \"0/2/1\"."),
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

    private let provider: RuntimeInspectProvider

    public init(provider: RuntimeInspectProvider) {
        self.provider = provider
    }

    /// The provider reports failures as sentinel strings. Surface those as tool
    /// errors so the model cannot mistake "(class not found: X)" for an answer.
    private func output(_ text: String) -> Tool.Output {
        let failurePrefixes = [
            "(class not found", "(no view at path", "(selector ", "(no target)",
            "(no windows)", "(no key window)", "Invoke failed:", "Failed to set "
        ]
        return failurePrefixes.contains(where: { text.hasPrefix($0) }) ? .error(text) : .text(text)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let className = arguments["class"]?.stringValue
        switch op {
        case "ui_hierarchy":
            return output(await provider.uiHierarchy())
        case "view_tree":
            let depth = arguments["maxDepth"]?.numberValue.map { Int($0) } ?? 12
            return output(await provider.viewTree(maxDepth: depth))
        case "view_info":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_info") }
            return output(await provider.viewInfo(path: path))
        case "view_set":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_set") }
            guard let key = arguments["key"]?.stringValue else { return .error("'key' is required for view_set") }
            guard let value = arguments["value"]?.stringValue else { return .error("'value' is required for view_set") }
            return output(await provider.setViewValue(path: path, key: key, value: value))
        case "view_invoke":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_invoke") }
            guard let selector = arguments["selector"]?.stringValue else { return .error("'selector' is required for view_invoke") }
            let argsJSON = arguments["argumentsJSON"]?.stringValue ?? "[]"
            return output(await provider.invokeOnView(path: path, selector: selector, argumentsJSON: argsJSON))

        case "class_list":
            let list = await provider.classList(matching: arguments["filter"]?.stringValue)
            return .text(list.joined(separator: "\n"))
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
            return .text(value ?? "(nil)")
        case "property_set":
            guard let keyPath = arguments["keyPath"]?.stringValue else {
                return .error("'keyPath' is required for property_set")
            }
            guard let value = arguments["value"]?.stringValue else {
                return .error("'value' is required for property_set")
            }
            return output(await provider.setPropertyValue(keyPath: keyPath, value: value, ofClass: className))
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
