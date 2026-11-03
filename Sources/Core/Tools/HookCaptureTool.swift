//
//  HookCaptureTool.swift
//  AppAgent — 宿主能力层
//
//  app agent 的宿主消息捕获诊断工具（app_hook_capture）。宿主按自己的边界定义 channel，
//  把命中的记录落到本地沙盒 JSONL，再由本工具读回分析。捕获默认全关；本工具通过共享的
//  NSUserDefaults 契约拨动开关，同进程的宿主写入方即时生效。自包含，无需 provider。
//

import Foundation

public struct HookCaptureTool: ToolProtocol {
    public let name = "app_hook_capture"
    public let description = """
        Capture host-instrumented messages and page diagnostics for debugging. Channel names and
        their meaning are defined by the host; the SDK does not assume a particular bridge,
        framework, or error-code vocabulary. Records may carry a host-defined 'status' field,
        which should be checked before concluding that a call was never received. Capture is OFF
        by default; you toggle it per channel.
        Choose an 'op':
        - 'status': show which channels are on and list capture files.
        - 'start': turn on 'channel'; optional filters 'apiAllow'/'apiDeny' (comma-separated),
          'match' ("substring"|"prefix"|"regex"), 'sampleEveryN', 'rateLimitPerSec',
          'maxPreviewBytes', 'captureResult'.
        - 'stop': turn off 'channel'.
        - 'stop_all': turn off all channels.
        - 'read': read recent records of 'channel' (optional 'limit' [default 50], 'webviewId',
          'pageId', 'callId', 'runId'). Use the webviewId returned by app_web_inspect targets.
          Incremental reads require BOTH 'runId' and 'sinceSeq'; seq restarts with the app.
          Read warnings/truncated before drawing conclusions. An empty result does not prove
          that no messages occurred: the host may not instrument that path or capture was off.
        - 'clear': delete capture files (optional 'channel'; else all).
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["status", "start", "stop", "stop_all", "read", "clear"]),
            "channel": .string(description: "Host-defined channel name."),
            "apiAllow": .string(description: "start: comma-separated API allow patterns (empty = all)."),
            "apiDeny": .string(description: "start: comma-separated API deny patterns."),
            "match": .string(description: "start: pattern match mode.",
                             enumValues: ["substring", "prefix", "regex"]),
            "sampleEveryN": .integer(description: "start: keep 1 of every N hits.", minimum: 1, maximum: 1000000),
            "rateLimitPerSec": .integer(description: "start: max records/sec (0 = unlimited).", minimum: 0, maximum: 1000000),
            "maxPreviewBytes": .integer(description: "start: truncate args/result preview to N bytes.", minimum: 0, maximum: 65536),
            "captureResult": .boolean(description: "start: also capture result payload (default true)."),
            "limit": .integer(description: "read: max records to return (default 50).", minimum: 1, maximum: 500),
            "sinceSeq": .integer(description: "read: seq cursor within the specified runId.", minimum: 0),
            "webviewId": .string(description: "read: exact container identity from app_web_inspect targets."),
            "pageId": .string(description: "read: exact navigation/page generation from capture records."),
            "callId": .string(description: "read: exact call identity, ideally combined with webviewId."),
            "runId": .string(description: "read: process run identity; required with sinceSeq.")
        ],
        required: ["op"]
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .moderate
    public var outputMaxBytes: Int? {
        64 * 1024
    }

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "status", "read":
            return .safe
        case "start", "stop", "stop_all":
            return .moderate
        case "clear":
            return .sensitive
        default:
            return .moderate
        }
    }

    public init() {
    }

    public func preflightRejection(for arguments: [String: JSONValue], session: AISession) async -> String? {
        argumentError(arguments)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        try Task.checkCancellation()
        if let error = argumentError(arguments) {
            return .error(error)
        }
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "status":
            return statusOutput()
        case "start":
            return startOutput(arguments)
        case "stop":
            guard let channel = channelArg(arguments) else {
                return channelError()
            }
            let ok = HookCaptureStore.setChannel(channel, enabled: false, filter: [:])
            return ok ? .text("capture stopped: \(channel)") : .error("failed to update capture config.")
        case "stop_all":
            let ok = HookCaptureStore.disableAll()
            return ok ? .text("capture stopped: all channels") : .error("failed to update capture config.")
        case "read":
            guard let channel = channelArg(arguments) else {
                return channelError()
            }
            let sinceSeq = intArg(arguments["sinceSeq"]).map {
                UInt64($0)
            }
            let snapshot = HookCaptureStore.readSnapshot(
                directory: HookCaptureStore.directory(), channel: channel,
                limit: intArg(arguments["limit"]) ?? 50, sinceSeq: sinceSeq,
                webviewId: arguments["webviewId"]?.stringValue,
                callId: arguments["callId"]?.stringValue,
                runId: arguments["runId"]?.stringValue,
                pageId: arguments["pageId"]?.stringValue,
                maxOutputBytes: 48 * 1024
            )
            return .text(prettyJSON(snapshot))
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
        let allFiles = HookCaptureStore.files()
        let files = allFiles.suffix(100).map {
            ["name": $0.name, "size": $0.size] as [String: Any]
        }
        return .text(prettyJSON([
            "dir": HookCaptureStore.directory(), "channels": chStatus, "files": files,
            "fileCount": allFiles.count, "filesTruncated": allFiles.count > files.count,
            "coverage": "Only host-instrumented paths are recorded; enabled does not mean all bridges are covered."
        ]))
    }

    private func startOutput(_ args: [String: JSONValue]) -> Tool.Output {
        guard let channel = channelArg(args) else {
            return channelError()
        }
        var filter: [String: Any] = [:]
        if let allow = args["apiAllow"]?.stringValue {
            filter["apiAllow"] = csv(allow)
        }
        if let deny = args["apiDeny"]?.stringValue {
            filter["apiDeny"] = csv(deny)
        }
        if let match = args["match"]?.stringValue {
            filter["match"] = match
        }
        if let n = intArg(args["sampleEveryN"]) {
            filter["sampleEveryN"] = n
        }
        if let rate = intArg(args["rateLimitPerSec"]) {
            filter["rateLimitPerSec"] = rate
        }
        if let bytes = intArg(args["maxPreviewBytes"]) {
            filter["maxPreviewBytes"] = bytes
        }
        if let capture = args["captureResult"]?.boolValue {
            filter["captureResult"] = capture
        }
        let ok = HookCaptureStore.setChannel(channel, enabled: true, filter: filter)
        return ok ? .text("capture started: \(channel)") : .error("failed to update capture config.")
    }

    // MARK: - Helpers

    private func channelArg(_ args: [String: JSONValue]) -> String? {
        guard let ch = args["channel"]?.stringValue, HookCaptureStore.isValidChannel(ch) else {
            return nil
        }
        return ch
    }

    private func channelError() -> Tool.Output {
        .error("'channel' is required and must be one of \(HookCaptureStore.channels).")
    }

    private func csv(_ s: String) -> [String] {
        s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter {
            !$0.isEmpty
        }
    }

    private func intArg(_ v: JSONValue?) -> Int? {
        if let n = v?.numberValue, n.isFinite {
            return Int(exactly: n)
        }
        if let s = v?.stringValue, let n = Int(s) {
            return n
        }
        return nil
    }

    private func argumentError(_ args: [String: JSONValue]) -> String? {
        guard let op = args["op"]?.stringValue,
              ["status", "start", "stop", "stop_all", "read", "clear"].contains(op) else {
            return "op must be status/start/stop/stop_all/read/clear."
        }
        if args["channel"] != nil || ["start", "stop", "read"].contains(op) {
            guard let channel = args["channel"]?.stringValue, HookCaptureStore.isValidChannel(channel) else {
                return "channel is missing or invalid."
            }
        }
        for (key, range) in [
            "limit": 1...500, "sinceSeq": 0...Int.max, "sampleEveryN": 1...1000000,
            "rateLimitPerSec": 0...1000000, "maxPreviewBytes": 0...65536
        ] where args[key] != nil {
            guard let value = intArg(args[key]), range.contains(value) else {
                return "\(key) must be an integer in \(range)."
            }
        }
        for key in ["webviewId", "pageId", "callId", "runId"] where args[key] != nil {
            guard let value = args[key]?.stringValue,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 512 else {
                return "\(key) must be a nonempty string of at most 512 bytes."
            }
        }
        if args["sinceSeq"] != nil && args["runId"] == nil {
            return "sinceSeq requires runId; a sequence number alone is not valid across app restarts."
        }
        if let match = args["match"], !["substring", "prefix", "regex"].contains(match.stringValue ?? "") {
            return "match must be substring, prefix or regex."
        }
        for key in ["apiAllow", "apiDeny"] where args[key] != nil {
            guard let value = args[key]?.stringValue, value.utf8.count <= 4096, csv(value).count <= 64 else {
                return "\(key) must be a string of at most 4096 bytes and 64 patterns."
            }
            if args["match"]?.stringValue == "regex" {
                for pattern in csv(value) where (try? NSRegularExpression(pattern: pattern)) == nil {
                    return "\(key) contains an invalid regular expression."
                }
            }
        }
        if let capture = args["captureResult"], capture.boolValue == nil {
            return "captureResult must be a boolean."
        }
        return nil
    }

    private func prettyJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
