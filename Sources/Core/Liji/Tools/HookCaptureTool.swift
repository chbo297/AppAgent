//
//  HookCaptureTool.swift
//  AppAgent — Liji 集成层
//
//  app agent 的「JS↔端消息捕获」诊断工具（app_hook_capture）。热修复排查时：在宿主
//  四个消息边界（talos_in/out、shell_in/out）按 channel 开启 dormant tap，把命中的
//  {方向, API, 入参, 结果} 落到本地沙盒 JSONL，再由本工具读回分析。捕获默认全关；本工具
//  通过共享的 NSUserDefaults 契约拨动开关，同进程 LijiMsgTap 即时生效。自包含，无需 provider。
//

import Foundation

public struct HookCaptureTool: ToolProtocol {
    public let name = "app_hook_capture"
    public let description = """
        Capture JS↔native bridge messages in the host app for hot-fix diagnosis, when a
        web/Talos page calls a native API but the app does not respond correctly. Channels:
        'talos_in' (page→native), 'talos_out' (native→page), 'shell_in' (Cordova/bdapi→native),
        'shell_out' (native→page). Capture is OFF by default; you toggle it per channel.
        Choose an 'op':
        - 'status': show which channels are on and list capture files.
        - 'start': turn on 'channel'; optional filters 'apiAllow'/'apiDeny' (comma-separated),
          'match' ("substring"|"prefix"|"regex"), 'sampleEveryN', 'rateLimitPerSec',
          'maxPreviewBytes', 'captureResult'.
        - 'stop': turn off 'channel'.
        - 'stop_all': turn off all channels.
        - 'read': read recent records of 'channel' (optional 'limit' [default 50], 'sinceSeq').
        - 'clear': delete capture files (optional 'channel'; else all).
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["status", "start", "stop", "stop_all", "read", "clear"]),
            "channel": .string(description: "Channel name.",
                               enumValues: ["talos_in", "talos_out", "shell_in", "shell_out"]),
            "apiAllow": .string(description: "start: comma-separated API allow patterns (empty = all)."),
            "apiDeny": .string(description: "start: comma-separated API deny patterns."),
            "match": .string(description: "start: pattern match mode.",
                             enumValues: ["substring", "prefix", "regex"]),
            "sampleEveryN": .integer(description: "start: keep 1 of every N hits (>=1)."),
            "rateLimitPerSec": .integer(description: "start: max records/sec (0 = unlimited)."),
            "maxPreviewBytes": .integer(description: "start: truncate args/result preview to N bytes."),
            "captureResult": .boolean(description: "start: also capture result payload (default true)."),
            "limit": .integer(description: "read: max records to return (default 50)."),
            "sinceSeq": .integer(description: "read: only records with seq greater than this.")
        ],
        required: ["op"]
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "status":
            return statusOutput()
        case "start":
            return startOutput(arguments)
        case "stop":
            guard let channel = channelArg(arguments) else { return channelError() }
            let ok = HookCaptureStore.setChannel(channel, enabled: false, filter: [:])
            return ok ? .text("capture stopped: \(channel)") : .error("failed to update capture config.")
        case "stop_all":
            let ok = HookCaptureStore.disableAll()
            return ok ? .text("capture stopped: all channels") : .error("failed to update capture config.")
        case "read":
            guard let channel = channelArg(arguments) else { return channelError() }
            let limit = max(1, intArg(arguments["limit"]) ?? 50)
            let sinceSeq = intArg(arguments["sinceSeq"]).map { UInt64(max(0, $0)) }
            let recs = HookCaptureStore.records(channel: channel, limit: limit, sinceSeq: sinceSeq)
            return .text(prettyJSON(["channel": channel, "count": recs.count, "records": recs]))
        case "clear":
            let channel = arguments["channel"]?.stringValue
            if let channel, !HookCaptureStore.isValidChannel(channel) {
                return .error("unknown channel: \(channel)")
            }
            let n = HookCaptureStore.clear(channel: channel)
            return .text("cleared \(n) capture file(s)\(channel.map { " for \($0)" } ?? "").")
        default:
            return .error("unknown op: '\(op)'. Use status/start/stop/stop_all/read/clear.")
        }
    }

    // MARK: - Ops

    private func statusOutput() -> Tool.Output {
        let channels = (HookCaptureStore.readConfig()["channels"] as? [String: Any]) ?? [:]
        var chStatus: [String: Any] = [:]
        for ch in HookCaptureStore.channels {
            let entry = (channels[ch] as? [String: Any]) ?? [:]
            chStatus[ch] = ["enabled": (entry["enabled"] as? Bool) ?? false]
        }
        let files = HookCaptureStore.files().map { ["name": $0.name, "size": $0.size] as [String: Any] }
        return .text(prettyJSON(["dir": HookCaptureStore.directory(), "channels": chStatus, "files": files]))
    }

    private func startOutput(_ args: [String: JSONValue]) -> Tool.Output {
        guard let channel = channelArg(args) else { return channelError() }
        var filter: [String: Any] = [:]
        if let allow = args["apiAllow"]?.stringValue { filter["apiAllow"] = csv(allow) }
        if let deny = args["apiDeny"]?.stringValue { filter["apiDeny"] = csv(deny) }
        if let match = args["match"]?.stringValue { filter["match"] = match }
        if let n = intArg(args["sampleEveryN"]) { filter["sampleEveryN"] = max(1, n) }
        if let r = intArg(args["rateLimitPerSec"]) { filter["rateLimitPerSec"] = max(0, r) }
        if let m = intArg(args["maxPreviewBytes"]) { filter["maxPreviewBytes"] = max(0, m) }
        if let cr = args["captureResult"]?.boolValue { filter["captureResult"] = cr }
        let ok = HookCaptureStore.setChannel(channel, enabled: true, filter: filter)
        return ok ? .text("capture started: \(channel)") : .error("failed to update capture config.")
    }

    // MARK: - Helpers

    private func channelArg(_ args: [String: JSONValue]) -> String? {
        guard let ch = args["channel"]?.stringValue, HookCaptureStore.isValidChannel(ch) else { return nil }
        return ch
    }

    private func channelError() -> Tool.Output {
        .error("'channel' is required and must be one of \(HookCaptureStore.channels).")
    }

    private func csv(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func intArg(_ v: JSONValue?) -> Int? {
        if let n = v?.numberValue { return Int(n) }
        if let s = v?.stringValue, let n = Int(s) { return n }
        return nil
    }

    private func prettyJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
