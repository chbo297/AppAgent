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

    /// Race `work` against a budget. Returns nil on timeout.
    private static func withBudget<T: Sendable>(
        seconds: TimeInterval? = nil,
        _ work: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let budget = seconds ?? checkTimeout
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
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
        preview: Int = 400,
        timeout: TimeInterval? = nil
    ) async {
        let outcome = await withBudget(seconds: timeout) { () async throws -> (Bool, String) in
            do {
                let out = try await tool.execute(arguments: args, session: session)
                switch out {
                case .error(let message):
                    return (false, message)
                case .text(let text):
                    return (true, text)
                case .json, .image:
                    return (true, out.stringValue)
                }
            } catch {
                return (false, "throw: \(error.localizedDescription)")
            }
        }

        guard let (isSuccess, body) = outcome else {
            rec.record(label, ok: false, detail: "TIMEOUT after \(Int(timeout ?? checkTimeout))s")
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

        // 自检期间把「等用户拍板」的呈现权换成自动应答的假 responder。
        // 真机上这个位置是 AppAgent 面板的决策卡片，它会一直等真人点按钮——
        // 无人值守时整轮自检会挂死，所以必须先换掉（跑完在 checkWebFetch 末尾复位）。
        let autoResponder = SelfCheckDecisionResponder()
        let autoRegistry = DecisionResponderCentral()
        autoRegistry.register(autoResponder)
        session.decisionResponders = autoRegistry
        await MainActor.run { SelfCheckDecisionResponder.outcome = .deny }

        await checkRuntimeInspection(rec, session: session)
        await checkHostStorage(rec, session: session)
        await checkSandboxFileTools(rec, session: session)
        await checkCoreTools(rec, session: session)
        await checkSkills(rec, session: session)
        await checkSessionTools(rec, session: session)
        await checkHostProviderTools(rec, session: session)
        await checkWebFetch(rec, session: session)
        checkSafetyModel(rec)
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
        let windowCount = await withBudget { () async throws -> Int in
            await MainActor.run {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }.count
            }
        } ?? 0
        await check(rec, "ui_hierarchy(summary)", runtime, ["op": .string("ui_hierarchy")],
                    session: session, preview: 700)
        let summary = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: ["op": .string("ui_hierarchy")],
                                      session: session).stringValue
        } ?? ""
        let full = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: ["op": .string("ui_hierarchy"),
                                                  "detail": .string("full")],
                                      session: session).stringValue
        } ?? ""
        // 摘要必须真的省下来，否则「先看地图再钻取」这条路等于没做。
        let summaryBytes = summary.utf8.count
        let fullBytes = full.utf8.count
        let shrunk = summaryBytes > 0 && fullBytes > 0 && summaryBytes * 3 < fullBytes
        rec.record("摘要显著小于全量", ok: shrunk,
                   detail: "summary=\(summaryBytes)B full=\(fullBytes)B"
                        + (fullBytes > 0 ? String(format: " (%.0f%%)", Double(summaryBytes) / Double(fullBytes) * 100) : ""))
        // 摘要覆盖到每一个 window（overlay 那两层不能漏）
        let dumped = summary.components(separatedBy: "\n").filter { $0.hasPrefix("[W") }.count
        rec.record("摘要覆盖每个 window", ok: dumped == windowCount && dumped > 0,
                   detail: "scene windows=\(windowCount), summarized=\(dumped)")
        // 摘要必须给出可直接二次调用的钻取句柄
        rec.record("摘要含可寻址 path", ok: summary.contains("[W0:") || summary.contains("view=[W"),
                   detail: summary.contains("[W0:") ? "有 W0: 前缀路径" : "缺少可寻址 path")
        await check(rec, "ui_hierarchy(bogus detail) rejected", runtime,
                    ["op": .string("ui_hierarchy"), "detail": .string("nope")],
                    expect: .errorContains("Unknown detail"), session: session)

        // The report only keeps previews, so park the untruncated hierarchy +
        // addressable view tree next to it — that is what you actually read when
        // debugging layout or styling from outside the app.
        let deepTree = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: ["op": .string("view_tree"), "maxDepth": .number(30)],
                                      session: session).stringValue
        } ?? "(unavailable)"
        writeArtifact("selfcheck-ui-hierarchy.txt",
                      "# ui_hierarchy(detail:summary) — \(summaryBytes) bytes\n\n\(summary)\n\n"
                      + "# ui_hierarchy(detail:full) — \(fullBytes) bytes\n\n\(full)\n\n"
                      + "# view_tree(maxDepth 30)\n\n\(deepTree)\n")
        await check(rec, "class_list(HostTabBar)", runtime,
                    ["op": .string("class_list"), "filter": .string("HostTabBar")], session: session)
        await check(rec, "class_list(no filter) rejected", runtime,
                    ["op": .string("class_list")],
                    expect: .errorContains("'filter' is required"), session: session)
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
        await checkKVCOps(rec, session: session, runtime: runtime)
        await check(rec, "view_tree(maxDepth 3)", runtime,
                    ["op": .string("view_tree"), "maxDepth": .number(3)], session: session, preview: 700)

        // 变更类操作（view_set / view_invoke / JS uiSet）打在自检自己插入的
        // 一次性视图上，而不是真实 UIKit 内部视图 —— 否则自检跑完会把界面改坏，
        // 下次有人打开 app 会以为 UI 有 bug。跑完在本函数末尾移除。
        let scratch = await withBudget { () async throws -> String in
            await MainActor.run { installScratchView() ?? "" }
        }.flatMap { $0.isEmpty ? nil : $0 }
        rec.record("临时视图已挂载（变更操作不碰真实视图）", ok: scratch != nil,
                   detail: scratch.map { "path=\($0)" } ?? "no window available")

        if let scratch {
            let path = scratch
            await check(rec, "view_info(scratch)", runtime,
                        ["op": .string("view_info"), "path": .string(path)], session: session)
            // 跨 window 寻址（W<n>: 前缀）——摘要给出的 path 就是这种形状
            await check(rec, "view_tree(path: scratch)", runtime,
                        ["op": .string("view_tree"), "path": .string(path), "maxDepth": .number(3)],
                        session: session)
            await check(rec, "view_set(frame)", runtime, [
                "op": .string("view_set"), "path": .string(path),
                "key": .string("frame"), "value": .string("0,0,120,80")
            ], session: session)
            // 改动必须带回原值，否则模型改坏了没有撤销路径
            let setResult = await withBudget { () async throws -> String in
                try await runtime.execute(arguments: [
                    "op": .string("view_set"), "path": .string(path),
                    "key": .string("alpha"), "value": .string("0.5")
                ], session: session).stringValue
            } ?? ""
            rec.record("view_set 返回改前原值", ok: setResult.contains("previous:"),
                       detail: trimmed(setResult, 160))
            // 把原值写回去 = 回滚
            if let previous = setResult.components(separatedBy: "previous: ").last?
                .components(separatedBy: " ").first {
                await check(rec, "把原值写回即回滚", runtime, [
                    "op": .string("view_set"), "path": .string(path),
                    "key": .string("alpha"), "value": .string(previous)
                ], session: session)
                let restored = await withBudget { () async throws -> String in
                    await MainActor.run { scratchView.map { String(format: "%.2f", $0.alpha) } ?? "?" }
                } ?? "?"
                rec.record("alpha 已还原", ok: restored == "1.00" || restored == previous,
                           detail: "alpha=\(restored) (previous=\(previous))")
            }
            await check(rec, "view_set(backgroundColor)", runtime, [
                "op": .string("view_set"), "path": .string(path),
                "key": .string("backgroundColor"), "value": .string("#3366FF")
            ], session: session)
            await check(rec, "view_set(alpha)", runtime, [
                "op": .string("view_set"), "path": .string(path),
                "key": .string("alpha"), "value": .string("0.75")
            ], session: session)
            await check(rec, "view_invoke(setNeedsLayout)", runtime, [
                "op": .string("view_invoke"), "path": .string(path), "selector": .string("setNeedsLayout")
            ], session: session)
            // 变更真的落到了那个视图上（自己的视图才敢精确比对）
            let applied = await withBudget { () async throws -> String in
                await MainActor.run {
                    guard let v = scratchView else { return "(no scratch view)" }
                    return String(format: "frame=%.0fx%.0f alpha=%.2f bg=%@",
                                  v.frame.width, v.frame.height, v.alpha,
                                  v.backgroundColor == nil ? "nil" : "set")
                }
            } ?? "TIMEOUT"
            rec.record("变更已生效在临时视图上", ok: applied == "frame=120x80 alpha=0.75 bg=set",
                       detail: applied)
            await checkReflectionGuards(rec, session: session, runtime: runtime, path: path)
        }

        rec.section("app_hotfix (JS 改运行时)")
        let hotfix = HotfixTool(provider: DefaultHotfixProvider())
        await check(rec, "apply(instant JS)", hotfix, [
            "op": .string("apply"),
            "name": .string("selfcheck-js"),
            "javascript": .string(
                "appagent.log('js patch running');"
                + "var applied = appagent.uiSet('\(scratch ?? "root")', 'cornerRadius', '12');"
                + "'js → ' + applied + ' | treeLen=' + appagent.uiTree(2).length;"
            ),
            "applyMode": .string("instant"),
            "summary": .string("selfcheck: JS 改运行时 UI")
        ], session: session)
        await check(rec, "list", hotfix, ["op": .string("list")], session: session)
        // JS 桥和 view_invoke 共用反射路径，同一道类型闸门也要拦住 JS 侧。
        let jsGuard = await withBudget { () async throws -> String in
            try await hotfix.execute(arguments: [
                "op": .string("apply"), "name": .string("selfcheck-js-guard"),
                "javascript": .string("appagent.uiInvoke('\(scratch ?? "root")', 'setTag:', '[7]')"),
                "applyMode": .string("instant")
            ], session: session).stringValue
        } ?? "TIMEOUT"
        rec.record("JS uiInvoke 也拦原始类型参数", ok: jsGuard.contains("not an object"),
                   detail: trimmed(jsGuard, 220))
        await check(rec, "remove(js-guard 槽位)", hotfix,
                    ["op": .string("remove"), "name": .string("selfcheck-js-guard")], session: session)
        // 坏 JS 必须以错误收场，而不是包成 success:false 的「成功」调用。
        await check(rec, "apply(坏 JS) 报失败", hotfix, [
            "op": .string("apply"), "name": .string("selfcheck-bad-js"),
            "javascript": .string("this is not ( valid javascript"),
            "applyMode": .string("instant")
        ], expect: .errorContains("hotfix apply failed"), session: session)
        await check(rec, "remove(坏 JS 槽位)", hotfix,
                    ["op": .string("remove"), "name": .string("selfcheck-bad-js")], session: session)
        await check(rec, "toggle(on)", hotfix, [
            "op": .string("toggle"), "name": .string("selfcheck-js"), "enabled": .bool(true)
        ], session: session)
        await check(rec, "toggle(off)", hotfix, [
            "op": .string("toggle"), "name": .string("selfcheck-js"), "enabled": .bool(false)
        ], session: session)
        await check(rec, "toggle(未知补丁) rejected", hotfix, [
            "op": .string("toggle"), "name": .string("no-such-patch"), "enabled": .bool(false)
        ], expect: .errorContains("no patch named"), session: session)
        await check(rec, "remove", hotfix, [
            "op": .string("remove"), "name": .string("selfcheck-js")
        ], session: session)
        await check(rec, "remove(未知补丁) rejected", hotfix, [
            "op": .string("remove"), "name": .string("no-such-patch")
        ], expect: .errorContains("no patch named"), session: session)
        let patchesLeft = await withBudget { () async throws -> String in
            try await hotfix.execute(arguments: ["op": .string("list")], session: session).stringValue
        } ?? "TIMEOUT"
        rec.record("补丁槽位已清空（无残留）", ok: patchesLeft == "[]",
                   detail: trimmed(patchesLeft, 200))

        await checkHookCapture(rec, session: session)

        rec.section("liji_server（离线可判定的边界）")
        // 后台服务在自检环境里不可达，所以只验参数校验与兜底分支：baseURL 指向
        // 一个必定连不上的本机端口，真实请求会立刻以 transport 错误收场。
        let liji = LijiServerTool(client: LijiServerClient(baseURL: "http://127.0.0.1:9"))
        await check(rec, "submit(缺 prompt) rejected", liji, ["op": .string("submit")],
                    expect: .errorContains("'prompt' is required"), session: session)
        await check(rec, "status(缺 requirementId) rejected", liji, ["op": .string("status")],
                    expect: .errorContains("'requirementId' is required"), session: session)
        await check(rec, "share(缺 patchId) rejected", liji, ["op": .string("share")],
                    expect: .errorContains("'patchId' is required"), session: session)
        await check(rec, "toggle(缺 token) rejected", liji, ["op": .string("toggle")],
                    expect: .errorContains("'token' is required"), session: session)
        await check(rec, "apply(无 hotfix 引擎) rejected", liji,
                    ["op": .string("apply"), "patchId": .string("selfcheck")],
                    expect: .errorContains("hotfix engine not available"), session: session)
        await check(rec, "unknown op rejected", liji, ["op": .string("nope")],
                    expect: .errorContains("unknown op"), session: session)
        // 服务不可达时必须以错误收场而不是挂住整轮自检。
        await check(rec, "list(服务不可达不挂死)", liji, ["op": .string("list")],
                    expect: .completes, session: session)

        rec.section("app_device_info")
        let device = AppDeviceInfoTool()
        for slice in ["device", "os", "app", "storage", "memory", "locale", "power"] {
            await check(rec, "section(\(slice))", device, ["section": .string(slice)],
                        session: session, preview: 220)
        }
        await check(rec, "section(bogus) rejected", device, ["section": .string("bogus")],
                    expect: .errorContains("Unknown section"), session: session)

        // 把一次性视图摘掉，运行时 UI 回到自检开始前的样子。
        if scratch != nil {
            let removed = await withBudget { () async throws -> Bool in
                await MainActor.run {
                    scratchView?.removeFromSuperview()
                    let detached = scratchView?.superview == nil
                    scratchView = nil
                    return detached
                }
            }
            rec.record("临时视图已移除（UI 无残留）", ok: removed == true,
                       detail: removed == nil ? "TIMEOUT" : (removed! ? "removed" : "still attached"))
        }
    }

    /// 自检期间持有的一次性视图。所有变更类内省操作都打在它身上。
    @MainActor private static var scratchView: UIView?

    // MARK: - KVC 读写 + 类反射（property_value / property_set / invoke）

    /// 这一组的重点是**失败必须被报成失败**：provider 用 sentinel 字符串表达错误，
    /// 工具层判错一旦漏掉，模型会把 "Failed to read …" 当成读到的值继续推理。
    private static func checkKVCOps(_ rec: Recorder, session: AISession, runtime: RuntimeInspectTool) async {
        await check(rec, "property_value(未定义 keyPath) rejected", runtime,
                    ["op": .string("property_value"), "keyPath": .string("selfcheckNoSuchKey")],
                    expect: .errorContains("Failed to read"), session: session)
        await check(rec, "property_value(未知类) rejected", runtime,
                    ["op": .string("property_value"), "keyPath": .string("view.tag"),
                     "class": .string("NoSuchClassHere")],
                    expect: .errorContains("no target object for KVC"), session: session)

        // KVC 写一遍来回：读原值 → 写 4242 → 读回 → 写回原值 → 确认复位。
        let readTag = { () async -> String in
            await withBudget { () async throws -> String in
                try await runtime.execute(arguments: ["op": .string("property_value"),
                                                      "keyPath": .string("view.tag")],
                                          session: session).stringValue
            } ?? "TIMEOUT"
        }
        let originalTag = await readTag()
        await check(rec, "property_set(view.tag=4242)", runtime,
                    ["op": .string("property_set"), "keyPath": .string("view.tag"),
                     "value": .string("4242")], session: session)
        let afterWrite = await readTag()
        rec.record("property_set 写入可读回", ok: afterWrite == "4242",
                   detail: "before=\(originalTag) after=\(afterWrite)")
        if originalTag != "TIMEOUT" {
            await check(rec, "property_set 写回原值", runtime,
                        ["op": .string("property_set"), "keyPath": .string("view.tag"),
                         "value": .string(originalTag)], session: session)
            let restored = await readTag()
            rec.record("view.tag 已复位（KVC 无残留）", ok: restored == originalTag,
                       detail: "tag=\(restored) (original=\(originalTag))")
        }
        await check(rec, "property_set(未定义 keyPath) rejected", runtime,
                    ["op": .string("property_set"), "keyPath": .string("selfcheckNoSuchKey"),
                     "value": .string("1")],
                    expect: .errorContains("Failed to set"), session: session)

        await check(rec, "invoke(HostTabBarController.description)", runtime,
                    ["op": .string("invoke"), "class": .string("HostTabBarController"),
                     "selector": .string("description")], session: session, preview: 200)
        await check(rec, "invoke(未知类) rejected", runtime,
                    ["op": .string("invoke"), "class": .string("NoSuchClassHere"),
                     "selector": .string("description")],
                    expect: .errorContains("class not found"), session: session)
        await check(rec, "invoke(未知 selector) rejected", runtime,
                    ["op": .string("invoke"), "class": .string("HostTabBarController"),
                     "selector": .string("selfcheckNoSuchSelector")],
                    expect: .errorContains("not found"), session: session)
        await check(rec, "invoke(缺 selector) rejected", runtime,
                    ["op": .string("invoke"), "class": .string("HostTabBarController")],
                    expect: .errorContains("required"), session: session)
    }

    // MARK: - 反射闸门：原始类型的参数/返回值必须在调用前被拒

    /// `perform(_:with:)` 只按对象指针传参收值。`setTag:` 收 NSInteger、`isHidden` 返回 BOOL，
    /// 硬调过去会把 NSNumber 的指针当整数写进去、或把 1 当对象解引用崩掉。所以这里既验
    /// 「被拒」，也验「拒完 tag 没被写脏」。
    private static func checkReflectionGuards(
        _ rec: Recorder, session: AISession, runtime: RuntimeInspectTool, path: String
    ) async {
        await check(rec, "view_invoke(description) 放行对象返回值", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("description")], session: session, preview: 200)
        await check(rec, "view_invoke(setTag:) 拒绝原始类型参数", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("setTag:"), "argumentsJSON": .string("[7]")],
                    expect: .errorContains("not an object"), session: session)
        await check(rec, "view_invoke(isHidden) 拒绝原始类型返回值", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("isHidden")],
                    expect: .errorContains("not an object"), session: session)
        await check(rec, "view_invoke(未知 selector) rejected", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("selfcheckNoSuchSelector")],
                    expect: .errorContains("not found"), session: session)
        let tag = await withBudget { () async throws -> Int in
            await MainActor.run { scratchView?.tag ?? -1 }
        } ?? -1
        rec.record("被拒的 setTag: 没写脏 tag", ok: tag == 0, detail: "tag=\(tag)")

        // 写类操作的失败文案五花八门，必须条条都报成失败。
        await check(rec, "view_set(未知 key) rejected", runtime,
                    ["op": .string("view_set"), "path": .string(path),
                     "key": .string("selfcheckNoSuchKey"), "value": .string("1")],
                    expect: .errorContains("Failed to set"), session: session)
        await check(rec, "view_set(坏 rect) rejected", runtime,
                    ["op": .string("view_set"), "path": .string(path),
                     "key": .string("frame"), "value": .string("garbage")],
                    expect: .errorContains("Invalid rect"), session: session)
        await check(rec, "view_set(坏 alpha) rejected", runtime,
                    ["op": .string("view_set"), "path": .string(path),
                     "key": .string("alpha"), "value": .string("abc")],
                    expect: .errorContains("Invalid alpha"), session: session)
        await check(rec, "view_set(纯 UIView 没有 text) rejected", runtime,
                    ["op": .string("view_set"), "path": .string(path),
                     "key": .string("text"), "value": .string("x")],
                    expect: .errorContains("no text/title"), session: session)
        // KVC 兜底分支也要能被判成成功（成功文案统一 "OK." 起头）。
        await check(rec, "view_set(KVC 兜底 accessibilityLabel)", runtime,
                    ["op": .string("view_set"), "path": .string(path),
                     "key": .string("accessibilityLabel"), "value": .string("selfcheck")],
                    session: session)
        await check(rec, "view_tree(坏 path) rejected", runtime,
                    ["op": .string("view_tree"), "path": .string("99/99")],
                    expect: .errorContains("no view at path"), session: session)
        await check(rec, "view_info(不存在的 window) rejected", runtime,
                    ["op": .string("view_info"), "path": .string("W9:0")],
                    expect: .errorContains("no view at path"), session: session)
    }

    // MARK: - app_hook_capture：真的写两条 JSONL 再读回来

    /// 抓包记录的写入方在仓库外（宿主 LijiMsgTap），所以以前 `read` 永远是 0 条、
    /// `clear` 永远删 0 个文件 —— 等于只验了「没崩」。这里自己按磁盘契约造两条记录，
    /// 把 seq 排序 / limit 取尾 / sinceSeq 过滤 / 按 channel 删 全部走一遍真实文件。
    private static func checkHookCapture(_ rec: Recorder, session: AISession) async {
        rec.section("app_hook_capture (JS↔native 桥接抓包)")
        let hook = HookCaptureTool()
        let defaults = UserDefaults.standard
        let originalConfig = defaults.string(forKey: HookCaptureStore.configKey)
        let fm = FileManager.default
        let dir = ((NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
                    ?? NSTemporaryDirectory()) as NSString).appendingPathComponent("LijiMsgCapture")
        let dirExisted = fm.fileExists(atPath: dir)

        let status = { () async -> [String: Any] in
            let raw = await withBudget { () async throws -> String in
                try await hook.execute(arguments: ["op": .string("status")], session: session).stringValue
            } ?? "{}"
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        }
        let enabled = { (json: [String: Any], channel: String) -> Bool in
            let channels = json["channels"] as? [String: Any]
            return ((channels?[channel] as? [String: Any])?["enabled"] as? Bool) ?? false
        }

        await check(rec, "status", hook, ["op": .string("status")], session: session)
        let reportedDir = (await status())["dir"] as? String ?? ""
        rec.record("status 给出抓包目录", ok: reportedDir == dir,
                   detail: "reported=\(reportedDir) expected=\(dir)")
        await check(rec, "start(talos_in)", hook,
                    ["op": .string("start"), "channel": .string("talos_in")], session: session)
        rec.record("start 后 talos_in 已开启", ok: enabled(await status(), "talos_in"), detail: "enabled=true")
        await check(rec, "start(未知 channel) rejected", hook,
                    ["op": .string("start"), "channel": .string("bogus_channel")],
                    expect: .errorContains("'channel' is required"), session: session)

        // 按磁盘契约造两条记录：cap_<channel>_<suffix>.jsonl，每行一个 JSON 对象。
        let file = (dir as NSString).appendingPathComponent("cap_talos_in_selfcheck.jsonl")
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let wrote = (try? ("{\"seq\":2,\"api\":\"selfcheck.two\",\"dir\":\"in\"}\n"
                           + "{\"seq\":1,\"api\":\"selfcheck.one\",\"dir\":\"in\"}\n")
            .write(toFile: file, atomically: true, encoding: .utf8)) != nil
        rec.record("写入两条抓包记录（含乱序 seq）", ok: wrote, detail: wrote ? file : "write failed")

        let readRecords = { (args: [String: JSONValue]) async -> [[String: Any]] in
            let raw = await withBudget { () async throws -> String in
                try await hook.execute(arguments: args, session: session).stringValue
            } ?? "{}"
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            return json["records"] as? [[String: Any]] ?? []
        }
        let seqs = { (records: [[String: Any]]) -> [Int] in
            records.compactMap { ($0["seq"] as? NSNumber)?.intValue }
        }

        let all = await readRecords(["op": .string("read"), "channel": .string("talos_in"),
                                     "limit": .number(10)])
        rec.record("read 读回两条并按 seq 升序", ok: seqs(all) == [1, 2], detail: "seqs=\(seqs(all))")
        let sinceOne = await readRecords(["op": .string("read"), "channel": .string("talos_in"),
                                          "sinceSeq": .number(1)])
        rec.record("read(sinceSeq:1) 只给更新的", ok: seqs(sinceOne) == [2], detail: "seqs=\(seqs(sinceOne))")
        let tail = await readRecords(["op": .string("read"), "channel": .string("talos_in"),
                                      "limit": .number(1)])
        rec.record("read(limit:1) 取尾部一条", ok: seqs(tail) == [2], detail: "seqs=\(seqs(tail))")
        await check(rec, "read(缺 channel) rejected", hook, ["op": .string("read")],
                    expect: .errorContains("'channel' is required"), session: session)

        await check(rec, "stop(talos_in)", hook,
                    ["op": .string("stop"), "channel": .string("talos_in")], session: session)
        rec.record("stop 后 talos_in 已关闭", ok: !enabled(await status(), "talos_in"), detail: "enabled=false")
        await check(rec, "stop(缺 channel) rejected", hook, ["op": .string("stop")],
                    expect: .errorContains("'channel' is required"), session: session)
        await check(rec, "stop_all", hook, ["op": .string("stop_all")], session: session)
        await check(rec, "clear(未知 channel) rejected", hook,
                    ["op": .string("clear"), "channel": .string("bogus_channel")],
                    expect: .errorContains("unknown channel"), session: session)

        let cleared = await withBudget { () async throws -> String in
            try await hook.execute(arguments: ["op": .string("clear"), "channel": .string("talos_in")],
                                   session: session).stringValue
        } ?? "TIMEOUT"
        rec.record("clear(talos_in) 真的删掉了文件", ok: cleared.contains("cleared 1 capture file"),
                   detail: trimmed(cleared, 160))
        let afterClear = await readRecords(["op": .string("read"), "channel": .string("talos_in"),
                                            "limit": .number(10)])
        rec.record("clear 后读回 0 条（无残留）", ok: afterClear.isEmpty,
                   detail: "count=\(afterClear.count) fileExists=\(fm.fileExists(atPath: file))")

        // 抓包开关写在共享 NSUserDefaults 里，自检不该改动宿主的持久配置。
        if let originalConfig {
            defaults.set(originalConfig, forKey: HookCaptureStore.configKey)
        } else {
            defaults.removeObject(forKey: HookCaptureStore.configKey)
        }
        if !dirExisted { try? fm.removeItem(atPath: dir) }
        let restored = defaults.string(forKey: HookCaptureStore.configKey) == originalConfig
            && (dirExisted || !fm.fileExists(atPath: dir))
        rec.record("抓包开关与目录已复位", ok: restored,
                   detail: "config=\(originalConfig == nil ? "removed" : "restored") dirExisted=\(dirExisted)")
    }

    /// 往 key window 挂一个不可见、不响应交互的一次性视图，返回它的可寻址路径。
    /// 自检结束后移除，运行时 UI 不留痕迹。
    @MainActor
    private static func installScratchView() -> String? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        // 必须和 DefaultRuntimeInspectProvider.keyWindow() 选同一个 window，
        // 否则 path 寻址会落到别的窗口上。用 W<n>: 前缀顺带覆盖跨窗口寻址。
        guard let windowIndex = windows.firstIndex(where: { $0.isKeyWindow }) ?? (windows.isEmpty ? nil : 0)
        else { return nil }
        let window = windows[windowIndex]
        let scratch = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        scratch.isUserInteractionEnabled = false
        scratch.isHidden = true
        window.addSubview(scratch)
        scratchView = scratch
        return "W\(windowIndex):\(window.subviews.count - 1)"
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
        // 只清掉自己写进去的内容，不去「先读旧值再还原」——读一段别的来源写入的
        // 剪贴板会触发系统粘贴授权，无人点确认时会一直卡住（实测卡死过一次）。
        let cleared = await withBudget { () async throws -> Bool in
            await MainActor.run {
                UIPasteboard.general.items = []
                return UIPasteboard.general.hasStrings == false
            }
        }
        rec.record("剪贴板已清理", ok: cleared == true, detail: cleared == nil ? "TIMEOUT" : "cleared")
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
        // app_navigate 会真的切 tab，记下原位置，这一节结束后还原。
        let previousTab = await withBudget { () async throws -> Int? in
            await MainActor.run { DemoAgentHolder.hostTabBarController?.selectedIndex }
        } ?? nil
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
        // 深浅色是全局观感，测完复位成跟随系统。
        let styleReset = await withBudget { () async throws -> Bool in
            await MainActor.run {
                DemoAgentHolder.hostTabBarController?.overrideUserInterfaceStyle = .unspecified
                return DemoAgentHolder.hostTabBarController?.overrideUserInterfaceStyle == .unspecified
            }
        }
        rec.record("深浅色已复位", ok: styleReset == true,
                   detail: styleReset == nil ? "TIMEOUT" : (styleReset! ? "unspecified" : "host tab bar missing"))
        if let previousTab {
            let tabReset = await withBudget { () async throws -> Bool in
                await MainActor.run {
                    DemoAgentHolder.hostTabBarController?.selectedIndex = previousTab
                    return DemoAgentHolder.hostTabBarController?.selectedIndex == previousTab
                }
            }
            rec.record("tab 已复位", ok: tabReset == true,
                       detail: tabReset == nil ? "TIMEOUT" : "selectedIndex=\(previousTab)")
        }

        rec.section("web_search / screenshot")
        await check(rec, "web_search(with provider)",
                    WebSearchTool(provider: DemoWebSearchProvider()),
                    ["query": .string("appagent"), "limit": .number(2)], session: session)
        await check(rec, "web_search(no provider) rejected", WebSearchTool(),
                    ["query": .string("appagent")],
                    expect: .errorContains("provider"), session: session)
        // screenshot 取代了原来的 vision_analyze：agent 真正需要的是「看自己现在长什么样」，
        // 而不是「分析一张宿主注入的外部图片」。
        let shot = ScreenshotTool()
        // 默认内联给模型看：走 Tool.Output.image，两种协议的 mapper 各自转成多模态 block
        let inlineShot = await withBudget { () async throws -> Tool.Output in
            try await shot.execute(arguments: ["maxWidth": .number(512)], session: session)
        }
        if let inlineShot {
            let images = inlineShot.images
            rec.record("screenshot 默认内联为图片", ok: images.count == 1,
                       detail: images.first.map { "\($0.mediaType), \($0.data.count) bytes" } ?? "无图片")
            rec.record("图片带文字说明（纯文本通道也自解释）",
                       ok: inlineShot.stringValue.contains("Screenshot of"),
                       detail: trimmed(inlineShot.stringValue, 120))
            if let image = images.first {
                let attachment = AIAgentMessage.ImageAttachment(data: image.data, mediaType: image.mediaType)
                let message = AIAgentMessage(role: .user, content: [.toolResult(
                    AIAgentMessage.ToolCallResult(toolCallId: "shot", content: image.caption,
                                                  images: [attachment]))])
                // Anthropic：图片进 tool_result.content 数组
                let anthropic = (try? JSONEncoder().encode(AnthropicMapper.toAnthropicMessages([message])))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                rec.record("Anthropic wire 带 image block",
                           ok: anthropic.contains("\"type\":\"image\"") && anthropic.contains("media_type"),
                           detail: anthropic.isEmpty ? "编码失败" : "tool_result.content 数组内含 image")
                // OpenAI chat：role:"tool" 只吃字符串，图片跟一条 user 消息
                let chat = OpenAIChatCompletionsMapper.toMessages([message], system: [])
                let hasImageURL = chat.contains { msg in
                    guard let parts = msg["content"] as? [[String: Any]] else { return false }
                    return parts.contains { $0["type"] as? String == "image_url" }
                }
                rec.record("OpenAI chat wire 带 image_url", ok: hasImageURL,
                           detail: "\(chat.count) 条消息（tool + 追加的 user）")
                // OpenAI Responses：input_image
                let responses = OpenAIResponsesMapper.toInput([message])
                let hasInputImage = responses.contains { item in
                    guard let parts = item["content"] as? [[String: Any]] else { return false }
                    return parts.contains { $0["type"] as? String == "input_image" }
                }
                rec.record("OpenAI responses wire 带 input_image", ok: hasInputImage,
                           detail: "\(responses.count) 个 input item")
            }
        } else {
            rec.record("screenshot 默认内联为图片", ok: false, detail: "TIMEOUT")
        }
        await check(rec, "screenshot(save_as_file) 落盘", shot,
                    ["name": .string("selfcheck-window"), "maxWidth": .number(512),
                     "save_as_file": .bool(true)],
                    session: session)
        await check(rec, "screenshot(bad path) rejected", shot,
                    ["path": .string("99/99")],
                    expect: .errorContains("No view at path"), session: session)
        rec.record("screenshot 是纯读（safe）", ok: shot.safetyLevel(for: [:]) == .safe,
                   detail: shot.safetyLevel(for: [:]).rawValue)
    }

    // MARK: - 安全模型：op 级分级 + 只读边界

    /// 纯判定，不执行任何工具 —— 锁住「同一个工具里读和写不同级」这条约定。
    private static func checkSafetyModel(_ rec: Recorder) {
        rec.section("op 级安全分级")

        func expect(_ label: String, _ actual: Tool.SafetyLevel, _ wanted: Tool.SafetyLevel) {
            rec.record(label, ok: actual == wanted, detail: "\(actual.rawValue) (期望 \(wanted.rawValue))")
        }

        let runtime = RuntimeInspectTool(provider: DefaultRuntimeInspectProvider())
        expect("app_runtime_inspect ui_hierarchy = safe",
               runtime.safetyLevel(for: ["op": .string("ui_hierarchy")]), .safe)
        expect("app_runtime_inspect view_set = moderate",
               runtime.safetyLevel(for: ["op": .string("view_set")]), .moderate)
        expect("app_runtime_inspect invoke = sensitive",
               runtime.safetyLevel(for: ["op": .string("invoke")]), .sensitive)

        let sandbox = AppSandboxFileTool()
        expect("app_sandbox_file list = safe", sandbox.safetyLevel(for: ["op": .string("list")]), .safe)
        expect("app_sandbox_file delete = sensitive", sandbox.safetyLevel(for: ["op": .string("delete")]), .sensitive)

        let hotfix = HotfixTool(provider: DefaultHotfixProvider())
        expect("app_hotfix list = safe", hotfix.safetyLevel(for: ["op": .string("list")]), .safe)
        expect("app_hotfix apply = dangerous", hotfix.safetyLevel(for: ["op": .string("apply")]), .dangerous)

        // 缺 op 不能降级成 safe，否则模型省掉参数就绕过闸门
        let missingOpSafe = [
            runtime.safetyLevel(for: [:]), sandbox.safetyLevel(for: [:]),
            hotfix.safetyLevel(for: [:]), AppUserDefaultsTool().safetyLevel(for: [:])
        ].allSatisfy { $0 > .safe }
        rec.record("缺 op 时不降级为 safe", ok: missingOpSafe,
                   detail: missingOpSafe ? "全部 > safe" : "有工具在缺参数时降到了 safe")

        rec.section("只读边界（Codex sandbox_mode 的 iOS 对应物）")
        let readOnlyBlocks = [Tool.SafetyLevel.moderate, .sensitive, .dangerous]
            .allSatisfy { LLMExecutor.isBlockedByMutationPolicy(.readOnly, level: $0) }
        rec.record("readOnly 拦下所有变更", ok: readOnlyBlocks,
                   detail: readOnlyBlocks ? "moderate/sensitive/dangerous 均被拒" : "有级别漏过")
        rec.record("readOnly 不拦纯读",
                   ok: !LLMExecutor.isBlockedByMutationPolicy(.readOnly, level: .safe),
                   detail: "safe 放行")
        let allowedPasses = [Tool.SafetyLevel.safe, .moderate, .sensitive, .dangerous]
            .allSatisfy { !LLMExecutor.isBlockedByMutationPolicy(.allowed, level: $0) }
        rec.record("allowed 交给逐次授权", ok: allowedPasses, detail: "不在边界层拦截")
    }

    // MARK: - 调试记录器 + 过程区渲染

    // MARK: - web_fetch：读公网内容

    private static func checkWebFetch(_ rec: Recorder, session: AISession) async {
        rec.section("web_fetch（离线可判定的边界）")
        let web = WebFetchTool()
        // 这几条不发请求，纯 URL 判定，所以是硬断言
        await check(rec, "拒绝 file:// scheme", web,
                    ["url": .string("file:///etc/passwd")],
                    expect: .errorContains("http"), session: session)
        await check(rec, "非法 mode 被拒", web,
                    ["url": .string("https://example.com"), "mode": .string("nope")],
                    expect: .errorContains("Unknown mode"), session: session)
        rec.record("save_as 抬升为 sensitive",
                   ok: web.safetyLevel(for: ["url": .string("https://example.com"),
                                             "save_as": .string("x.txt")]) == .sensitive,
                   detail: "无 save_as = \(web.safetyLevel(for: [:]).rawValue)")
        rec.record("抓回内容带不可信栅栏",
                   ok: WebFetchTool.fence("x", source: "u").contains("UNTRUSTED WEB CONTENT"),
                   detail: "防提示注入声明就位")

        rec.section("web_fetch（私网 = 问用户，不是硬拒）")
        // resolve 阶段只做判定，不再直接拒绝
        for host in ["localhost:8080", "169.254.169.254", "10.0.0.5"] {
            let raw = "http://\(host)/x"
            guard case .privateNetwork(_, let parsed) = WebFetchTool.resolve(raw) else {
                rec.record("\(host) → 需授权", ok: false, detail: "resolve 没返回 .privateNetwork")
                continue
            }
            rec.record("\(host) → 需授权", ok: true, detail: "host=\(parsed)")
        }
        rec.record("公网地址无需授权",
                   ok: { if case .success = WebFetchTool.resolve("https://example.com") { return true }
                         return false }(),
                   detail: "resolve = .success")

        // 没有任何 responder（headless）→ 兜底拒绝，不是「无人应答就放行」
        let emptyRegistry = DecisionResponderCentral()
        session.decisionResponders = emptyRegistry
        await check(rec, "无 responder → 兜底拒绝", web,
                    ["url": .string("http://10.9.9.9/")],
                    expect: .errorContains("denied"), session: session)

        // 接回自动应答的 responder，别把空注册表留给后面的检查项
        let responder = SelfCheckDecisionResponder()
        let registry = DecisionResponderCentral()
        registry.register(responder)
        session.decisionResponders = registry

        await MainActor.run {
            SelfCheckDecisionResponder.outcome = .deny
            SelfCheckDecisionResponder.askedHosts = []
            SelfCheckDecisionResponder.sawPendingDecision = false
        }
        await check(rec, "用户拒绝 → 不出站", web,
                    ["url": .string("http://10.0.0.5/admin/api/users")],
                    expect: .errorContains("denied"), session: session)
        let (asked, sawPending) = await MainActor.run {
            (SelfCheckDecisionResponder.askedHosts, SelfCheckDecisionResponder.sawPendingDecision)
        }
        rec.record("询问期间会话处于 pendingDecision 态",
                   ok: sawPending && asked == ["10.0.0.5"], detail: "asked=\(asked)")
        rec.record("决定后阻塞态已清除",
                   ok: session.uiState.pendingDecision == nil, detail: "pendingDecision = nil")

        // 用户允许（本 session）：第一次问过之后同一 host 不再问
        await MainActor.run {
            SelfCheckDecisionResponder.outcome = .allowForSession
            SelfCheckDecisionResponder.askedHosts = []
        }
        // 127.0.0.1:9 是 discard 端口，必然连不上——这里只验「放行后真的去连了」
        let allowed = await withBudget(seconds: 25) { () async throws -> String in
            try await web.execute(arguments: ["url": .string("http://127.0.0.1:9/")],
                                  session: session).stringValue
        } ?? "(timeout)"
        rec.record("用户允许 → 放行到出站",
                   ok: !allowed.contains("denied"), detail: trimmed(allowed, 160))
        let approved: [String] = session.uiState.get("approvedPrivateHosts") ?? []
        rec.record("allowForSession 记住了 host",
                   ok: approved.contains("127.0.0.1"), detail: "approved=\(approved)")
        await MainActor.run { SelfCheckDecisionResponder.askedHosts = [] }
        let secondTry = await withBudget(seconds: 25) { () async throws -> String in
            try await web.execute(arguments: ["url": .string("http://127.0.0.1:9/")],
                                  session: session).stringValue
        } ?? "(timeout)"
        let askedAgain = await MainActor.run { !SelfCheckDecisionResponder.askedHosts.isEmpty }
        rec.record("已授权的 host 不再询问",
                   ok: !askedAgain && !secondTry.contains("denied"),
                   detail: askedAgain ? "又问了一次" : "直接放行")

        // 决策卡片本身：点哪个按钮 = 什么语义（纯函数，不依赖真实点击）
        let authRequest = DecisionRequest.privateNetworkAccess(host: "10.0.0.5",
                                                              url: "http://10.0.0.5/x")
        rec.record("授权卡片给三个选项",
                   ok: authRequest.options.map(\.id) == ["allow_once", "allow_session", "deny"],
                   detail: authRequest.options.map(\.label).joined(separator: " / "))
        rec.record("卡片选项映射到正确语义",
                   ok: AppAgentDecisionCardView.outcome(for: authRequest, optionIndex: 0) == .allowOnce
                       && AppAgentDecisionCardView.outcome(for: authRequest, optionIndex: 1) == .allowForSession
                       && AppAgentDecisionCardView.outcome(for: authRequest, optionIndex: 2) == .deny,
                   detail: "仅本次 / 本会话 / 拒绝")
        let clarify = DecisionRequest.clarification(question: "选哪个？", choices: ["A", "B"])
        rec.record("澄清卡片复用同一控件",
                   ok: AppAgentDecisionCardView.outcome(for: clarify, optionIndex: 1) == .answer("B"),
                   detail: "choices → answer")

        // 收尾：别把授权残留给后面的检查项（responder 保持自动应答，见 run()）
        session.uiState.remove("approvedPrivateHosts")
        await MainActor.run { SelfCheckDecisionResponder.outcome = .deny }

        rec.section("web_fetch（真实出站，网络不通时降级不算失败）")
        // 给足 25s：请求本身 20s 超时，不能被 8s 的默认预算掐掉造成假失败
        await check(rec, "GET example.com (text)", web,
                    ["url": .string("https://example.com"), "mode": .string("text"),
                     "max_bytes": .number(4096)],
                    expect: .completes, session: session, preview: 300, timeout: 25)
        await check(rec, "GET raw.githubusercontent (raw)", web,
                    ["url": .string("https://raw.githubusercontent.com/chbo297/BOUIKit/main/README.md"),
                     "mode": .string("raw"), "max_bytes": .number(2048)],
                    expect: .completes, session: session, preview: 300, timeout: 25)
        await check(rec, "HEAD 只看响应头", web,
                    ["url": .string("https://example.com"), "mode": .string("head")],
                    expect: .completes, session: session, preview: 200, timeout: 25)
        // 下载 → 落盘 → 用 file_read 读回来，验证「长内容不进上下文」这条路
        let downloaded = await withBudget(seconds: 25) { () async throws -> String in
            try await web.execute(arguments: [
                "url": .string("https://example.com"),
                "save_as": .string("downloads/example.html")
            ], session: session).stringValue
        } ?? "(timeout/no network)"
        rec.record("下载落盘（网络可用时）", ok: true, detail: trimmed(downloaded, 240))
        if downloaded.contains("saved_path") {
            await check(rec, "file_read 读回下载内容", FileReadTool(),
                        ["path": .string("downloads/example.html")], session: session, preview: 200)
        }
    }

    private static func checkDebugAndRendering(_ rec: Recorder) async {
        rec.section("debug log")
        AppAgentDebugLog.shared.record(.info, message: "selfcheck marker")
        let events = AppAgentDebugLog.shared.snapshot().count
        rec.record("snapshot non-empty", ok: events > 0, detail: "events=\(events)")
        let export = AppAgentDebugLog.shared.exportText()
        rec.record("export contains marker", ok: export.contains("selfcheck marker"),
                   detail: trimmed(String(export.suffix(200))))

        rec.section("chat activity rendering")
        let lines = await withBudget { () async throws -> [String] in
            await MainActor.run { activityRenderingReport() }
        } ?? ["渲染超时 ✗"]
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
    /// 自检不在这里做决定：呈现由 AppAgent 自己的面板负责（`DecisionResponder`），
    /// 宿主策略保持「无意见」，正好验证默认集成下宿主什么都不用写。
}

/// 冒充用户点按钮：自检里没人真的去点卡片，用它替代 AppAgent 面板作为 responder。
final class SelfCheckDecisionResponder: DecisionResponder, @unchecked Sendable {
    @MainActor static var outcome: DecisionOutcome? = .deny
    @MainActor static var askedHosts: [String] = []
    @MainActor static var sawPendingDecision = false

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        switch request {
        case .privateNetworkAccess(let host, _):
            let pending = session.uiState.pendingDecision != nil
            await MainActor.run {
                Self.askedHosts.append(host)
                if pending { Self.sawPendingDecision = true }
            }
            return await MainActor.run { Self.outcome }
        case .clarification(_, let choices):
            // 冒充用户点了第一个选项；开放式提问就给一句固定回答。
            return .answer(choices.first ?? "自检自动回答")
        case .toolAuthorization:
            // 自检直连 execute，不经过 LLMExecutor，这条一般走不到；放行以免误挂。
            return .allowOnce
        }
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
