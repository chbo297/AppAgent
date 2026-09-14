//
//  RuntimeInspectTool.swift
//  OpenAPP — Liji 集成层
//
//  把宿主 app 的运行时内省能力封装为一个多操作工具，供 app agent 灵活调用。
//  仅当 RuntimeInspectProvider 注入且能力开启时才应注册本工具。
//

import Foundation

public struct RuntimeInspectTool: ToolProtocol {
    public let name = "app_runtime_inspect"
    public let description = """
        Inspect the host app runtime. Choose an 'op':
        - 'ui_hierarchy': dump current window view/controller hierarchy
        - 'class_list': list runtime classes (optional 'filter' substring, e.g. "BM")
        - 'method_list': list methods of 'class'
        - 'property_list': list properties/ivars of 'class'
        - 'property_value': read a 'keyPath' value (optional 'class', defaults to top page)
        - 'invoke': call 'selector' on 'class' with 'argumentsJSON' (a JSON array). Powerful — use carefully.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["ui_hierarchy", "class_list", "method_list", "property_list", "property_value", "invoke"]),
            "class": .string(description: "Class name for method_list/property_list/property_value/invoke."),
            "filter": .string(description: "Substring filter for class_list."),
            "keyPath": .string(description: "Key path for property_value."),
            "selector": .string(description: "Selector for invoke."),
            "argumentsJSON": .string(description: "JSON array string of arguments for invoke.")
        ],
        required: ["op"]
    )
    public let group = "liji-runtime"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    private let provider: RuntimeInspectProvider

    public init(provider: RuntimeInspectProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let className = arguments["class"]?.stringValue
        switch op {
        case "ui_hierarchy":
            return .text(await provider.uiHierarchy())
        case "class_list":
            let list = await provider.classList(matching: arguments["filter"]?.stringValue)
            return .text(list.joined(separator: "\n"))
        case "method_list":
            guard let className else { return .error("'class' is required for method_list") }
            return .text((await provider.methodList(ofClass: className)).joined(separator: "\n"))
        case "property_list":
            guard let className else { return .error("'class' is required for property_list") }
            return .text((await provider.propertyList(ofClass: className)).joined(separator: "\n"))
        case "property_value":
            guard let keyPath = arguments["keyPath"]?.stringValue else {
                return .error("'keyPath' is required for property_value")
            }
            let value = await provider.propertyValue(keyPath: keyPath, ofClass: className)
            return .text(value ?? "(nil)")
        case "invoke":
            guard let className, let selector = arguments["selector"]?.stringValue else {
                return .error("'class' and 'selector' are required for invoke")
            }
            let argsJSON = arguments["argumentsJSON"]?.stringValue ?? "[]"
            return .text(await provider.invoke(className: className, selector: selector, argumentsJSON: argsJSON))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
