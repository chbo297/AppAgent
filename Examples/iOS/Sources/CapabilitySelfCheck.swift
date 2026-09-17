//
//  CapabilitySelfCheck.swift
//  AppAgentDemo
//
//  In-simulator smoke test for the agent's host-introspection + session tools.
//  Runs each capability tool DIRECTLY (no LLM needed) against a live session and
//  returns a human-readable report, so every feature can be exercised and eyeballed
//  in the simulator without a model round-trip.
//

import UIKit

enum CapabilitySelfCheck {

    /// Run every capability tool once and format the results as a report.
    static func run(session: AISession) async -> String {
        var lines: [String] = []
        func section(_ title: String) { lines.append("\n=== \(title) ===") }

        func exec(_ tool: any ToolProtocol, _ args: [String: JSONValue]) async -> String {
            do {
                let out = try await tool.execute(arguments: args, session: session)
                return out.stringValue
            } catch {
                return "throw: \(error.localizedDescription)"
            }
        }

        func trimmed(_ s: String, _ max: Int = 600) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "…(truncated)"
        }

        // 1) Multi-session self-awareness
        section("session_manage / list")
        lines.append(trimmed(await exec(SessionManageTool(), ["op": .string("list")])))

        // 2) UI view hierarchy
        let runtime = RuntimeInspectTool(provider: DefaultRuntimeInspectProvider())
        section("app_runtime_inspect / ui_hierarchy")
        lines.append(trimmed(await exec(runtime, ["op": .string("ui_hierarchy")])))

        // 3) Runtime: class list (filtered) + methods/properties of a known class
        section("app_runtime_inspect / class_list (filter: HostTabBar)")
        lines.append(trimmed(await exec(runtime, ["op": .string("class_list"), "filter": .string("HostTabBar")])))

        section("app_runtime_inspect / property_list (UILabel)")
        lines.append(trimmed(await exec(runtime, ["op": .string("property_list"), "class": .string("UILabel")])))

        // 4) KVC get/set on the top view controller's view
        section("app_runtime_inspect / property_value (view.tag via KVC)")
        lines.append(trimmed(await exec(runtime, ["op": .string("property_value"), "keyPath": .string("view.tag")])))

        // 4b) 可寻址视图树 → 看层级 / 看单个视图运行时状态 / 改尺寸颜色 / 反射调用
        section("app_runtime_inspect / view_tree (maxDepth 3)")
        lines.append(trimmed(await exec(runtime, ["op": .string("view_tree"), "maxDepth": .number(3)]), 900))

        section("app_runtime_inspect / view_info (path 0)")
        lines.append(trimmed(await exec(runtime, ["op": .string("view_info"), "path": .string("0")])))

        section("app_runtime_inspect / view_set (frame + backgroundColor + alpha)")
        lines.append("frame → " + trimmed(await exec(runtime, [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("frame"), "value": .string("0,0,120,80")
        ])))
        lines.append("backgroundColor → " + trimmed(await exec(runtime, [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("backgroundColor"), "value": .string("#3366FF")
        ])))
        lines.append("alpha → " + trimmed(await exec(runtime, [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("alpha"), "value": .string("0.75")
        ])))

        section("app_runtime_inspect / view_invoke (setNeedsLayout)")
        lines.append(trimmed(await exec(runtime, [
            "op": .string("view_invoke"), "path": .string("0"), "selector": .string("setNeedsLayout")
        ])))

        // 4c) 用 JS 改运行时（DefaultHotfixProvider 的 appagent 桥）
        section("app_hotfix / apply JS patch (appagent bridge)")
        let hotfix = HotfixTool(provider: DefaultHotfixProvider())
        lines.append(trimmed(await exec(hotfix, [
            "op": .string("apply"),
            "name": .string("selfcheck-js"),
            "javascript": .string(
                "appagent.log('js patch running');"
                + "var applied = appagent.uiSet('0', 'cornerRadius', '12');"
                + "'js → ' + applied + ' | treeLen=' + appagent.uiTree(2).length;"
            ),
            "applyMode": .string("instant"),
            "summary": .string("selfcheck: JS 改运行时 UI")
        ])))
        lines.append("list → " + trimmed(await exec(hotfix, ["op": .string("list")])))

        // 4d) 会话控制：新建 / 列可用模型 / 换模型 / 清空
        section("session_manage / create + models + set_model + clear")
        let sessions = SessionManageTool()
        let created = await exec(sessions, ["op": .string("create"), "title": .string("selfcheck-new")])
        lines.append("create → " + trimmed(created))
        lines.append("models → " + trimmed(await exec(sessions, ["op": .string("models")]), 400))
        lines.append("set_model(bad ref) → " + trimmed(await exec(sessions, [
            "op": .string("set_model"), "model": .string("nope/none")
        ])))
        if let json = (try? JSONSerialization.jsonObject(with: Data(created.utf8))) as? [String: Any],
           let sid = json["session_id"] as? String {
            lines.append("clear → " + trimmed(await exec(sessions, [
                "op": .string("clear"), "session_id": .string(sid)
            ])))
        }

        // 4e) 调试记录器：确认调用轨迹可查、可导出
        section("debug log / snapshot + export")
        AppAgentDebugLog.shared.record(.info, message: "selfcheck marker")
        lines.append("events=\(AppAgentDebugLog.shared.snapshot().count)")
        lines.append("export tail → " + trimmed(String(AppAgentDebugLog.shared.exportText().suffix(300))))

        // 4f) 思考/执行过程区：在真机运行时渲染一次，确认折叠摘要与展开明细都能出布局
        section("chat activity / collapsed + expanded rendering")
        lines.append(contentsOf: await MainActor.run { activityRenderingReport() })

        // 5) Sandbox file read/write/list
        let sandbox = AppSandboxFileTool()
        section("app_sandbox_file / write + read + list")
        _ = await exec(sandbox, ["op": .string("write"),
                                 "path": .string("Documents/selfcheck.txt"),
                                 "content": .string("hello-selfcheck")])
        lines.append("read → " + trimmed(await exec(sandbox, ["op": .string("read"), "path": .string("Documents/selfcheck.txt")])))
        lines.append("list → " + trimmed(await exec(sandbox, ["op": .string("list"), "path": .string("Documents")])))

        // 6) UserDefaults read/write
        let defaults = AppUserDefaultsTool()
        section("app_user_defaults / write + read")
        _ = await exec(defaults, ["op": .string("write"),
                                  "key": .string("selfcheck_flag"),
                                  "value": .string("42")])
        lines.append("read → " + trimmed(await exec(defaults, ["op": .string("read"), "key": .string("selfcheck_flag")])))

        return lines.joined(separator: "\n")
    }

    /// 在真实 UIKit 运行时里渲染一轮「思考 + 工具执行」过程区：
    /// 分别量折叠态与展开态的高度，确认摘要行与明细都真的排上了版。
    @MainActor
    private static func activityRenderingReport() -> [String] {
        var timeline = AppAgentActivityTimeline(startedAt: Date().addingTimeInterval(-2.5))
        timeline.appendThinking("先确认设置页的模型来源\n再决定要不要读取文件")
        timeline.startTool(id: "call-1", name: "file_read", argumentsPreview: "path=Documents/selfcheck.txt")
        timeline.finishTool(id: "call-1", resultPreview: "hello-selfcheck")
        timeline.appendThinking("信息够了，可以给结论")

        var lines: [String] = []
        lines.append("running header → \(timeline.headerTitle())")
        lines.append("summary → \(timeline.headerSummary ?? "(nil)")")

        timeline.finish()
        lines.append("finished header → \(timeline.headerTitle()) · steps=\(timeline.stepCount)")

        func height(expanded: Bool) -> CGFloat {
            let cell = ChatMessageCell(style: .default, reuseIdentifier: ChatMessageCell.reuseIdentifier)
            cell.frame = CGRect(x: 0, y: 0, width: 390, height: 1)
            cell.configure(with: ChatMessage(
                role: .assistant,
                text: "最终结果：设置页已经能实测模型可用性。",
                activity: timeline,
                isActivityExpanded: expanded
            ))
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            return cell.contentView
                .systemLayoutSizeFitting(
                    CGSize(width: 390, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
        }

        let collapsed = height(expanded: false)
        let expanded = height(expanded: true)
        lines.append(String(format: "collapsed height=%.1f, expanded height=%.1f", collapsed, expanded))
        lines.append(expanded > collapsed ? "展开明细生效 ✓" : "展开未增高 ✗")
        return lines
    }

    /// Build a throwaway agent + session so the self-check can run even when the

    /// demo has no usable provider config (tool.execute never calls the model).
    ///
    /// `AISession.agentMask` holds only a *weak* back-reference to its agent, so
    /// the ephemeral agent must be retained for the lifetime of the check —
    /// otherwise `session_manage` sees a detached session. We park it in a static
    /// strong holder.
    private static var retainedEphemeralAgent: AIAgent?

    static func ephemeralSession() async -> AISession {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "selfcheck",
            profile: AIAgentProfile(identity: "selfcheck"),
            sessionStorage: InMemorySessionStorage()
        )
        retainedEphemeralAgent = agent
        return await agent.createSession(title: "自检")
    }
}

/// Weak shared handle to the demo's agent + active session so the host UI (a
/// button on the Home tab) can run the self-check without threading references
/// through the whole view hierarchy.
enum DemoAgentHolder {
    static weak var agent: AIAgent?
    static var currentSessionId: String?

    static func currentSession() -> AISession? {
        guard let agent else { return nil }
        if let id = currentSessionId, let s = agent.session(id: id) { return s }
        return agent.allSessions.first
    }
}
