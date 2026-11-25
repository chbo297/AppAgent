//
//  AppAgentWorkspaceTool.swift
//  AppAgent — 给模型用的工作区工具：本会话工作区的显隐和 H5 页面内容
//
//  只改执行它的那个会话的数据。后台会话也能改，切到它时界面才按数据刷新。
//  插槽里的内容（宿主视图，例如百度地图的子图区）由宿主自己的工具操作。
//  宿主注册时说明自己有哪些插槽（`AppAgentWorkspaceSlot`），并补一段只属于自己的用法（`hostGuide`）。
//

#if canImport(UIKit)
import UIKit

public struct AppAgentWorkspaceTool: ToolProtocol {
    public let name = "workspace"
    public let description: String
    public let usageGuide: String?
    public let parameters: Tool.Schema
    public let group = "app-workspace"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    static let operations = ["read", "write", "edit", "delete", "set_state", "clear", "show", "hide"]

    private let slotNames: [String]

    /// - Parameters:
    ///   - slots: 宿主提供的插槽，通常就是 `AppAgentWorkspaceHost.workspaceSlots`；空表示只有 H5 层。
    ///   - hostGuide: 接在通用用法后面的宿主补充说明（`hostApp.invoke` 可调的动作、示例等）。
    public init(slots: [AppAgentWorkspaceSlot] = [], hostGuide: String? = nil) {
        var description = """
            This conversation's workspace: a custom H5 page shown over the App, for what no existing App page or \
            small change to one can do (layouts, comparisons, interactive panels, demos of a new structure). \
            Each conversation has its own workspace; background conversations may edit theirs, and it shows when \
            that conversation is on screen. The first call returns the full usage guide.
            """
        if !slots.isEmpty {
            description += "\nUnder the H5 layer the App can show one native slot view at a time:"
            for slot in slots {
                description += "\n- \(slot.name): \(slot.summary)"
            }
        }
        self.description = description
        slotNames = slots.map(\.name)
        usageGuide = hostGuide.map { guide in
            Self.guide + "\n\n" + guide
        } ?? Self.guide
        parameters = Tool.Schema(properties: [
            "op": .string(description: "read / write / edit / delete / set_state / clear change the H5 page; "
                          + "show / hide change what is visible.", enumValues: Self.operations),
            "path": .string(description: "read: return this file's full text. edit: file to edit."),
            "files": .object(description: "write: {path: text}. Entry is index.html; css, js, json, svg by relative path."),
            "title": .string(description: "write: page title."),
            "replace_all": .boolean(description: "write: true removes files not listed in files."),
            "old": .string(description: "edit: exact text to replace; must occur exactly once."),
            "new": .string(description: "edit: replacement text."),
            "paths": .array(description: "delete: files to remove.", items: .string()),
            "state": .object(description: "set_state: {key: string or null}. Null removes the key. "
                             + "The page reads appAgent.workspace.state and gets an appagent:state event."),
            "target": .string(description: "show / hide: omit for the whole workspace; h5 for the H5 layer; "
                              + "a slot name for that slot (showing a slot hides the other slots).",
                              enumValues: ["h5"] + slots.map(\.name))
        ], required: ["op"])
    }

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        arguments["op"]?.stringValue == "read" ? .safe : .moderate
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        guard Self.operations.contains(op) else {
            return .error("unknown workspace operation")
        }
        let enabled = await MainActor.run {
            AppAgentWorkspace.shared.isEnabled()
        }
        guard op == "read" || enabled else {
            return .error("workspace is turned off in this app")
        }
        if op == "read", let path = arguments["path"]?.stringValue {
            guard let text = session.workspace.h5.files[path] else {
                return .error("no file at \(path)")
            }
            return .json(.object(["path": .string(path), "text": .string(text)]))
        }
        if op != "read" {
            do {
                try session.updateWorkspace { workspace in
                    try apply(op, arguments: arguments, to: &workspace)
                }
            } catch {
                return .error(error.localizedDescription)
            }
        }
        let sessionId = session.id
        let live = await MainActor.run {
            AppAgentWorkspace.shared.liveReport(sessionId: sessionId)
        }
        return .json(Self.overview(session.workspace, live: live))
    }

    private func apply(_ op: String, arguments: [String: JSONValue], to workspace: inout SessionWorkspace) throws {
        switch op {
        case "write":
            guard case .object(let raw)? = arguments["files"] else {
                throw SessionWorkspaceError("write requires files")
            }
            var files: [String: String] = arguments["replace_all"] == .bool(true) ? [:] : workspace.h5.files
            for (path, value) in raw {
                guard let text = value.stringValue else {
                    throw SessionWorkspaceError("files values must be text")
                }
                files[path] = text
            }
            workspace.h5.files = files
            if let title = arguments["title"]?.stringValue {
                workspace.title = title
            }
        case "edit":
            guard let path = arguments["path"]?.stringValue,
                  let old = arguments["old"]?.stringValue, !old.isEmpty,
                  let new = arguments["new"]?.stringValue else {
                throw SessionWorkspaceError("edit requires path, old and new")
            }
            guard let text = workspace.h5.files[path] else {
                throw SessionWorkspaceError("no file at \(path)")
            }
            let count = text.components(separatedBy: old).count - 1
            guard count == 1 else {
                throw SessionWorkspaceError("old text occurs \(count) times in \(path); it must occur exactly once")
            }
            workspace.h5.files[path] = text.replacingOccurrences(of: old, with: new)
        case "delete":
            guard case .array(let raw)? = arguments["paths"] else {
                throw SessionWorkspaceError("delete requires paths")
            }
            for value in raw {
                if let path = value.stringValue {
                    workspace.h5.files.removeValue(forKey: path)
                }
            }
        case "set_state":
            guard case .object(let raw)? = arguments["state"] else {
                throw SessionWorkspaceError("set_state requires state")
            }
            for (key, value) in raw {
                if value == .null {
                    workspace.h5.state.removeValue(forKey: key)
                } else if let text = value.stringValue {
                    workspace.h5.state[key] = text
                } else {
                    throw SessionWorkspaceError("state values must be strings or null; JSON.stringify objects first")
                }
            }
        case "clear":
            workspace.h5 = SessionWorkspace.H5()
            workspace.title = ""
        case "show", "hide":
            let shown = op == "show"
            switch arguments["target"]?.stringValue {
            case nil:
                workspace.isShown = shown
            case "h5"?:
                workspace.h5.isShown = shown
            case let name? where slotNames.contains(name):
                if shown {
                    for other in workspace.slots.keys where other != name {
                        workspace.slots[other]?.isShown = false
                    }
                }
                var slot = workspace.slots[name] ?? SessionWorkspace.Slot()
                slot.isShown = shown
                workspace.slots[name] = slot
            case let name?:
                throw SessionWorkspaceError("unknown target \(name); use h5, a slot name, or omit target")
            }
            if shown, !workspace.hasContent {
                throw SessionWorkspaceError("nothing to show yet: write index.html and show h5, or show a slot")
            }
        default:
            break
        }
    }

    /// 给模型的概览：文件只列路径和大小，插槽状态只列 key（宿主的数据，由宿主工具读）。
    private static func overview(_ workspace: SessionWorkspace, live: JSONValue?) -> JSONValue {
        let files = workspace.h5.files.keys.sorted().map { path in
            JSONValue.object([
                "path": .string(path),
                "bytes": .number(Double(workspace.h5.files[path]?.utf8.count ?? 0))
            ])
        }
        var result: [String: JSONValue] = [
            "shown": .bool(workspace.isShown),
            "onScreen": .bool(live != nil),
            "title": .string(workspace.title),
            "h5": .object([
                "shown": .bool(workspace.h5.isShown),
                "files": .array(files),
                "state": .object(workspace.h5.state.mapValues(JSONValue.string))
            ]),
            "slots": .object(workspace.slots.mapValues { slot in
                .object([
                    "shown": .bool(slot.isShown),
                    "stateKeys": .array(slot.state.keys.sorted().map(JSONValue.string))
                ])
            })
        ]
        if let live {
            result["live"] = live
        }
        return .object(result)
    }
}

// MARK: - 使用手册（第一次调用时随结果交给模型，见 ToolProtocol.usageGuide）

extension AppAgentWorkspaceTool {
    static let guide = """
        LIFECYCLE
        - The workspace has the H5 page (default shown) and, if the App provides them, native slot views under
          it (default hidden; one shown at a time). show / hide with target h5 or a slot name toggle that layer;
          without target they toggle the whole workspace and keep the layer settings.
        - write saves files without showing them; call show afterwards. A background conversation may edit and
          show its own workspace; it appears when that conversation is on screen. onScreen in a result says
          whether the page is on screen now; live then reports touch, loadFailure and scriptErrors.
        - To let the user look at the page, collapse the chat panel with session op chat_panel state collapsed.

        FILES
        - index.html is the entry (at most 1 MiB); other css, js, json or svg files by relative path (each at
          most 512 KiB, 4 MiB and 128 files in total). Fetching the network is blocked.
        - write merges files by path (replace_all true drops the others); edit replaces one exact snippet; read
          with path returns a file; the page reloads by itself when its files change.

        STATE
        - Page state is text by key: the page reads appAgent.workspace.state[key] and writes
          appAgent.workspace.setState(key, value) (value a string or null; JSON.stringify objects).
          At most 128 KiB in total. set_state changes it from here without a reload; the page receives an
          appagent:state event with the new state.

        APP ACTIONS
        - window.hostApp.invoke(name, args) runs an App action the App allows (see the App's notes below) and
          returns a Promise of {ok: true, result} or {ok: false, error}. Call it only from a tap handler; calls
          without a user tap are rejected. One call runs at a time. The workspace hides first so the App page shows.

        DEMOS
        - Use sample data only when the user explicitly asks for a prototype or demo. Label each sample on its
          card with "示例" and keep fictional items out of real recommendations; actions on a sample stay on the page.
        - Keep general App actions and local interactions (tabs, filters, expand) working. Show "演示中暂未接入"
          inline for unfinished controls, without an alert or toast. Mention briefly in the reply that the page is a demo.

        LAYOUT AND DESIGN
        - A native collapse button (36 pt circle) floats at the top-left with a 10 pt inset; keep the top-left
          56x56 CSS px free, for example padding-left: 56px on the first header.
        - One clear job per screen. Compact panels with their own background (white at about 0.9 opacity,
          12-16 px radius); -apple-system font, body 14-15 px, titles 17 px semibold, 8 px spacing grid; one
          accent color. Avoid full-screen gradients, emoji-heavy titles, stacks of identical cards and shadows on everything.
        - With a slot shown keep its area transparent: no full-screen background or wrapper with a background.

        TOUCH (a slot shown)
        - By default transparent areas pass touches to the native view, and anything that paints (background,
          border, shadow, text, image, form control) or scrolls keeps its touches. pointer-events: none never blocks.
        - For exact control call appAgent.workspace.setTouchRegions(regions) with the native view areas in CSS
          viewport px: each region is [x, y, w, h] or {points: [[x, y], ...]} (3-256 points), up to 64. The
          page then owns the regions until it calls setTouchRegions again ([] passes nothing); only a viewport
          resize clears them, followed by an appagent:layout event. useAutoTouchRegions() returns to the
          automatic mode.
        - Check live.touch.passesToSlot before telling the user the native view can be dragged.
        """
}

#endif
