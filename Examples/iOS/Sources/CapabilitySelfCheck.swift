//
//  CapabilitySelfCheck.swift
//  AppAgentDemo
//
//  In-simulator smoke test for every tool the agent ships with. Runs each tool
//  DIRECTLY (no LLM round-trip) against a live session, tallies pass/fail per
//  check, and returns a human-readable report. Launch with `-run-selfcheck`
//  and the report is written to Documents/selfcheck-report.txt plus emitted to
//  the log in chunks (os_log truncates a single long message), so a script
//  driving the simulator can assert on it.
//
//  Every check runs behind a timeout so one hanging tool can never wedge the
//  whole run — a stuck check is reported as a failure and the run continues.
//

import UIKit

enum CapabilitySelfCheck {

    /// What a check must return to count as a pass.
    enum Expectation {
        /// Must return a non-error output.
        case ok
        /// Must return an error containing this substring (a documented degradation,
        /// e.g. a host provider that was deliberately not injected).
        case errorContains(String)
        /// Either outcome is acceptable; the check only asserts it terminates
        /// within the budget (used where success depends on a live model).
        case completes
    }

    static let beginMarker = "APPAGENT_SELFCHECK_BEGIN"
    static let endMarker = "APPAGENT_SELFCHECK_END"
    static let summaryMarker = "APPAGENT_SELFCHECK_SUMMARY"
    static let reportFileName = "selfcheck-report.txt"

    /// Per-check wall clock budget. Anything slower is a bug worth surfacing.
    private static let checkTimeout: TimeInterval = 8

    // MARK: - Recorder

    /// Accumulates report lines and the pass/fail tally.
    private final class Recorder {
        private(set) var lines: [String] = []
        private(set) var failures: [String] = []
        private(set) var passed = 0

        func section(_ title: String) { lines.append("\n=== \(title) ===") }
        func note(_ text: String) { lines.append(text) }

        func record(_ label: String, ok: Bool, detail: String) {
            if ok { passed += 1 } else { failures.append(label) }
            lines.append("\(ok ? "✓" : "✗") \(label) → \(detail)")
        }

        var total: Int { passed + failures.count }
    }
    // MARK: - Primitives

    /// Race `work` against the per-check budget. Returns nil on timeout.
    private static func withBudget<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(checkTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func trimmed(_ s: String, _ max: Int = 400) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…(truncated)"
    }

    /// Drop a supporting file in Documents alongside the report.
    private static func writeArtifact(_ name: String, _ contents: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? contents.write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Execute one tool call, judge it against `expect`, and record the outcome.
    private static func check(
        _ rec: Recorder,
        _ label: String,
        _ tool: any ToolProtocol,
        _ args: [String: JSONValue],
        expect: Expectation = .ok,
        session: AISession,
        preview: Int = 400
    ) async {
        let outcome = await withBudget { () async throws -> (Bool, String) in
            do {
                let out = try await tool.execute(arguments: args, session: session)
                switch out {
                case .error(let message):
                    return (false, message)
                case .text(let text):
                    return (true, text)
                case .json:
                    return (true, out.stringValue)
                }
            } catch {
                return (false, "throw: \(error.localizedDescription)")
            }
        }

        guard let (isSuccess, body) = outcome else {
            rec.record(label, ok: false, detail: "TIMEOUT after \(Int(checkTimeout))s")
            return
        }

        switch expect {
        case .ok:
            rec.record(label, ok: isSuccess, detail: trimmed(body, preview))
        case .errorContains(let needle):
            let matched = !isSuccess && body.localizedCaseInsensitiveContains(needle)
            rec.record(label, ok: matched,
                       detail: (matched ? "expected error: " : "unexpected: ") + trimmed(body, preview))
        case .completes:
            rec.record(label, ok: true,
                       detail: (isSuccess ? "ok: " : "degraded: ") + trimmed(body, preview))
        }
    }
    // MARK: - Runner

    /// Run every tool once and format the results as a report.
    static func run(session: AISession) async -> String {
        let rec = Recorder()
        let startedAt = Date()

        await checkRuntimeInspection(rec, session: session)
        await checkHostStorage(rec, session: session)
        await checkSandboxFileTools(rec, session: session)
        await checkCoreTools(rec, session: session)
        await checkSkills(rec, session: session)
        await checkSessionTools(rec, session: session)
        await checkHostProviderTools(rec, session: session)
        await checkDebugAndRendering(rec)

        let elapsed = Date().timeIntervalSince(startedAt)
        var out = rec.lines
        out.append("\n=== SUMMARY ===")
        out.append(String(format: "total=%d ok=%d fail=%d elapsed=%.1fs",
                          rec.total, rec.passed, rec.total - rec.passed, elapsed))
        if !rec.failures.isEmpty {
            out.append("failed: " + rec.failures.joined(separator: ", "))
        }
        let report = out.joined(separator: "\n")
        persist(report)
        return report
    }

    /// Write the report next to the app's Documents so it survives the run, and
    /// emit it to the log in os_log-sized chunks plus a one-line summary.
    private static func persist(_ report: String) {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent(reportFileName)
            try? report.write(to: url, atomically: true, encoding: .utf8)
            NSLog("APPAGENT_SELFCHECK_FILE %@", url.path)
        }

        // os_log truncates long messages, so chunk on line boundaries.
        NSLog("%@", beginMarker)
        var buffer = ""
        for line in report.components(separatedBy: "\n") {
            if buffer.count + line.count > 700 {
                NSLog("SELFCHECK| %@", buffer)
                buffer = ""
            }
            buffer += (buffer.isEmpty ? "" : "\n") + line
        }
        if !buffer.isEmpty { NSLog("SELFCHECK| %@", buffer) }
        NSLog("%@", endMarker)

        if let summary = report.components(separatedBy: "\n").last(where: { $0.hasPrefix("total=") })
            ?? report.components(separatedBy: "\n").first(where: { $0.hasPrefix("total=") }) {
            NSLog("%@ %@", summaryMarker, summary)
        }
    }
    // MARK: - host-runtime: 视图层级 / 运行时内省 / 热修复 / 桥接抓包

    private static func checkRuntimeInspection(_ rec: Recorder, session: AISession) async {
        let runtime = RuntimeInspectTool(provider: DefaultRuntimeInspectProvider())
        rec.section("app_runtime_inspect")
        // The demo mounts the host window plus the SDK's overlay window(s), so a
        // hierarchy dump that only walked keyWindow would miss a whole UI layer.
        let windowCount = await MainActor.run {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }.count
        }
        await check(rec, "ui_hierarchy", runtime, ["op": .string("ui_hierarchy")],
                    session: session, preview: 700)
        let dump = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: ["op": .string("ui_hierarchy")],
                                      session: session).stringValue
        } ?? ""
        let dumped = dump.components(separatedBy: "Window: ").count - 1
        rec.record("ui_hierarchy covers every window", ok: dumped == windowCount && dumped > 0,
                   detail: "scene windows=\(windowCount), dumped=\(dumped)")

        // The report only keeps previews, so park the untruncated hierarchy +
        // addressable view tree next to it — that is what you actually read when
        // debugging layout or styling from outside the app.
        let deepTree = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: ["op": .string("view_tree"), "maxDepth": .number(30)],
                                      session: session).stringValue
        } ?? "(unavailable)"
        writeArtifact("selfcheck-ui-hierarchy.txt",
                      "# ui_hierarchy\n\n\(dump)\n\n# view_tree(maxDepth 30)\n\n\(deepTree)\n")
        await check(rec, "class_list(HostTabBar)", runtime,
                    ["op": .string("class_list"), "filter": .string("HostTabBar")], session: session)
        await check(rec, "method_list(HostTabBarController)", runtime,
                    ["op": .string("method_list"), "class": .string("HostTabBarController")], session: session)
        await check(rec, "method_list(unknown) rejected", runtime,
                    ["op": .string("method_list"), "class": .string("NoSuchClassHere")],
                    expect: .errorContains("class not found"), session: session)
        await check(rec, "view_info(bad path) rejected", runtime,
                    ["op": .string("view_info"), "path": .string("99/99")],
                    expect: .errorContains("no view at path"), session: session)
        await check(rec, "property_list(UILabel)", runtime,
                    ["op": .string("property_list"), "class": .string("UILabel")], session: session)
        await check(rec, "property_value(view.tag)", runtime,
                    ["op": .string("property_value"), "keyPath": .string("view.tag")], session: session)
        await check(rec, "view_tree(maxDepth 3)", runtime,
                    ["op": .string("view_tree"), "maxDepth": .number(3)], session: session, preview: 700)
        await check(rec, "view_info(path 0)", runtime,
                    ["op": .string("view_info"), "path": .string("0")], session: session)
        await check(rec, "view_set(frame)", runtime, [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("frame"), "value": .string("0,0,120,80")
        ], session: session)
        await check(rec, "view_set(backgroundColor)", runtime, [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("backgroundColor"), "value": .string("#3366FF")
        ], session: session)
        await check(rec, "view_set(alpha)", runtime, [
            "op": .string("view_set"), "path": .string("0"),
            "key": .string("alpha"), "value": .string("0.75")
        ], session: session)
        await check(rec, "view_invoke(setNeedsLayout)", runtime, [
            "op": .string("view_invoke"), "path": .string("0"), "selector": .string("setNeedsLayout")
        ], session: session)

        rec.section("app_hotfix (JS 改运行时)")
        let hotfix = HotfixTool(provider: DefaultHotfixProvider())
        await check(rec, "apply(instant JS)", hotfix, [
            "op": .string("apply"),
            "name": .string("selfcheck-js"),
            "javascript": .string(
                "appagent.log('js patch running');"
                + "var applied = appagent.uiSet('0', 'cornerRadius', '12');"
                + "'js → ' + applied + ' | treeLen=' + appagent.uiTree(2).length;"
            ),
            "applyMode": .string("instant"),
            "summary": .string("selfcheck: JS 改运行时 UI")
        ], session: session)
        await check(rec, "list", hotfix, ["op": .string("list")], session: session)
        await check(rec, "toggle(off)", hotfix, [
            "op": .string("toggle"), "name": .string("selfcheck-js"), "enabled": .bool(false)
        ], session: session)
        await check(rec, "remove", hotfix, [
            "op": .string("remove"), "name": .string("selfcheck-js")
        ], session: session)

        rec.section("app_hook_capture (JS↔native 桥接抓包)")
        let hook = HookCaptureTool()
        await check(rec, "status", hook, ["op": .string("status")], session: session)
        await check(rec, "start(talos_in)", hook,
                    ["op": .string("start"), "channel": .string("talos_in")], session: session)
        await check(rec, "read(talos_in)", hook,
                    ["op": .string("read"), "channel": .string("talos_in"), "limit": .number(5)],
                    session: session)
        await check(rec, "stop_all", hook, ["op": .string("stop_all")], session: session)
        await check(rec, "clear", hook, ["op": .string("clear")], session: session)

        rec.section("app_device_info")
        let device = AppDeviceInfoTool()
        for slice in ["device", "os", "app", "storage", "memory", "locale", "power"] {
            await check(rec, "section(\(slice))", device, ["section": .string(slice)],
                        session: session, preview: 220)
        }
        await check(rec, "section(bogus) rejected", device, ["section": .string("bogus")],
                    expect: .errorContains("Unknown section"), session: session)
    }
    // MARK: - host-storage: 沙箱文件 / UserDefaults

    private static func checkHostStorage(_ rec: Recorder, session: AISession) async {
        rec.section("app_sandbox_file")
        let sandbox = AppSandboxFileTool()
        await check(rec, "write", sandbox, [
            "op": .string("write"),
            "path": .string("Documents/selfcheck.txt"),
            "content": .string("hello-selfcheck")
        ], session: session)
        await check(rec, "read", sandbox,
                    ["op": .string("read"), "path": .string("Documents/selfcheck.txt")], session: session)
        await check(rec, "list(Documents)", sandbox,
                    ["op": .string("list"), "path": .string("Documents")], session: session)
        await check(rec, "delete", sandbox,
                    ["op": .string("delete"), "path": .string("Documents/selfcheck.txt")], session: session)
        await check(rec, "traversal rejected", sandbox,
                    ["op": .string("read"), "path": .string("../../../etc/passwd")],
                    expect: .errorContains("path"), session: session)

        rec.section("app_user_defaults")
        let defaults = AppUserDefaultsTool()
        await check(rec, "write", defaults, [
            "op": .string("write"), "key": .string("selfcheck_flag"), "value": .string("42")
        ], session: session)
        await check(rec, "read", defaults,
                    ["op": .string("read"), "key": .string("selfcheck_flag")], session: session)
        await check(rec, "list(prefix selfcheck)", defaults,
                    ["op": .string("list"), "prefix": .string("selfcheck")], session: session)
        await check(rec, "remove", defaults,
                    ["op": .string("remove"), "key": .string("selfcheck_flag")], session: session)
    }

    // MARK: - file group: 沙箱内文本文件读写检索

    private static func checkSandboxFileTools(_ rec: Recorder, session: AISession) async {
        rec.section("file_write / file_read / file_search")
        await check(rec, "file_write", FileWriteTool(), [
            "path": .string("selfcheck/notes.txt"),
            "content": .string("alpha\nbeta-marker\ngamma")
        ], session: session)
        await check(rec, "file_read", FileReadTool(),
                    ["path": .string("selfcheck/notes.txt")], session: session)
        await check(rec, "file_read(offset+limit)", FileReadTool(), [
            "path": .string("selfcheck/notes.txt"),
            "offset": .number(2), "limit": .number(1)
        ], session: session)
        await check(rec, "file_search(content)", FileSearchTool(), [
            "pattern": .string("beta-marker"), "target": .string("content")
        ], session: session)
        await check(rec, "file_search(files)", FileSearchTool(), [
            "pattern": .string("*.txt"), "target": .string("files")
        ], session: session)
        await check(rec, "file_read(missing) rejected", FileReadTool(),
                    ["path": .string("selfcheck/does-not-exist.txt")],
                    expect: .errorContains("not found"), session: session)
    }
    // MARK: - core: memory / todo / clarify / clipboard / haptic / tts / delegate

    private static func checkCoreTools(_ rec: Recorder, session: AISession) async {
        rec.section("memory")
        let memory = MemoryTool()
        let added = await withBudget { () async throws -> String in
            try await memory.execute(arguments: [
                "action": .string("add"),
                "content": .string("selfcheck 用户偏好：报告用中文"),
                "tags": .array([.string("selfcheck")])
            ], session: session).stringValue
        }
        var addedId: String?
        if let added,
           let json = (try? JSONSerialization.jsonObject(with: Data(added.utf8))) as? [String: Any],
           let id = json["id"] as? String {
            addedId = id
            rec.record("add", ok: true, detail: trimmed(added))
        } else {
            rec.record("add", ok: false, detail: trimmed(added ?? "TIMEOUT"))
        }
        await check(rec, "search", memory,
                    ["action": .string("search"), "query": .string("selfcheck")], session: session)
        await check(rec, "remove(bogus id) rejected", memory,
                    ["action": .string("remove"), "id": .string("no-such-entry")],
                    expect: .errorContains("No memory entry"), session: session)
        if let id = addedId {
            await check(rec, "remove(real id)", memory,
                        ["action": .string("remove"), "id": .string(id)], session: session)
        }

        rec.section("todo")
        let todo = TodoTool()
        await check(rec, "write", todo, [
            "todos": .array([
                .object(["id": .string("t1"), "content": .string("跑自检"), "status": .string("in_progress")]),
                .object(["id": .string("t2"), "content": .string("看报告"), "status": .string("pending")])
            ])
        ], session: session)
        await check(rec, "read", todo, [:], session: session)
        await check(rec, "merge update", todo, [
            "merge": .bool(true),
            "todos": .array([
                .object(["id": .string("t1"), "content": .string("跑自检"), "status": .string("completed")])
            ])
        ], session: session)

        rec.section("clarify")
        // The demo installs a delegate that auto-answers, so the round trip is exercised.
        await check(rec, "question with choices", ClarifyTool(), [
            "question": .string("自检要不要继续？"),
            "choices": .array([.string("继续"), .string("停止")])
        ], session: session)

        rec.section("clipboard / haptic / text_to_speech")
        let clipboard = ClipboardTool()
        await check(rec, "clipboard write", clipboard,
                    ["action": .string("write"), "content": .string("selfcheck-clip")], session: session)
        await check(rec, "clipboard read", clipboard,
                    ["action": .string("read")], session: session)
        await check(rec, "haptic(medium)", HapticTool(), ["style": .string("medium")], session: session)
        await check(rec, "haptic(selection)", HapticTool(), ["style": .string("selection")], session: session)
        await check(rec, "text_to_speech", TextToSpeechTool(), [
            "text": .string("self check"), "language": .string("en-US"), "rate": .number(0.5)
        ], session: session)
        await check(rec, "text_to_speech(empty) rejected", TextToSpeechTool(),
                    ["text": .string("")],
                    expect: .errorContains("Missing required parameter"), session: session)

        rec.section("delegate_task")
        // No model is configured in the ephemeral self-check agent, so this must
        // fail fast with a model-side error rather than hanging.
        await check(rec, "delegate without model degrades", DelegateTaskTool(), [
            "goal": .string("回一句 ok")
        ], expect: .completes, session: session)
    }
    // MARK: - skills: 发现 / 查看 / 创建 / 删除

    private static func checkSkills(_ rec: Recorder, session: AISession) async {
        rec.section("skills_list / skill_manage / skill_view")
        guard let manager = session.agentMask?.agent?.skillsManager else {
            rec.record("skillsManager available", ok: false, detail: "session has no agent")
            return
        }
        let list = SkillsListTool(manager: manager)
        let view = SkillViewTool(manager: manager)
        let manage = SkillManageTool(manager: manager)

        await check(rec, "skills_list(before)", list, [:], session: session)
        await check(rec, "skill_manage create", manage, [
            "action": .string("create"),
            "name": .string("selfcheck-skill"),
            "content": .string("""
                ---
                name: selfcheck-skill
                description: 自检临时技能
                ---

                # selfcheck
                这是一个由能力自检创建的临时技能。
                """)
        ], session: session)
        await check(rec, "skill_view", view, ["name": .string("selfcheck-skill")], session: session)
        await check(rec, "skills_list(after)", list, [:], session: session)
        await check(rec, "skill_manage delete", manage, [
            "action": .string("delete"), "name": .string("selfcheck-skill")
        ], session: session)
        await check(rec, "skill_view(missing) rejected", view,
                    ["name": .string("selfcheck-skill")],
                    expect: .errorContains("not found"), session: session)
    }

    // MARK: - session: 自我感知 / 搜索 / 管理

    private static func checkSessionTools(_ rec: Recorder, session: AISession) async {
        rec.section("session_search")
        let search = SessionSearchTool()
        await check(rec, "browse", search, ["limit": .number(5)], session: session)
        await check(rec, "query", search,
                    ["query": .string("selfcheck"), "limit": .number(5)], session: session)

        rec.section("session_manage")
        let sessions = SessionManageTool()
        await check(rec, "list", sessions, ["op": .string("list")], session: session, preview: 500)
        await check(rec, "models", sessions, ["op": .string("models")], session: session, preview: 300)
        await check(rec, "read(current)", sessions, [
            "op": .string("read"), "session_id": .string(session.id), "max_messages": .number(5)
        ], session: session)
        await check(rec, "set_model(bad ref) rejected", sessions,
                    ["op": .string("set_model"), "model": .string("nope/none")],
                    expect: .errorContains("nope"), session: session)

        // create → rename → clear → delete round trip on a throwaway session.
        var createdId: String?
        let created = await withBudget { () async throws -> String in
            let out = try await sessions.execute(
                arguments: ["op": .string("create"), "title": .string("selfcheck-new")],
                session: session
            )
            return out.stringValue
        }
        if let created,
           let json = (try? JSONSerialization.jsonObject(with: Data(created.utf8))) as? [String: Any],
           let sid = json["session_id"] as? String {
            createdId = sid
            rec.record("create", ok: true, detail: trimmed(created))
        } else {
            rec.record("create", ok: false, detail: trimmed(created ?? "TIMEOUT"))
        }

        if let sid = createdId {
            await check(rec, "rename", sessions, [
                "op": .string("rename"), "session_id": .string(sid), "title": .string("selfcheck-renamed")
            ], session: session)
            // Whether 'switch' works depends on the host UI having installed a
            // session activation handler — headless runs legitimately have none.
            await check(rec, "switch", sessions,
                        ["op": .string("switch"), "session_id": .string(sid)],
                        expect: .completes, session: session)
            await check(rec, "clear", sessions,
                        ["op": .string("clear"), "session_id": .string(sid)], session: session)
            await check(rec, "delete", sessions,
                        ["op": .string("delete"), "session_id": .string(sid)], session: session)
        }
        await check(rec, "delete(current) rejected", sessions,
                    ["op": .string("delete"), "session_id": .string(session.id)],
                    expect: .errorContains("current"), session: session)
    }
    // MARK: - 需宿主注入 Provider 的工具

    private static func checkHostProviderTools(_ rec: Recorder, session: AISession) async {
        rec.section("app_state / app_navigate / app_action (demo providers)")
        await check(rec, "app_state", AppStateTool(provider: DemoAppStateProvider()),
                    [:], session: session)

        let navigate = AppNavigateTool(provider: DemoNavigationProvider())
        await check(rec, "app_navigate list routes", navigate, [:], session: session)
        await check(rec, "app_navigate(profile)", navigate,
                    ["route": .string("profile")], session: session)
        await check(rec, "app_navigate(unknown) rejected", navigate,
                    ["route": .string("nowhere")],
                    expect: .errorContains("nowhere"), session: session)

        let action = AppActionTool(provider: DemoActionProvider())
        await check(rec, "app_action list actions", action, [:], session: session)
        await check(rec, "app_action(toggle_dark_mode)", action, [
            "action": .string("toggle_dark_mode"),
            "parameters": .object(["enabled": .bool(true)])
        ], session: session)
        await check(rec, "app_action(unknown) rejected", action,
                    ["action": .string("nope")],
                    expect: .errorContains("nope"), session: session)

        rec.section("web_search / vision_analyze")
        await check(rec, "web_search(with provider)",
                    WebSearchTool(provider: DemoWebSearchProvider()),
                    ["query": .string("appagent"), "limit": .number(2)], session: session)
        await check(rec, "web_search(no provider) rejected", WebSearchTool(),
                    ["query": .string("appagent")],
                    expect: .errorContains("provider"), session: session)
        await check(rec, "vision_analyze(no provider) rejected", VisionAnalyzeTool(),
                    ["image_path": .string("/tmp/none.png"), "question": .string("what")],
                    expect: .errorContains("provider"), session: session)
    }

    // MARK: - 调试记录器 + 过程区渲染

    private static func checkDebugAndRendering(_ rec: Recorder) async {
        rec.section("debug log")
        AppAgentDebugLog.shared.record(.info, message: "selfcheck marker")
        let events = AppAgentDebugLog.shared.snapshot().count
        rec.record("snapshot non-empty", ok: events > 0, detail: "events=\(events)")
        let export = AppAgentDebugLog.shared.exportText()
        rec.record("export contains marker", ok: export.contains("selfcheck marker"),
                   detail: trimmed(String(export.suffix(200))))

        rec.section("chat activity rendering")
        let lines = await MainActor.run { activityRenderingReport() }
        for line in lines.dropLast() { rec.note(line) }
        if let verdict = lines.last {
            rec.record("展开明细增高", ok: verdict.contains("✓"), detail: verdict)
        }
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
    /// strong holder, along with the stub delegate that answers `clarify`.
    private static var retainedEphemeralAgent: AIAgent?
    private static let autoAnswerDelegate = SelfCheckDelegate()

    static func ephemeralSession() async -> AISession {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "selfcheck",
            profile: AIAgentProfile(identity: "selfcheck"),
            sessionStorage: InMemorySessionStorage()
        )
        agent.delegate = autoAnswerDelegate
        retainedEphemeralAgent = agent
        return await agent.createSession(title: "自检")
    }
}

// MARK: - Stub delegate + demo host providers
//
// These exist so the self-check can exercise the tools that normally depend on
// the host app: `clarify` needs a delegate to answer, and app_state /
// app_navigate / app_action / web_search need injected providers.

/// Answers every clarification immediately so `clarify` can be exercised headlessly.
final class SelfCheckDelegate: AIAgentDelegate {
    func aiAgent(_ aiAgent: AIAgent, session: AISession,
                 needsClarification question: String, choices: [String]?) async -> String? {
        choices?.first ?? "自检自动回答"
    }
}

struct DemoAppStateProvider: AppStateProvider {
    func currentState() async -> [String: String] {
        await MainActor.run {
            let tab = (DemoAgentHolder.hostTabBarController?.selectedIndex).map(String.init) ?? "unknown"
            return [
                "current_tab_index": tab,
                "logged_in": "false",
                "interface_style": UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            ]
        }
    }
}

struct DemoNavigationProvider: AppNavigationProvider {
    private static let routes = ["home": 0, "browse": 1, "profile": 2]

    func availableRoutes() async -> [AppRoute] {
        [
            AppRoute(name: "home", description: "宿主 app 首页"),
            AppRoute(name: "browse", description: "宿主 app 浏览页"),
            AppRoute(name: "profile", description: "宿主 app 个人页")
        ]
    }

    func navigate(to route: String, parameters: [String: String]) async throws {
        guard let index = Self.routes[route] else {
            throw NSError(domain: "DemoNavigation", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown route '\(route)'"])
        }
        await MainActor.run { DemoAgentHolder.hostTabBarController?.selectedIndex = index }
    }
}

struct DemoActionProvider: AppActionProvider {
    func availableActions() async -> [AppAction] {
        [
            AppAction(name: "toggle_dark_mode", description: "切换宿主 app 的深浅色",
                      parameters: ["enabled": .boolean(description: "true 走深色")]),
            AppAction(name: "bump_tab", description: "切到下一个 tab")
        ]
    }

    func execute(action: String, parameters: [String: JSONValue]) async throws -> Tool.Output {
        switch action {
        case "toggle_dark_mode":
            let enabled = parameters["enabled"]?.boolValue ?? true
            await MainActor.run {
                DemoAgentHolder.hostTabBarController?.overrideUserInterfaceStyle = enabled ? .dark : .light
            }
            return .json(.object(["success": .bool(true), "dark": .bool(enabled)]))
        case "bump_tab":
            let index = await MainActor.run { () -> Int in
                guard let tabs = DemoAgentHolder.hostTabBarController else { return -1 }
                let next = (tabs.selectedIndex + 1) % max(1, tabs.viewControllers?.count ?? 1)
                tabs.selectedIndex = next
                return next
            }
            return .json(.object(["success": .bool(true), "tab": .number(Double(index))]))
        default:
            return .error("Unknown action '\(action)'")
        }
    }
}

struct DemoWebSearchProvider: WebSearchProvider {
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        (0..<min(limit, 3)).map { i in
            WebSearchResult(
                title: "\(query) 结果 \(i + 1)",
                url: "https://example.com/\(query)/\(i + 1)",
                snippet: "这是自检用的本地假结果，不发起真实网络请求。"
            )
        }
    }
}

/// Weak shared handle to the demo's agent + active session so the host UI (a
/// button on the Home tab) can run the self-check without threading references
/// through the whole view hierarchy.
enum DemoAgentHolder {
    static weak var agent: AIAgent?
    static var currentSessionId: String?
    @MainActor static weak var hostTabBarController: UITabBarController?

    static func currentSession() -> AISession? {
        guard let agent else { return nil }
        if let id = currentSessionId, let s = agent.session(id: id) { return s }
        return agent.allSessions.first
    }
}
