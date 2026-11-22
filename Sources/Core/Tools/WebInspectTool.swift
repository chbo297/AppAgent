//
//  WebInspectTool.swift
//  AppAgent — 宿主能力层
//
//  把「H5 / WKWebView 内省」封装成一个多操作工具。仅当 WebInspectProvider 注入且能力开启时注册。
//
//  设计取向与 app_runtime_inspect 一致：先摘要、再按 path 钻取，别让模型一次拉走整棵 DOM。
//

import Foundation

public struct WebInspectTool: ToolProtocol {
    public let name = "app_web_inspect"
    public let description = """
        Look inside H5 pages shown in the app's WKWebView containers; the native view tree stops at \
        the WKWebView. Use it when the question is about web content: what an H5 page shows, why an \
        element is missing, hidden, clipped or the wrong size, which node is at a screen point, what \
        the page logged or failed to load, or a JS-bridge problem (console capture). Reads run in an \
        isolated JS world and do not affect the page; 'eval' runs arbitrary JS and asks the user first. \
        The first call returns the full usage guide.
        """
    public let usageGuide: String? = Self.guide
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation; see the usage guide for what each one needs.",
                          enumValues: ["targets", "dom_summary", "dom_query", "why_hidden", "probe",
                                       "highlight", "clear_highlight", "page_source", "eval",
                                       "console_start", "console_read", "console_stop"]),
            "scope": HostInspectionScope.parameter,
            "webviewId": .string(description: "Container id from 'targets'. Omit to use the largest visible container."),
            "selector": .string(description: "CSS selector for dom_query / why_hidden / highlight, searched inside 'path' when both are given."),
            "path": .string(description: "Element child indexes from document.body, e.g. \"0/2/1\". \"frame\" enters a same-origin iframe, \"shadow\" an open shadow root: \"0/frame/1/shadow/0\"."),
            "maxNodes": .integer(description: "dom_summary node budget (default 120).", minimum: 10, maximum: 1000),
            "x": .number(description: "probe only: x in points, web view coordinates."),
            "y": .number(description: "probe only: y in points, web view coordinates."),
            "kind": .string(description: "page_source only: 'html' (live DOM, default) or 'resources' (loaded and failed resources).",
                            enumValues: ["html", "resources"],
                            defaultValue: .string("html")),
            "maxBytes": .integer(description: "page_source truncation budget (default 65536).", minimum: 1024, maximum: 524288),
            "script": .string(description: "eval only: JavaScript whose result must be JSON-serializable."),
            "pageWorld": .boolean(description: "eval only: run in the page's own JS world to reach its globals (default false)."),
            "limit": .integer(description: "console_read only: max records (default 100).", minimum: 1, maximum: 1000),
            "sinceSeq": .integer(description: "console_read only: return records with a larger seq.", minimum: 0)
        ],
        required: ["op"]
    )
    public let group = "host-runtime"
    /// 调试工具，按需加载（debug 组）。
    public let deferredGroup: String? = ToolGroups.debug
    public let safetyLevel: Tool.SafetyLevel = .sensitive

    /// 原生标注是可逆的 UI 修改；任意 JS 不继承 DOM 读取或标注的权限。
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "targets", "dom_summary", "dom_query", "why_hidden", "probe", "page_source", "console_read":
            return .safe
        case "highlight", "clear_highlight", "console_start", "console_stop":
            return .moderate
        default:
            return .sensitive
        }
    }

    private let provider: WebInspectProvider

    public init(provider: WebInspectProvider) {
        self.provider = provider
    }

    public func preflightRejection(for arguments: [String: JSONValue], session: AISession) async -> String? {
        validationError(arguments)
    }

    /// Validate before permission checks and before default-target resolution. A present but
    /// malformed optional argument must never acquire the semantics of an omitted argument.
    private func validationError(_ arguments: [String: JSONValue]) -> String? {
        for key in ["op", "webviewId", "selector", "path", "kind", "script", "scope"] {
            guard let raw = arguments[key] else {
                continue
            }
            guard case .string(let value) = raw else {
                return "'\(key)' must be a string when supplied."
            }
            if key != "path", value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "'\(key)' must not be empty."
            }
        }
        if let raw = arguments["pageWorld"], raw.boolValue == nil {
            return "'pageWorld' must be a boolean."
        }
        if let scope = arguments["scope"]?.stringValue, HostInspectionScope(rawValue: scope) == nil {
            return "Unknown scope '\(scope)'. Use 'host', 'appagent' or 'all'."
        }
        if let kind = arguments["kind"]?.stringValue, kind != "html" && kind != "resources" {
            return "Unknown kind '\(kind)'. Use 'html' or 'resources'."
        }
        for key in ["maxNodes", "maxBytes", "limit"] {
            if let raw = arguments[key] {
                guard let value = raw.numberValue, value.isFinite, Int(exactly: value) != nil else {
                    return "'\(key)' must be a finite integer representable as Int."
                }
            }
        }
        if let raw = arguments["sinceSeq"] {
            guard let value = raw.numberValue, value.isFinite, UInt64(exactly: value) != nil else {
                return "'sinceSeq' must be a nonnegative finite integer representable as UInt64."
            }
        }
        for key in ["x", "y"] {
            if let raw = arguments[key] {
                guard let value = raw.numberValue, value.isFinite, value >= 0, value <= 1_000_000 else {
                    return "'\(key)' must be between 0 and 1000000 view points."
                }
            }
        }
        switch arguments["op"]?.stringValue {
        case "dom_query", "why_hidden", "highlight":
            if arguments["selector"] == nil && arguments["path"] == nil {
                return "'selector' or 'path' is required for \(arguments["op"]?.stringValue ?? "")."
            }
        case "probe":
            if arguments["x"] == nil || arguments["y"] == nil {
                return "'x' and 'y' are required for probe."
            }
        case "eval":
            if arguments["script"] == nil {
                return "'script' is required for eval."
            }
        case "targets", "dom_summary", "clear_highlight", "page_source", "console_start", "console_read", "console_stop":
            break
        default:
            return "unknown op: \(arguments["op"]?.stringValue ?? "")"
        }
        return nil
    }

    /// provider 的失败以 sentinel 字符串返回，这里翻译成工具错误——否则模型会把
    /// "(no web view found)" 当成「页面里什么都没有」继续往下推。
    private func output(_ text: String) -> Tool.Output {
        let failurePrefixes = [
            "(no web view", "(no node", "(no element", "(webview not found",
            "JS error:", "Inspection denied:", "Failed to "
        ]
        let isFailure = failurePrefixes.contains(where: { prefix in
            text.hasPrefix(prefix)
        })
        return isFailure ? .error(text) : .text(text)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        if let rejection = validationError(arguments) {
            return .error(rejection)
        }
        let context = try await HostInspectionAccess.context(
            arguments: arguments, session: session, tool: name,
            isMutation: safetyLevel(for: arguments) > .safe
        )
        return await dispatch(arguments: arguments, context: context)
    }

    private func dispatch(arguments: [String: JSONValue], context: HostInspectionContext) async -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let webviewId = arguments["webviewId"]?.stringValue
        let selector = arguments["selector"]?.stringValue
        let path = arguments["path"]?.stringValue
        switch op {
        case "targets":
            return output(await provider.targets(context: context))
        case "dom_summary":
            let maxNodes = arguments["maxNodes"]?.numberValue.map { value in
                Int(exactly: value) ?? 120
            } ?? 120
            return output(await provider.domSummary(webviewId: webviewId, path: path,
                                                    maxNodes: max(10, min(1000, maxNodes)), context: context))
        case "dom_query":
            guard selector != nil || path != nil else {
                return .error("'selector' or 'path' is required for dom_query")
            }
            return output(await provider.domQuery(webviewId: webviewId, selector: selector, path: path, context: context))
        case "why_hidden":
            guard selector != nil || path != nil else {
                return .error("'selector' or 'path' is required for why_hidden")
            }
            return output(await provider.whyHidden(webviewId: webviewId, selector: selector, path: path, context: context))
        case "highlight":
            guard selector != nil || path != nil else {
                return .error("'selector' or 'path' is required for highlight")
            }
            return output(await provider.highlight(webviewId: webviewId, selector: selector, path: path, context: context))
        case "clear_highlight":
            return output(await provider.clearHighlight(webviewId: webviewId, context: context))
        case "probe":
            guard let x = arguments["x"]?.numberValue, let y = arguments["y"]?.numberValue else {
                return .error("'x' and 'y' are required for probe")
            }
            return output(await provider.probe(webviewId: webviewId, x: x, y: y, context: context))
        case "page_source":
            let kind = arguments["kind"]?.stringValue ?? "html"
            guard kind == "html" || kind == "resources" else {
                return .error("Unknown kind '\(kind)'. Use 'html' or 'resources'.")
            }
            let maxBytes = arguments["maxBytes"]?.numberValue.map { value in
                Int(exactly: value) ?? 65_536
            } ?? 65_536
            return output(await provider.pageSource(webviewId: webviewId, kind: kind,
                                                    maxBytes: max(1024, min(524_288, maxBytes)), context: context))
        case "eval":
            guard let script = arguments["script"]?.stringValue, !script.isEmpty else {
                return .error("'script' is required for eval")
            }
            let pageWorld = arguments["pageWorld"]?.boolValue ?? false
            return output(await provider.eval(webviewId: webviewId, script: script, inPageWorld: pageWorld, context: context))
        case "console_start":
            return output(await provider.consoleStart(webviewId: webviewId, context: context))
        case "console_read":
            let limit = arguments["limit"]?.numberValue.map { value in
                Int(exactly: value) ?? 100
            } ?? 100
            let sinceSeq = arguments["sinceSeq"]?.numberValue.flatMap { value in
                UInt64(exactly: value)
            }
            return output(await provider.consoleRead(webviewId: webviewId,
                                                     limit: max(1, min(1000, limit)), sinceSeq: sinceSeq, context: context))
        case "console_stop":
            return output(await provider.consoleStop(webviewId: webviewId, context: context))
        default:
            return .error("unknown op: \(op)")
        }
    }
}

extension WebInspectTool {
    static let guide = """
        FIND THE PAGE
        - targets: live web containers (id, url, title, frame, visibility). Start here when unsure \
        which container the user means; other ops default to the largest visible one.

        SEE WHAT IT RENDERS
        - dom_summary (path?, maxNodes?): meaningful nodes only (text, interactive, has id, large \
        enough); big subtrees collapse to "⊞ N nodes" with the path to expand.
        - dom_query (selector | path): one node in detail: box model, key computed styles, scrollWidth \
        vs clientWidth, ancestor chain and the ancestor that limits the width ("why is it not full \
        width").
        - why_hidden (selector | path): display / visibility / opacity / zero size / clipped by an \
        ancestor / outside the viewport / covered by another element. Use it before guessing.
        - probe (x, y): the node at a point, in points in web view coordinates.
        - highlight (selector | path) / clear_highlight: native red outline that ignores touches and \
        does not touch the DOM; cleared on navigation or when the container hides. Use it instead of \
        eval to mark nodes.
        - page_source (kind?, maxBytes?): 'html' is the live DOM (what actually renders), 'resources' \
        lists loaded resources and failures.
        - Cross-origin iframes and closed shadow roots cannot be entered.

        RUN JS
        - eval (script, pageWorld?): returns the JSON-serializable result. Runs in the isolated world \
        unless pageWorld=true (needed for the page's own globals). Always asks the user; approval for \
        DOM reads does not cover JS or DOM writes.

        CONSOLE AND BRIDGE PROBLEMS
        - console_start / console_read (limit?, sinceSeq?) / console_stop: captures console.log / \
        info / warn / error, window 'error' and 'unhandledrejection'. Nothing is injected before \
        console_start and only later logs are captured: start, have the user retry, then read.
        - For a JS-bridge problem, also check the host app's own bridge-message capture tool if it \
        provides one; the native side of a bridge is not visible from the page.

        TYPICAL FLOW
        - Rendering bug: targets → dom_summary → why_hidden / dom_query.
        - Bridge bug: console_start → user retries → console_read (+ the host's bridge capture, if any).
        """
}
