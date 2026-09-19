//
//  HotfixTool.swift
//  AppAgent — 宿主能力层
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
            "op": .string(description: "Operation.",
                          enumValues: ["list", "apply", "toggle", "remove"]),
            "_why": .string(description: "One sentence on why this is needed. Shown to the user when they are asked to approve; supply it for 'apply'."),
            "name": .string(description: "Patch slot name."),
            "javascript": .string(description: "JS patch source for apply."),
            "applyMode": .string(description: "instant | restart", enumValues: ["instant", "restart"]),
            "summary": .string(description: "Short human summary of the patch."),
            "enabled": .boolean(description: "For toggle.")
        ],
        required: ["op"]
    )
    public let group = "host-hotfix"
    public let safetyLevel: Tool.SafetyLevel = .sensitive

    /// `apply` 会在运行时执行任意 JS 改 UI/逻辑，风险等级和「列一下装了哪些补丁」
    /// 完全不在一个量级。
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "list": return .safe
        case "toggle", "remove": return .moderate
        case "apply": return .dangerous
        default: return .sensitive
        }
    }

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
            let payload = JSONValue.object([
                "success": .bool(result.success),
                "applyMode": .string(result.applyMode),
                "needsRestart": .bool(result.needsRestart),
                "message": .string(result.message)
            ])
            // 打补丁失败（JS 报错等）必须以 .error 收场：包成 .json 交回去的话
            // 这次调用在过程区里是「成功」，模型也容易把 success:false 读漏。
            return result.success ? .json(payload) : .error("hotfix apply failed: \(result.message)")
        case "toggle":
            guard let name = arguments["name"]?.stringValue else {
                return .error("'name' is required for toggle")
            }
            var enabled = true
            if case .bool(let b)? = arguments["enabled"] { enabled = b }
            let ok = await provider.setEnabled(name: name, enabled: enabled)
            guard ok else { return .error("no patch named '\(name)' (or re-enabling it failed).") }
            return .json(.object(["success": .bool(true), "enabled": .bool(enabled)]))
        case "remove":
            guard let name = arguments["name"]?.stringValue else {
                return .error("'name' is required for remove")
            }
            let ok = await provider.remove(name: name)
            guard ok else { return .error("no patch named '\(name)' to remove.") }
            return .json(.object(["success": .bool(true)]))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
