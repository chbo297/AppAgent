//
//  CapabilitySelfCheck.swift
//  AppAgentDemo
//
//  In-simulator smoke test for every tool the agent ships with. Runs each tool
//  DIRECTLY (no LLM round-trip) against a live session, tallies pass/fail per
//  check, and returns a human-readable report. Launch with `-run-selfcheck`
//  and the report is written to Documents/AppAgent/diagnostics/selfcheck-report.txt
//  plus emitted to the log in chunks (os_log truncates a single long message), so a script
//  driving the simulator can assert on it.
//
//  Every check runs behind a timeout so one hanging tool can never wedge the
//  whole run — a stuck check is reported as a failure and the run continues.
//

import UIKit
import WebKit

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
    static let reportFileName = "AppAgent/diagnostics/selfcheck-report.txt"

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
        let target = docs.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: target, atomically: true, encoding: .utf8)
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

        // 真机上 overlay 一定会把当前 scene 绑到 session 上（AppAgentOverlay.bind）。自检以前
        // 不绑，于是 includes() 在 `context.sceneIdentifier == nil` 处就短路返回，**整条场景过滤
        // 路径都是盲区** —— tab 漏报（3 个报成 1 个）正是藏在这里，从 9/24 活到 9/28 没被发现。
        // 绑上之后，下面所有检查才跑在与真机一致的配置下。
        session.inspectionSceneIdentifier = await MainActor.run {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .session.persistentIdentifier
        }

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

    /// Write the report in protected diagnostics so it survives the run, and
    /// emit it to the log in os_log-sized chunks plus a one-line summary.
    private static func persist(_ report: String) {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent(reportFileName)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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
        // Default and full detail must both stay host-only even while overlay is mounted.
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
        let shrunk = summaryBytes > 0 && fullBytes > summaryBytes
        rec.record("宿主摘要小于宿主全量", ok: shrunk,
                   detail: "summary=\(summaryBytes)B full=\(fullBytes)B"
                        + (fullBytes > 0 ? String(format: " (%.0f%%)", Double(summaryBytes) / Double(fullBytes) * 100) : ""))
        let all = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: [
                "op": .string("ui_hierarchy"), "scope": .string("all")
            ], session: session).stringValue
        } ?? ""
        let sdk = await withBudget { () async throws -> String in
            try await runtime.execute(arguments: [
                "op": .string("ui_hierarchy"), "scope": .string("appagent")
            ], session: session).stringValue
        } ?? ""
        rec.record("默认摘要与 full 排除 SDK 窗口",
                   ok: !summary.contains("AppAgentWindow") && !full.contains("AppAgentWindow")
                    && !summary.contains("AppAgentRegionDebug") && !full.contains("AppAgentRegionDebug")
                    && summary.contains("HostTabBar"),
                   detail: "host summary=\(summaryBytes)B full=\(fullBytes)B")
        rec.record("显式授权 all 可检查 SDK", ok: all.contains("AppAgentWindow"),
                   detail: "all=\(all.utf8.count)B")
        rec.record("appagent 范围不含宿主页面",
                   ok: sdk.contains("AppAgentWindow") && !sdk.contains("HostTabBarController"),
                   detail: "sdk=\(sdk.utf8.count)B")
        // 回放真机踩过的坑：绑定 scene 之后，view 还没加载的子 VC 曾被判成「不在本场景」，
        // 整排 tab 只报出当前那一个（3 个报成 1 个）。模型据此认定这排按钮是假皮肤，
        // 转去反射 _UITabButton，一次「切到 profile」烧掉 231 秒。
        let tabTruth: (count: Int, titles: [String], selected: Int)? = await MainActor.run {
            func firstTab(_ controller: UIViewController?) -> UITabBarController? {
                guard let controller else { return nil }
                if let tab = controller as? UITabBarController { return tab }
                for child in controller.children {
                    if let found = firstTab(child) { return found }
                }
                return firstTab(controller.presentedViewController)
            }
            let roots = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .compactMap(\.rootViewController)
            guard let tab = roots.lazy.compactMap({ firstTab($0) }).first else { return nil }
            let children = tab.viewControllers ?? []
            return (children.count,
                    children.map { $0.tabBarItem?.title ?? $0.title ?? "" },
                    tab.selectedIndex)
        }
        if let tabTruth, tabTruth.count > 0 {
            let reportedCount = summary.range(of: #"\d+ 个 tab"#, options: .regularExpression)
                .flatMap { Int(summary[$0].prefix(while: \.isNumber)) }
            let missing = tabTruth.titles.filter { !$0.isEmpty && !summary.contains("\"\($0)\"") }
            rec.record("摘要列出全部 tab（含 view 未加载的）",
                       ok: reportedCount == tabTruth.count && missing.isEmpty,
                       detail: "真实 \(tabTruth.count) 个 [\(tabTruth.titles.joined(separator: "/"))]，"
                           + "摘要报 \(reportedCount.map(String.init) ?? "nil")"
                           + (missing.isEmpty ? "" : "，缺标题 [\(missing.joined(separator: "/"))]"))
        } else {
            rec.record("摘要列出全部 tab（含 view 未加载的）", ok: false,
                       detail: "宿主没有 UITabBarController，这条无法验证")
        }
        // page_navigate 的端到端回归：一次调用换页，且结果里就能看出页面真的动了
        // （不用再补一轮 ui_hierarchy 去确认）。切走再切回，不留下副作用。
        if let tabTruth, tabTruth.count > 1 {
            let other = (tabTruth.selected + 1) % tabTruth.count
            let switched = await withBudget { () async throws -> String in
                try await runtime.execute(arguments: [
                    "op": .string("page_navigate"), "target": .string("tab:\(other)")
                ], session: session).stringValue
            } ?? "TIMEOUT"
            rec.record("page_navigate 按索引切 tab 并自报页面变化",
                       ok: switched.hasPrefix("OK.") && switched.contains("页面已变化"),
                       detail: trimmed(switched, 200))
            // 按标题切回：用户说的是「profile」，模型不该被迫自己算索引。
            let backTitle = tabTruth.titles[tabTruth.selected]
            let back = await withBudget { () async throws -> String in
                try await runtime.execute(arguments: [
                    "op": .string("page_navigate"),
                    "target": .string(backTitle.isEmpty ? "tab:\(tabTruth.selected)" : "tab:\(backTitle)")
                ], session: session).stringValue
            } ?? "TIMEOUT"
            rec.record("page_navigate 按标题切回原 tab",
                       ok: back.hasPrefix("OK.") && back.contains("页面已变化"),
                       detail: trimmed(back, 200))
            await check(rec, "page_navigate 拒绝不存在的 tab", runtime,
                        ["op": .string("page_navigate"), "target": .string("tab:不存在的页面")],
                        expect: .errorContains("no tab matches"), session: session)
        }
        // Use a handle obtained through approved SDK inspection, then try it in host scope.
        // Guessing a valid path must not bypass ownership at read/write/screenshot entry points.
        if let match = sdk.range(of: #"W[0-9]+:"# , options: .regularExpression) {
            let sdkRoot = String(sdk[match]) + "root"
            await check(rec, "宿主 view_info 拒绝 SDK 句柄", runtime,
                        ["op": .string("view_info"), "path": .string(sdkRoot)],
                        expect: .errorContains("no view at path"), session: session)
            await check(rec, "宿主 screenshot 拒绝 SDK 句柄", ScreenshotTool(),
                        ["path": .string(sdkRoot)], expect: .errorContains("outside"), session: session)
            await check(rec, "授权 SDK view_info 可用", runtime,
                        ["op": .string("view_info"), "path": .string(sdkRoot), "scope": .string("appagent")],
                        session: session)
        } else {
            rec.record("SDK 摘要有可检验句柄", ok: false, detail: "SDK scope missing W<n>: path")
        }
        // 摘要必须给出可直接二次调用的钻取句柄
        rec.record("摘要含可寻址 path", ok: summary.contains("[W") && summary.contains(":"),
                   detail: "使用稳定 window 句柄")
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
        writeArtifact("AppAgent/diagnostics/selfcheck-sdk-hierarchy.txt", "# authorized all\n\(all)\n\n# SDK only\n\(sdk)")
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
        let hostWindowPrefix = summary.range(of: #"W[0-9]+:"# , options: .regularExpression)
            .map { String(summary[$0]) } ?? ""
        let scratch = await withBudget { () async throws -> String in
            await MainActor.run { installScratchView(windowPrefix: hostWindowPrefix) ?? "" }
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
                + "var applied = appagent.uiSet('\(scratch ?? "missing-scratch")', 'cornerRadius', '12');"
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
                "javascript": .string("appagent.uiInvoke('\(scratch ?? "missing-scratch")', 'setTag:', '[7]')"),
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

        // Reclassify only our disposable view to exercise embedded SDK ownership.
        // Even if the negative check fails, no real SDK or host UI is mutated.
        if let scratch {
            _ = await withBudget { () async throws -> Bool in
                await MainActor.run {
                    guard let view = scratchView else { return false }
                    view.tag = 0
                    HostInspectionUIKit.markAppAgentOwned(view)
                    return true
                }
            }
            await check(rec, "宿主 view_set 拒绝嵌入 SDK 临时视图", runtime,
                        ["op": .string("view_set"), "path": .string(scratch),
                         "key": .string("tag"), "value": .string("271828")],
                        expect: .errorContains("no view at path"), session: session)
            await check(rec, "宿主 screenshot 拒绝嵌入 SDK 临时视图", ScreenshotTool(),
                        ["path": .string(scratch)], expect: .errorContains("outside"), session: session)
            await check(rec, "授权 SDK view_info 可访问嵌入临时视图", runtime,
                        ["op": .string("view_info"), "path": .string(scratch), "scope": .string("appagent")],
                        session: session)
            let jsDenied = await withBudget { () async throws -> String in
                try await hotfix.execute(arguments: [
                    "op": .string("apply"), "name": .string("selfcheck-sdk-guard"),
                    "javascript": .string("appagent.uiSet('\(scratch)', 'tag', '42')"),
                    "applyMode": .string("instant")
                ], session: session).stringValue
            } ?? "TIMEOUT"
            let unchanged = await withBudget { () async throws -> Bool in
                await MainActor.run { scratchView?.tag == 0 }
            }
            rec.record("宿主 JS 桥拒绝 SDK 且未修改视图",
                       ok: jsDenied.contains("no view at path") && unchanged == true,
                       detail: trimmed(jsDenied, 160))
            await check(rec, "remove(SDK 负向测试槽位)", hotfix,
                        ["op": .string("remove"), "name": .string("selfcheck-sdk-guard")], session: session)
        }


        // 宿主后台服务（liji_server）相关工具已迁到宿主侧，由宿主自行注册到 ToolCentral，
        // AppAgent 不再内置，故本自检不再覆盖；宿主侧自检请在宿主工程里做。

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

        // The top page is the selected tab's content, not HostTabBarController.
        // Host scope must not fall back to its class object; approved all may.
        await check(rec, "invoke(HostTabBarController.description) host 拒绝类对象回退", runtime,
                    ["op": .string("invoke"), "class": .string("HostTabBarController"),
                     "selector": .string("description")],
                    expect: .errorContains("selector description not found on HostTabBarController instance/class"),
                    session: session, preview: 200)
        // Go through execute → HostInspectionAccess → SelfCheckDecisionResponder,
        // not a provider call with a fabricated all-scope context.
        await check(rec, "invoke(HostTabBarController.description) 授权 all 放行类方法", runtime,
                    ["op": .string("invoke"), "class": .string("HostTabBarController"),
                     "selector": .string("description"), "scope": .string("all")],
                    expect: .ok, session: session, preview: 200)
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
        // Object-compatible ABI is necessary, not sufficient: description is an
        // arbitrary selector, so host must reject it and only approved all may run it.
        await check(rec, "view_invoke(description) host 拒绝任意 selector", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("description")],
                    expect: .errorContains("selector description requires all scope"), session: session)
        await check(rec, "view_invoke(description) 授权 all 放行对象返回值", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("description"), "scope": .string("all")],
                    expect: .ok, session: session, preview: 200)
        // Scope approval must never bypass the primitive ABI guard.
        for scope in ["host", "all"] {
            await check(rec, "view_invoke(setTag:, scope:\(scope)) 拒绝原始类型参数", runtime,
                        ["op": .string("view_invoke"), "path": .string(path), "scope": .string(scope),
                         "selector": .string("setTag:"), "argumentsJSON": .string("[7]")],
                        expect: .errorContains("not an object"), session: session)
            await check(rec, "view_invoke(isHidden, scope:\(scope)) 拒绝原始类型返回值", runtime,
                        ["op": .string("view_invoke"), "path": .string(path), "scope": .string(scope),
                         "selector": .string("isHidden")],
                        expect: .errorContains("not an object"), session: session)
        }
        await check(rec, "view_invoke(未知 selector) rejected", runtime,
                    ["op": .string("view_invoke"), "path": .string(path),
                     "selector": .string("selfcheckNoSuchSelector")],
                    expect: .errorContains("not found"), session: session)
        let tag = await withBudget { () async throws -> Int in
            await MainActor.run { scratchView?.tag ?? -1 }
        } ?? -1
        rec.record("被拒的 setTag: 没写脏 tag", ok: tag == 0, detail: "tag=\(tag)")

        // 写类操作的失败文案五花八门，必须条条都报成失败。
        // view_set reads the rollback value first; an unknown key fails that read
        // before any setter is attempted, and mutationOutput must still report an error.
        await check(rec, "view_set(未知 key) rejected", runtime,
                    ["op": .string("view_set"), "path": .string(path),
                     "key": .string("selfcheckNoSuchKey"), "value": .string("1")],
                    expect: .errorContains("Failed to read selfcheckNoSuchKey on "), session: session)
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

    // MARK: - app_web_inspect：真挂一个 WKWebView 进去读 DOM

    /// scratch webview 只存在 @MainActor 静态槽里：**不把非 Sendable 的 WKWebView 跨隔离域传递**。
    @MainActor private static var scratchWebView: WKWebView?

    @MainActor
    private static func installScratchWebView() -> Bool {
        var host: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            for window in windowScene.windows {
                if host == nil {
                    host = window
                }
            }
        }
        guard let host else {
            return false
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        host.addSubview(webView)
        // 刻意做成「两个典型故障」：按钮 display:none、内容比容器宽（scrollWidth > clientWidth）。
        let html = """
            <html><head><title>selfcheck</title><meta name="viewport" content="width=device-width"></head>
            <body style="margin:0">
            <div id="narrow" style="width:120px;overflow:hidden"><span style="display:inline-block;width:400px">wide content</span></div>
            <button id="btn">tap me</button>
            <button id="gone" style="display:none">hidden</button>
            </body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
        scratchWebView = webView
        return true
    }

    @MainActor
    private static func removeScratchWebView() {
        scratchWebView?.removeFromSuperview()
        scratchWebView = nil
    }

    private static func waitForScratchPageLoad(tool: WebInspectTool, session: AISession) async -> Bool {
        // 不监听 delegate（scratch 视图没有 owner），直接轮询 readyState，最多约 3s。
        for _ in 0..<30 {
            let state = await withBudget(seconds: 2) { () async throws -> String in
                try await tool.execute(arguments: ["op": .string("eval"),
                                                  "script": .string("return document.readyState;")],
                                       session: session).stringValue
            } ?? ""
            if state.contains("complete") {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // MARK: - app_hook_capture：真的写两条 JSONL 再读回来

    /// 往宿主 window 挂一个不可见、不响应交互的一次性视图。
    /// 自检结束后移除，运行时 UI 不留痕迹。
    @MainActor
    private static func installScratchView(windowPrefix: String) -> String? {
        guard let window = DemoAgentHolder.hostTabBarController?.viewIfLoaded?.window else { return nil }
        let scratch = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        scratch.isUserInteractionEnabled = false
        scratch.isHidden = true
        window.addSubview(scratch)
        scratchView = scratch
        return "\(windowPrefix)\(window.subviews.count - 1)"
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

        // create → rename → archive → restore round trip on a throwaway session.
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
            await check(rec, "clear rejected", sessions,
                        ["op": .string("clear"), "session_id": .string(sid)],
                        expect: .errorContains("irreversibly"), session: session)
            await check(rec, "archive", sessions,
                        ["op": .string("archive"), "session_id": .string(sid)], session: session)
            await check(rec, "archived", sessions,
                        ["op": .string("archived")], session: session)
            await check(rec, "restore", sessions,
                        ["op": .string("restore"), "session_id": .string(sid)], session: session)
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
                    expect: .errorContains("outside"), session: session)
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
    }

    private static func checkDebugAndRendering(_ rec: Recorder) async {
        rec.section("debug log")
        AppAgentDebugLog.shared.record(.info, message: "selfcheck marker")
        let events = AppAgentDebugLog.shared.snapshot().count
        rec.record("snapshot non-empty", ok: events > 0, detail: "events=\(events)")
        let export = AppAgentDebugLog.shared.exportText()
        rec.record("export contains marker", ok: export.contains("selfcheck marker"),
                   detail: trimmed(String(export.suffix(200))))
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
        case .appAgentInspection:
            // Direct execute still requests appagent/all approval through the
            // normal decision path. Explicitly approve each self-check call.
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
