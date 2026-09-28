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
        Inspect H5 pages running inside the app's WKWebView containers (shell browser, Cordova, \
        embedded web views). The native view tree stops at WKWebView — this tool is the only way \
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
        - 'page_source': 'kind'="html" (serialized live DOM, truncated) or "resources" (loaded \
        resources plus failures). Note the live DOM, not the original HTML, is what matters for \
        rendering bugs.
        - 'eval': run arbitrary JS and return the JSON-serializable result. Runs in the isolated \
        world unless 'pageWorld'=true (needed to touch the page's own globals).
        - 'console_start' / 'console_read' / 'console_stop': capture console.log/info/warn/error, \
        window 'error' and 'unhandledrejection' events. Nothing is injected until you start it, and \
        only logs produced after starting are captured — start it, reproduce the problem, then read. \
        'console_read' takes 'limit' (default 100) and 'sinceSeq'.
        Typical flow for a rendering bug: 'targets' → 'dom_summary' → 'why_hidden' / 'dom_query'.
        Typical flow for a bridge bug: 'console_start' → ask the user to retry → 'console_read', \
        and cross-check with app_hook_capture channels shell_in/shell_out.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["targets", "dom_summary", "dom_query", "why_hidden", "probe",
                                       "page_source", "eval", "console_start", "console_read", "console_stop"]),
            "webviewId": .string(description: "Target container id from 'targets'. Omitted = the visible container with the largest area."),
            "selector": .string(description: "CSS selector for dom_query / why_hidden. Takes precedence over 'path'."),
            "path": .string(description: "Node path from 'dom_summary', e.g. \"0/2/1\" (child element indices from document.body)."),
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
    public let safetyLevel: Tool.SafetyLevel = .moderate

    /// 内部使用阶段权限放开：只读 op 为 safe，`eval` 与 console 开关为 moderate（不弹授权卡片）。
    /// 上线前 `eval` 要抬到 `.sensitive` 并接 DecisionRequest，见
    /// liji_server `docs/WEB_INSPECT_DESIGN.md` §6。
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "targets", "dom_summary", "dom_query", "why_hidden", "probe", "page_source", "console_read":
            return .safe
        case "eval", "console_start", "console_stop":
            return .moderate
        default:
            return .moderate
        }
    }

    private let provider: WebInspectProvider

    public init(provider: WebInspectProvider) {
        self.provider = provider
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
        let op = arguments["op"]?.stringValue ?? ""
        let webviewId = arguments["webviewId"]?.stringValue
        let selector = arguments["selector"]?.stringValue
        let path = arguments["path"]?.stringValue
        switch op {
        case "targets":
            return output(await provider.targets())
        case "dom_summary":
            let maxNodes = arguments["maxNodes"]?.numberValue.map { value in
                Int(value)
            } ?? 120
            return output(await provider.domSummary(webviewId: webviewId, path: path,
                                                    maxNodes: max(10, min(1000, maxNodes))))
        case "dom_query":
            guard selector != nil || path != nil else {
                return .error("'selector' or 'path' is required for dom_query")
            }
            return output(await provider.domQuery(webviewId: webviewId, selector: selector, path: path))
        case "why_hidden":
            guard selector != nil || path != nil else {
                return .error("'selector' or 'path' is required for why_hidden")
            }
            return output(await provider.whyHidden(webviewId: webviewId, selector: selector, path: path))
        case "probe":
            guard let x = arguments["x"]?.numberValue, let y = arguments["y"]?.numberValue else {
                return .error("'x' and 'y' are required for probe")
            }
            return output(await provider.probe(webviewId: webviewId, x: x, y: y))
        case "page_source":
            let kind = arguments["kind"]?.stringValue ?? "html"
            guard kind == "html" || kind == "resources" else {
                return .error("Unknown kind '\(kind)'. Use 'html' or 'resources'.")
            }
            let maxBytes = arguments["maxBytes"]?.numberValue.map { value in
                Int(value)
            } ?? 65_536
            return output(await provider.pageSource(webviewId: webviewId, kind: kind,
                                                    maxBytes: max(1024, min(524_288, maxBytes))))
        case "eval":
            guard let script = arguments["script"]?.stringValue, !script.isEmpty else {
                return .error("'script' is required for eval")
            }
            let pageWorld = arguments["pageWorld"]?.boolValue ?? false
            return output(await provider.eval(webviewId: webviewId, script: script, inPageWorld: pageWorld))
        case "console_start":
            return output(await provider.consoleStart(webviewId: webviewId))
        case "console_read":
            let limit = arguments["limit"]?.numberValue.map { value in
                Int(value)
            } ?? 100
            let sinceSeq = arguments["sinceSeq"]?.numberValue.map { value in
                UInt64(max(0, value))
            }
            return output(await provider.consoleRead(webviewId: webviewId,
                                                     limit: max(1, min(1000, limit)), sinceSeq: sinceSeq))
        case "console_stop":
            return output(await provider.consoleStop(webviewId: webviewId))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
