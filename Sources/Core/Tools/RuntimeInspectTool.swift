//
//  RuntimeInspectTool.swift
//  AppAgent — 宿主能力层
//
//  宿主 app 的原生运行时能力，按用途拆成两个工具，共用同一个 RuntimeInspectProvider：
//    · app_ui（`RuntimeInspectTool.ui(provider:)`）：看界面、像用户一样操作（点按、切页、滚动）。
//      日常常用，一直暴露给模型。
//    · app_runtime_inspect（`RuntimeInspectTool(provider:)`）：读写内存里的对象、反射调用、改视图属性。
//      属于调试能力，放在按需加载的 debug 组。
//

import Foundation

public struct RuntimeInspectTool: ToolProtocol {
    /// 两个工具各自负责的能力。
    public enum Facet: Sendable {
        /// 看界面与模拟用户操作。
        case ui
        /// 内存对象读写、反射与视图属性修改。
        case objects
    }

    public static let uiToolName = "app_ui"
    public static let objectsToolName = "app_runtime_inspect"

    public static let uiOperations = ["ui_hierarchy", "view_tree", "view_info", "view_activate", "page_navigate", "page_scroll"]
    /// 两个工具都能看界面：app_ui 说页面名和控件文字，app_runtime_inspect 带类名和页面说明。
    public static let objectOperations = ["ui_hierarchy", "view_tree", "view_info",
                                          "property_value", "class_list", "method_list", "property_list",
                                          "property_set", "view_set", "view_invoke", "invoke"]

    public let facet: Facet

    public var name: String {
        facet == .ui ? Self.uiToolName : Self.objectsToolName
    }

    public var description: String {
        switch facet {
        case .ui:
            return """
                See and operate the host app's native screen like a user. Use it to find which page is \
                showing, what it is for and what is on it (ui_hierarchy, view_tree, view_info), and to tap a \
                control (view_activate), switch tab / go back / dismiss (page_navigate) or scroll \
                (page_scroll). Pages are named by what they are, not by code. Not for content inside a web \
                page or for pixels (use screenshot). The first call returns the full usage guide.
                """
        case .objects:
            return """
                Debug the host app's runtime: see the screen with class names (ui_hierarchy, view_tree, \
                view_info), read values the app holds in memory such as page state or a \
                loaded server response (property_value), list classes, methods and properties, and — only \
                when the user asks to change or debug the app — edit a view or property (view_set, \
                property_set) or call a method (view_invoke, invoke; asks the user first). View paths come \
                from app_ui. The first call returns the full usage guide.
                """
        }
    }

    public var usageGuide: String? {
        facet == .ui ? Self.uiGuide : Self.objectsGuide
    }

    public var parameters: Tool.Schema {
        switch facet {
        case .ui:
            return Tool.Schema(
                properties: [
                    "scope": HostInspectionScope.parameter,
                    "op": .string(description: "Operation; see the usage guide for what each one needs.",
                                  enumValues: Self.uiOperations),
                    "detail": .string(description: "ui_hierarchy only. 'summary' (default) or 'full' (very large).",
                                      enumValues: ["summary", "full"],
                                      defaultValue: .string("summary")),
                    "path": .string(description: "View path from ui_hierarchy / view_tree output, e.g. \"0/2/1\" (default window) or \"W1:0/2/1\" (window W1). Used by view_tree, view_info, view_activate and optionally page_scroll."),
                    "maxDepth": .integer(description: "view_tree depth limit (default 12).", minimum: 1, maximum: 40),
                    "target": .string(description: "page_navigate only: \"tab:<title or index>\", \"pop\", \"popToRoot\" or \"dismiss\"."),
                    "event": .string(description: "view_activate only: UIControl event to send (default touchUpInside).",
                                     enumValues: ["touchUpInside", "touchDown", "touchUpOutside",
                                                  "valueChanged", "primaryActionTriggered"]),
                    "direction": .string(description: "page_scroll only, required.",
                                         enumValues: ["up", "down", "left", "right"]),
                    "amount": .number(description: "page_scroll only: screens to scroll (default 1).")
                ],
                required: ["op"]
            )
        case .objects:
            return Tool.Schema(
                properties: [
                    "scope": HostInspectionScope.parameter,
                    "op": .string(description: "Operation; see the usage guide for what each one needs.",
                                  enumValues: Self.objectOperations),
                    "_why": .string(description: "One sentence shown to the user when approval is needed. Give it for view_invoke / invoke."),
                    "path": .string(description: "View path from ui_hierarchy / view_tree output (here or in app_ui). Used by view_tree, view_info, view_set and view_invoke."),
                    "detail": .string(description: "ui_hierarchy only. 'summary' (default) or 'full' (very large).",
                                      enumValues: ["summary", "full"],
                                      defaultValue: .string("summary")),
                    "maxDepth": .integer(description: "view_tree depth limit (default 12).", minimum: 1, maximum: 40),
                    "key": .string(description: "view_set property: frame, bounds, center, alpha, hidden, cornerRadius, backgroundColor, text; other names go through KVC."),
                    "value": .string(description: "New value for view_set / property_set, always as a string: rect \"x,y,w,h\", point \"x,y\", color \"#RRGGBB\" or \"#RRGGBBAA\", bool \"true\"/\"false\", numbers as text."),
                    "class": .string(description: "Class name for method_list / property_list / invoke, and optional root for property_value / property_set. Short Swift names work."),
                    "keyPath": .string(description: "property_value / property_set key path from the top visible page (or from 'class'), e.g. \"viewModel.items.0.name\" or \"tabBarController.selectedIndex\"."),
                    "filter": .string(description: "class_list only, required: class-name substring such as the app's prefix."),
                    "selector": .string(description: "view_invoke / invoke selector, e.g. \"setNeedsLayout\" or \"setTitle:forState:\"."),
                    "arguments": .array(description: "view_invoke / invoke arguments, one JSON value per selector argument, e.g. [\"Hi\", 0]. Omit for none.")
                ],
                required: ["op"]
            )
        }
    }

    public let group = "host-runtime"

    /// 调试能力按需加载；看界面与模拟用户操作一直暴露。
    public var deferredGroup: String? {
        facet == .objects ? ToolGroups.debug : nil
    }

    public let safetyLevel: Tool.SafetyLevel = .moderate

    /// 看和改在这个工具里差别巨大：`ui_hierarchy` 是纯读，`view_set` 会直接改掉线上
    /// 界面，`invoke` 能反射调任意 selector。用同一个静态级别的后果我自己撞过一次
    /// （自检把 demo 的 tab bar 改成了半透明蓝块，全程没有任何拦截）。
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "ui_hierarchy", "view_tree", "view_info",
             "class_list", "method_list", "property_list", "property_value":
            return .safe
        case "view_set", "property_set":
            return .moderate
        // 模拟用户操作等价于用户自己点/滑了一下：宿主的 delegate、埋点、拦截逻辑全都照常
        // 跑，能做的事不超过一个真实用户。所以按普通改动对待，不再弹授权卡；
        // `toolMutationPolicy == .readOnly` 的硬边界仍然拦得住它们。
        case "view_activate", "page_navigate", "page_scroll":
            return .moderate
        case "view_invoke", "invoke":
            return .sensitive
        default:
            return .moderate
        }
    }

    private let provider: RuntimeInspectProvider

    /// 调试工具 app_runtime_inspect：内存对象读写、反射、视图属性修改。
    public init(provider: RuntimeInspectProvider) {
        self.init(provider: provider, facet: .objects)
    }

    /// 日常工具 app_ui：看界面、模拟用户操作。
    public static func ui(provider: RuntimeInspectProvider) -> RuntimeInspectTool {
        RuntimeInspectTool(provider: provider, facet: .ui)
    }

    init(provider: RuntimeInspectProvider, facet: Facet) {
        self.provider = provider
        self.facet = facet
    }

    /// `view_invoke` 里有两类拒绝理由不需要执行就能判定：选择器不在受限作用域的白名单里，
    /// 以及签名带原始类型（反射只能传对象）。把它们提到授权之前，用户就不用再为一个
    /// 注定失败的调用点「允许」——真机实测那一次点掉了 4.9 秒，点完才报错。
    ///
    /// 提权作用域（appagent / all）不在这里判：它本身要走一次授权，那是它应有的流程。
    public func preflightRejection(for arguments: [String: JSONValue], session: AISession) async -> String? {
        guard facet == .objects, arguments["op"]?.stringValue == "view_invoke" else {
            return nil
        }
        guard (arguments["scope"]?.stringValue ?? "host") == "host" else { return nil }
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else { return nil }
        guard let selector = arguments["selector"]?.stringValue, !selector.isEmpty else {
            return "'selector' is required for view_invoke"
        }
        let argsJSON = Self.invocationArgumentsJSON(arguments)
        let argCount = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [Any])?.count ?? 0
        // 预检本身不申请授权，所以直接用默认的 host 作用域上下文。
        return await provider.invocationRejection(
            path: path, className: nil, selector: selector,
            argumentCount: argCount, context: HostInspectionContext()
        )
    }

    /// The provider reports failures as sentinel strings. Surface those as tool
    /// errors so the model cannot mistake "(class not found: X)" for an answer.
    private func output(_ text: String) -> Tool.Output {
        let failurePrefixes = [
            "(class not found", "(no view at path", "(selector ", "(no target)",
            "(no windows)", "(no key window)", "(no target object for KVC",
            "Invoke failed:", "Failed to set ", "Failed to read ", "Inspection denied:"
        ]
        return failurePrefixes.contains(where: { text.hasPrefix($0) }) ? .error(text) : .text(text)
    }

    /// 写类操作（`view_set` / `property_set`）的判定反过来做：**成功必须以 `OK.` 开头**。
    /// 靠「失败前缀清单」认失败太脆——provider 的失败文案有一堆形态
    /// （`Invalid rect '…'`、`Invalid alpha '…'`、`UIView has no text/title to set.`…），
    /// 漏一个就会把一次没生效的修改当成成功交给模型。
    private func mutationOutput(_ text: String) -> Tool.Output {
        text.hasPrefix("OK.") ? .text(text) : .error(text)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let owned = facet == .ui ? Self.uiOperations : Self.objectOperations
        guard owned.contains(op) else {
            let other = facet == .ui ? Self.objectOperations : Self.uiOperations
            if other.contains(op) {
                let otherName = facet == .ui ? Self.objectsToolName : Self.uiToolName
                return .error("op '\(op)' belongs to \(otherName).")
            }
            return .error("unknown op: \(op)")
        }
        let className = arguments["class"]?.stringValue
        guard let depth = ToolArgumentValues.integer(arguments, "maxDepth", default: 12, range: Int.min...Int.max) else {
            return .error("'maxDepth' must be a finite, representable integer.")
        }
        let context = try await HostInspectionAccess.context(
            arguments: arguments, session: session, tool: name,
            isMutation: safetyLevel(for: arguments) != .safe
        ).presenting(facet == .ui ? .product : .implementation)
        switch op {
        case "ui_hierarchy":
            // 默认只给摘要。全量在真实 app 里几十 KB，一次就能把上下文吃光，
            // 需要细节应该顺着摘要里的 path 走 view_tree / view_info 二次调用。
            let detail = arguments["detail"]?.stringValue ?? "summary"
            switch detail {
            case "summary":
                return output(await provider.uiHierarchySummary(context: context))
            case "full":
                return output(await provider.uiHierarchy(context: context))
            default:
                return .error("Unknown detail '\(detail)'. Use 'summary' (default) or 'full'.")
            }
        case "view_tree":
            let path = arguments["path"]?.stringValue ?? ""
            return output(await provider.viewSubtree(path: path, maxDepth: max(1, min(40, depth)), context: context))
        case "view_info":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_info") }
            return output(await provider.viewInfo(path: path, context: context))
        case "view_set":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_set") }
            guard let key = arguments["key"]?.stringValue else { return .error("'key' is required for view_set") }
            guard let value = Self.scalarText(arguments["value"]) else {
                return .error("'value' is required for view_set")
            }
            return mutationOutput(await provider.setViewValue(path: path, key: key, value: value, context: context))
        case "view_invoke":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_invoke") }
            guard let selector = arguments["selector"]?.stringValue else { return .error("'selector' is required for view_invoke") }
            let argsJSON = Self.invocationArgumentsJSON(arguments)
            return output(await provider.invokeOnView(path: path, selector: selector, argumentsJSON: argsJSON, context: context))

        case "view_activate":
            guard let path = arguments["path"]?.stringValue else { return .error("'path' is required for view_activate") }
            return mutationOutput(await provider.activateView(
                path: path, event: arguments["event"]?.stringValue, context: context
            ))
        case "page_navigate":
            guard let target = arguments["target"]?.stringValue else {
                return .error("'target' is required for page_navigate (e.g. \"tab:Profile\", \"pop\", \"dismiss\")")
            }
            return mutationOutput(await provider.navigatePage(target: target, context: context))
        case "page_scroll":
            guard let direction = arguments["direction"]?.stringValue else {
                return .error("'direction' is required for page_scroll (up / down / left / right)")
            }
            return mutationOutput(await provider.scrollPage(
                path: arguments["path"]?.stringValue,
                direction: direction,
                amount: arguments["amount"]?.numberValue,
                context: context
            ))
        case "class_list":
            // 无过滤时进程内 ObjC 类是万级规模，直接返回等于烧掉整个上下文。
            let filter = arguments["filter"]?.stringValue
            guard let filter, !filter.isEmpty else {
                return .error("'filter' is required for class_list — the process has many classes. "
                              + "Pass a substring such as the app's class prefix.")
            }
            let list = await provider.classList(matching: filter, context: context)
            return .text(list.isEmpty ? "(no class matches '\(filter)')" : list.joined(separator: "\n"))
        case "method_list":
            guard let className else { return .error("'class' is required for method_list") }
            return output((await provider.methodList(ofClass: className, context: context)).joined(separator: "\n"))
        case "property_list":
            guard let className else { return .error("'class' is required for property_list") }
            return output((await provider.propertyList(ofClass: className, context: context)).joined(separator: "\n"))
        case "property_value":
            guard let keyPath = arguments["keyPath"]?.stringValue else {
                return .error("'keyPath' is required for property_value")
            }
            let value = await provider.propertyValue(keyPath: keyPath, ofClass: className, context: context)
            guard let value else { return .text("(nil)") }
            return output(value)
        case "property_set":
            guard let keyPath = arguments["keyPath"]?.stringValue else {
                return .error("'keyPath' is required for property_set")
            }
            guard let value = Self.scalarText(arguments["value"]) else {
                return .error("'value' is required for property_set")
            }
            return mutationOutput(await provider.setPropertyValue(keyPath: keyPath, value: value, ofClass: className, context: context))
        case "invoke":
            guard let className, let selector = arguments["selector"]?.stringValue else {
                return .error("'class' and 'selector' are required for invoke")
            }
            let argsJSON = Self.invocationArgumentsJSON(arguments)
            return output(await provider.invoke(className: className, selector: selector, argumentsJSON: argsJSON, context: context))
        default:
            return .error("unknown op: \(op)")
        }
    }

    /// 反射参数以 typed `arguments` 数组为准；旧调用方的 `argumentsJSON` 字符串、
    /// 以及模型把数组写成 JSON 字符串塞进 `arguments`，都照旧接受。
    static func invocationArgumentsJSON(_ arguments: [String: JSONValue]) -> String {
        if let list = arguments["arguments"]?.arrayValue,
           let data = try? JSONEncoder().encode(list),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return arguments["arguments"]?.stringValue ?? arguments["argumentsJSON"]?.stringValue ?? "[]"
    }

    /// `value` 协议上是字符串；模型常把 0.5 / true 直接写成 JSON 数字或布尔，按同义文本收下。
    static func scalarText(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 {
                return String(Int(number))
            }
            return String(number)
        default:
            return nil
        }
    }
}

extension RuntimeInspectTool {
    static let uiGuide = """
        SCOPE
        - Default scope 'host' covers the host app's UI and hides AppAgent's own UI. 'appagent' / 'all' \
        need a separate approval; detail='full' never widens scope.
        - UI covers the bound scene (or the only active scene). W<n> are stable window handles.

        SEE WHAT IS ON SCREEN
        - ui_hierarchy: windows, the page (view controller) stack and the meaningful views (text, \
        controls, host classes). Wrapper layers are skipped; big subtrees collapse to "⊞ N views" with \
        the path to expand. Start here. detail='full' dumps everything and is very large.
        - view_tree (path?, maxDepth?): expand one subtree; omit path for the window root.
        - view_info (path): one view's live state (kind, page, frame, colors, text, subview count).
        - Pages are named by the host's page names and purposes, falling back to the page title; a class \
        name appears only for a page the host never described. For class names and code-level detail, \
        use app_runtime_inspect (debug group).
        - Typical flow: ui_hierarchy → view_tree on the interesting path → view_info → act.

        ACT LIKE THE USER
        - page_navigate (target): "tab:Profile" / "tab:2" / "pop" / "popToRoot" / "dismiss". Tab \
        selection runs the host's tab-bar delegate; a refused selection is reported. First choice for \
        "go to page X".
        - view_activate (path, event?): the nearest UIControl ancestor gets sendActions(event), \
        otherwise accessibilityActivate(). No touches are synthesized; it fails if neither exists.
        - page_scroll (direction, amount?, path?): scrolls the nearest UIScrollView by screens, \
        otherwise accessibilityScroll.
        - Every action reports whether the visible page actually changed, so a no-op shows up at once.
        """

    static let objectsGuide = """
        SCOPE
        - Default scope 'host' covers the host app's objects and classes. 'appagent' / 'all' need a \
        separate approval.
        - Reads work on any host object: property_value walks properties, dictionary keys and array \
        indexes. Writes stay on UI object chains; limited scopes reject class singletons and arbitrary \
        selectors. View paths come from app_ui ui_hierarchy / view_tree.

        SEE THE SCREEN AS CODE
        - ui_hierarchy / view_tree / view_info: same paths as app_ui, but with class names, superclasses \
        and each page's class next to its product name and purpose.

        READ APP DATA
        - property_value (keyPath, class?): starts from the innermost visible page (the selected child \
        in a tab bar app; reach containers with "tabBarController.…" / "navigationController.…"). \
        Collections and server payloads can be read whole or step by step, e.g. "payload.shop.hours", \
        "items.0.name".
        - class_list (filter) (filter required; the process has tens of thousands of classes), \
        method_list (class), property_list (class).

        CHANGE THE APP (only when the user asked to change or debug it)
        - view_set (path, key, value): keys frame / bounds / center / alpha / hidden / cornerRadius / \
        backgroundColor / text, anything else via KVC. The result shows the previous value; write it \
        back to undo.
        - property_set (keyPath, value, class?): KVC write. Values are strings; numbers and true/false \
        are converted.
        - view_invoke (path, selector, arguments?, _why) / invoke (class, selector, arguments?, _why): \
        reflection, asks the user first. Arguments and return values must be objects: selectors that \
        take or return primitives (setTag:, isHidden, frame) are rejected; use view_set / property_set / \
        app_ui view_info for those.
        - Every write reports whether the visible page actually changed, so a no-op shows up at once.
        """
}
