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
        Inspect H5 pages running inside the app's WKWebView containers. The native view tree stops \
        at WKWebView — this tool is the only way \
        to see the DOM. Queries are read-only and run in an isolated content world, so page \
        JavaScript is not affected. Choose an 'op':
        - 'targets': list live web containers (id, url, title, frame, visibility). Start here when \
        unsure which container the user means.
        - 'dom_summary': the map of what the page renders. Only meaningful nodes (text, interactive, \
        has id, large enough); big subtrees collapse to "⊞ N nodes" plus the 'path' to expand. \
        Optional 'path' to start elsewhere, 'maxNodes' (default 120).
        - 'dom_query': one node in detail via 'selector' (preferred) or 'path' — box model \
        (content/padding/border/margin), key computed styles, scrollWidth vs clientWidth, ancestor \
        chain and the ancestor that constrains the width. This answers "why is it not full width".
        - 'why_hidden': why an element is not visible — display/visibility/opacity/zero size/clipped \
        by an ancestor/outside viewport/covered by another element. Use this before guessing.
        - 'probe': hit-test a screen point ('x','y' in points, view coordinates) and return the node.
        - 'highlight' / 'clear_highlight': show/remove a native, touch-transparent red outline for \
        a node selected by 'selector' or 'path'. Does not modify DOM. Automatically clears on navigation \
        or when the container becomes hidden/offscreen. Use this instead of eval for marking nodes.
        - 'page_source': 'kind'="html" (serialized live DOM, truncated) or "resources" (loaded \
        resources plus failures). Note the live DOM, not the original HTML, is what matters for \
        rendering bugs.
        - 'eval': run arbitrary JS and return the JSON-serializable result. Runs in the isolated \
        world unless 'pageWorld'=true (needed to touch the page's own globals). Requires sensitive \
        operation approval; permission to inspect DOM does not authorize arbitrary JS or DOM writes.
        - 'console_start' / 'console_read' / 'console_stop': capture console.log/info/warn/error, \
        window 'error' and 'unhandledrejection' events. Nothing is injected until you start it, and \
        only logs produced after starting are captured — start it, reproduce the problem, then read. \
        'console_read' takes 'limit' (default 100) and 'sinceSeq'.
        Typical flow for a rendering bug: 'targets' → 'dom_summary' → 'why_hidden' / 'dom_query'.
        Typical flow for a bridge bug: 'console_start' → ask the user to retry → 'console_read', \
        and cross-check with app_hook_capture using the host-defined channels for that bridge.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["targets", "dom_summary", "dom_query", "why_hidden", "probe",
                                       "highlight", "clear_highlight", "page_source", "eval",
                                       "console_start", "console_read", "console_stop"]),
            "scope": HostInspectionScope.parameter,
            "webviewId": .string(description: "Target container id from 'targets'. Omitted = the visible container with the largest area."),
            "selector": .string(description: "CSS selector for dom_query / why_hidden / highlight. In the root selected by path if supplied, otherwise the top document."),
            "path": .string(description: "Child element indices from document.body, e.g. '0/2/1'. 'frame' enters a same-origin iframe body; 'shadow' enters an open shadow root, e.g. '0/frame/1/shadow/0'. Cross-origin frames and closed shadow roots are unsupported."),
            "maxNodes": .integer(description: "Node budget for dom_summary (default 120).", minimum: 10, maximum: 1000),
            "x": .number(description: "X in points (view coordinates) for probe."),
            "y": .number(description: "Y in points (view coordinates) for probe."),
            "kind": .string(description: "For page_source: 'html' (default) or 'resources'.",
                            enumValues: ["html", "resources"],
                            defaultValue: .string("html")),
            "maxBytes": .integer(description: "Truncation budget for page_source (default 65536).", minimum: 1024, maximum: 524288),
            "script": .string(description: "JavaScript source for eval."),
            "pageWorld": .boolean(description: "For eval: run in the page's own world instead of the isolated one (default false)."),
            "limit": .integer(description: "For console_read: how many records (default 100).", minimum: 1, maximum: 1000),
            "sinceSeq": .integer(description: "For console_read: only records with a larger seq.", minimum: 0)
        ],
        required: ["op"]
    )
    public let group = "host-runtime"
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
