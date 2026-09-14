//
//  HotfixTool.swift
//  AppAgent — Liji 集成层
//
//  把宿主 app 的热修复能力封装为工具。仅当 HotfixProvider 注入且能力开启时注册。
//

import Foundation

public struct HotfixTool: ToolProtocol {
    public let name = "app_hotfix"
    public let description = """
        Manage host-app JS hotfix patches (BMBandage-compatible). Choose an 'op':
        - 'list': list installed patch slots
        - 'apply': install/replace patch 'name' with 'javascript' ('applyMode': instant|restart)
        - 'toggle': enable/disable patch 'name' via 'enabled'
        - 'remove': remove patch 'name'
        For test builds only. instant patches take effect immediately; restart patches need an app restart.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.", enumValues: ["list", "apply", "toggle", "remove"]),
            "name": .string(description: "Patch slot name."),
            "javascript": .string(description: "JS patch source for apply."),
            "applyMode": .string(description: "instant | restart", enumValues: ["instant", "restart"]),
            "summary": .string(description: "Short human summary of the patch."),
            "enabled": .boolean(description: "For toggle.")
        ],
        required: ["op"]
    )
    public let group = "liji-hotfix"
    public let safetyLevel: Tool.SafetyLevel = .sensitive

    private let provider: HotfixProvider

    public init(provider: HotfixProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "list":
            let items = await provider.list()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(items), let s = String(data: data, encoding: .utf8) {
                return .text(s)
            }
            return .text("[]")
        case "apply":
            guard let name = arguments["name"]?.stringValue,
                  let js = arguments["javascript"]?.stringValue else {
                return .error("'name' and 'javascript' are required for apply")
            }
            let mode = arguments["applyMode"]?.stringValue ?? "restart"
            let summary = arguments["summary"]?.stringValue ?? ""
            let result = await provider.apply(name: name, javascript: js, applyMode: mode, summary: summary)
            return .json(.object([
                "success": .bool(result.success),
                "applyMode": .string(result.applyMode),
                "needsRestart": .bool(result.needsRestart),
                "message": .string(result.message)
            ]))
        case "toggle":
            guard let name = arguments["name"]?.stringValue else {
                return .error("'name' is required for toggle")
            }
            var enabled = true
            if case .bool(let b)? = arguments["enabled"] { enabled = b }
            let ok = await provider.setEnabled(name: name, enabled: enabled)
            return .json(.object(["success": .bool(ok), "enabled": .bool(enabled)]))
        case "remove":
            guard let name = arguments["name"]?.stringValue else {
                return .error("'name' is required for remove")
            }
            let ok = await provider.remove(name: name)
            return .json(.object(["success": .bool(ok)]))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
