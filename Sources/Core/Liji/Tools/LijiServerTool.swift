//
//  LijiServerTool.swift
//  AppAgent — Liji 集成层
//
//  让 app agent 把「产品诉求」发给 liji_server 生成热修复补丁，并查询/应用/分享。
//  当本地运行时信息不足以实现需求时，走后台服务读取地图源码生成补丁。
//

import Foundation

public struct LijiServerTool: ToolProtocol {
    public let name = "liji_server"
    public let description = """
        Send product requirements to the liji backend which reads the real Baidu Map source and
        generates a hotfix patch. Choose an 'op':
        - 'submit': submit 'prompt' (natural-language requirement); optional 'runtimeContext'. Returns a requirement id.
        - 'status': check a requirement by 'requirementId' (status: pending/in_progress/patch_generated/applied/failed).
        - 'list': list my tasks & requirements.
        - 'apply': download the patch of 'patchId' and apply it via the host hotfix engine.
        - 'share': create a QR share for 'patchId'.
        - 'granted': list patches shared to me.
        - 'toggle': enable/disable a granted patch by 'token' via 'enabled'.
        Typical flow: submit → poll status until patch_generated → apply.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["submit", "status", "list", "apply", "share", "granted", "toggle"]),
            "prompt": .string(description: "Requirement text for submit."),
            "runtimeContext": .string(description: "Optional runtime info JSON captured on device."),
            "requirementId": .string(description: "Requirement id for status."),
            "patchId": .string(description: "Patch id for apply/share."),
            "token": .string(description: "Share token for toggle."),
            "enabled": .boolean(description: "For toggle.")
        ],
        required: ["op"]
    )
    public let group = "liji-server"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    private let client: LijiServerClient
    private let hotfix: HotfixProvider?

    public init(client: LijiServerClient, hotfix: HotfixProvider? = nil) {
        self.client = client
        self.hotfix = hotfix
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        do {
            switch op {
            case "submit":
                guard let prompt = arguments["prompt"]?.stringValue else {
                    return .error("'prompt' is required for submit")
                }
                let ctx = arguments["runtimeContext"]?.stringValue ?? ""
                let req = try await client.submitRequirement(prompt: prompt, runtimeContext: ctx)
                return .json(.object([
                    "requirementId": .string(req.id),
                    "taskId": .string(req.taskId),
                    "status": .string(req.status)
                ]))
            case "status":
                guard let rid = arguments["requirementId"]?.stringValue else {
                    return .error("'requirementId' is required for status")
                }
                let req = try await client.requirementStatus(id: rid)
                var obj: [String: JSONValue] = [
                    "requirementId": .string(req.id),
                    "status": .string(req.status),
                    "summary": .string(req.summary),
                    "iteration": .number(Double(req.iteration))
                ]
                if !req.error.isEmpty { obj["error"] = .string(req.error) }
                if let p = req.patch {
                    obj["patchId"] = .string(p.id)
                    obj["applyMode"] = .string(p.applyMode)
                }
                return .json(.object(obj))
            case "list":
                let tasks = try await client.listTasks()
                let summary = tasks.map { t in
                    "· \(t.title) [\(t.id.prefix(8))] — " +
                    t.requirements.map { "\($0.status)" }.joined(separator: ",")
                }.joined(separator: "\n")
                return .text(summary.isEmpty ? "(no tasks)" : summary)
            case "apply":
                guard let pid = arguments["patchId"]?.stringValue else {
                    return .error("'patchId' is required for apply")
                }
                guard let hotfix else {
                    return .error("hotfix engine not available on this build")
                }
                let dl = try await client.downloadPatch(patchId: pid)
                let result = await hotfix.apply(name: "liji_\(pid.prefix(8))",
                                                javascript: dl.javascript,
                                                applyMode: dl.applyMode,
                                                summary: "")
                return .json(.object([
                    "success": .bool(result.success),
                    "applyMode": .string(result.applyMode),
                    "needsRestart": .bool(result.needsRestart),
                    "message": .string(result.message)
                ]))
            case "share":
                guard let pid = arguments["patchId"]?.stringValue else {
                    return .error("'patchId' is required for share")
                }
                let s = try await client.share(patchId: pid)
                return .json(.object([
                    "token": .string(s.token),
                    "shareUrl": .string(s.shareUrl),
                    "qrUrl": .string(s.qrUrl)
                ]))
            case "granted":
                let grants = try await client.granted()
                let text = grants.map { "· \($0.title) [\($0.token.prefix(8))] enabled=\($0.enabled) from \($0.owner)" }
                    .joined(separator: "\n")
                return .text(text.isEmpty ? "(nothing shared to me)" : text)
            case "toggle":
                guard let token = arguments["token"]?.stringValue else {
                    return .error("'token' is required for toggle")
                }
                var enabled = true
                if case .bool(let b)? = arguments["enabled"] { enabled = b }
                let g = try await client.toggleGrant(token: token, enabled: enabled)
                return .json(.object(["token": .string(g.token), "enabled": .bool(g.enabled)]))
            default:
                return .error("unknown op: \(op)")
            }
        } catch let LijiServerError.http(status, body) {
            return .error("server \(status): \(body.prefix(300))")
        } catch {
            return .error("liji_server error: \(error)")
        }
    }
}
