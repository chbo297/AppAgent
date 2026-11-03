//
//  WebInspectTests.swift
//  AppAgentTests — web / H5 内省
//
//  Core 侧用例（原生 macOS 也能跑）：工具的参数校验、op 路由、失败判定。
//  真实 HTML / 原生 overlay 由 UIKit runner 的 WebInspectViewTests 定向验证。
//

import XCTest
@testable import AppAgent

/// 记录被调到哪个 op 的假 provider；返回值刻意带上 sentinel 前缀以验证失败翻译。
private final class StubWebInspectProvider: WebInspectProvider, @unchecked Sendable {
    var calls: [String] = []
    var nextResult = "ok"
    var contexts: [HostInspectionContext] = []

    func targets(context: HostInspectionContext) async -> String {
        contexts.append(context)
        calls.append("targets")
        return nextResult
    }

    func domSummary(webviewId: String?, path: String?, maxNodes: Int, context: HostInspectionContext) async -> String {
        calls.append("dom_summary(\(webviewId ?? "-"),\(path ?? "-"),\(maxNodes))")
        return nextResult
    }

    func domQuery(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String {
        calls.append("dom_query(\(selector ?? "-"),\(path ?? "-"))")
        return nextResult
    }

    func whyHidden(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String {
        calls.append("why_hidden(\(selector ?? "-"),\(path ?? "-"))")
        return nextResult
    }

    func highlight(webviewId: String?, selector: String?, path: String?, context: HostInspectionContext) async -> String {
        contexts.append(context)
        calls.append("highlight(\(webviewId ?? "-"),\(selector ?? "-"),\(path ?? "-"))")
        return nextResult
    }

    func clearHighlight(webviewId: String?, context: HostInspectionContext) async -> String {
        contexts.append(context)
        calls.append("clear_highlight(\(webviewId ?? "-"))")
        return nextResult
    }

    func pageSource(webviewId: String?, kind: String, maxBytes: Int, context: HostInspectionContext) async -> String {
        calls.append("page_source(\(kind),\(maxBytes))")
        return nextResult
    }

    func consoleRead(webviewId: String?, limit: Int, sinceSeq: UInt64?, context: HostInspectionContext) async -> String {
        calls.append("console_read(\(limit),\(sinceSeq.map(String.init) ?? "-"))")
        return nextResult
    }
}

final class WebInspectTests: XCTestCase {

    private func makeSession() -> AISession {
        AISession(id: "web-inspect-test", title: "New Chat")
    }

    private func text(_ output: Tool.Output) -> String? {
        if case .text(let value) = output {
            return value
        }
        return nil
    }

    private func error(_ output: Tool.Output) -> String? {
        if case .error(let value) = output {
            return value
        }
        return nil
    }

    // MARK: - op 路由与参数校验

    func testDomSummaryRoutesWithClampedBudget() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        _ = try await tool.execute(arguments: ["op": .string("dom_summary"),
                                              "maxNodes": .number(5)],
                                   session: makeSession())
        XCTAssertEqual(provider.calls, ["dom_summary(-,-,10)"])
    }

    func testDomQueryRequiresSelectorOrPath() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let output = try await tool.execute(arguments: ["op": .string("dom_query")],
                                           session: makeSession())
        XCTAssertNotNil(error(output))
        XCTAssertTrue(provider.calls.isEmpty, "参数不全时不该打到 provider")
    }

    func testWhyHiddenAcceptsSelector() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        _ = try await tool.execute(arguments: ["op": .string("why_hidden"),
                                              "selector": .string("#submit")],
                                   session: makeSession())
        XCTAssertEqual(provider.calls, ["why_hidden(#submit,-)"])
    }

    func testProbeRequiresBothCoordinates() async throws {
        let tool = WebInspectTool(provider: StubWebInspectProvider())
        let output = try await tool.execute(arguments: ["op": .string("probe"), "x": .number(10)],
                                           session: makeSession())
        XCTAssertNotNil(error(output))
    }

    func testUnknownOpIsError() async throws {
        let tool = WebInspectTool(provider: StubWebInspectProvider())
        let output = try await tool.execute(arguments: ["op": .string("nope")], session: makeSession())
        XCTAssertEqual(error(output), "unknown op: nope")
    }

    // MARK: - 失败必须被翻译成工具错误

    func testSentinelFailureBecomesToolError() async throws {
        let provider = StubWebInspectProvider()
        provider.nextResult = "(no web view found on screen)"
        let tool = WebInspectTool(provider: provider)
        let output = try await tool.execute(arguments: ["op": .string("targets")], session: makeSession())
        XCTAssertNotNil(error(output), "「页面里什么都没有」和「没找到容器」不是一回事，必须报错")
    }

    func testDefaultProviderRejectsUnsupportedOps() async throws {
        // 只实现必需方法的 provider：可选 op 走协议默认实现，返回 denied 而不是假装成功。
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let output = try await tool.execute(arguments: ["op": .string("eval"),
                                                       "script": .string("1+1")],
                                           session: makeSession())
        XCTAssertNotNil(error(output))
    }

    func testSuccessPassesThrough() async throws {
        let provider = StubWebInspectProvider()
        provider.nextResult = "w1 onscreen rect=0,0,390,844"
        let tool = WebInspectTool(provider: provider)
        let output = try await tool.execute(arguments: ["op": .string("targets")], session: makeSession())
        XCTAssertEqual(text(output), "w1 onscreen rect=0,0,390,844")
    }

    // MARK: - 正式操作不能借读取权限运行任意 JS

    func testReadOpsAreSafeAndEvalRequiresSeparateApproval() {
        let tool = WebInspectTool(provider: StubWebInspectProvider())
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("dom_summary")]), .safe)
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("why_hidden")]), .safe)
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("highlight")]), .moderate)
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("clear_highlight")]), .moderate)
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("eval")]), .sensitive)
        // 缺 op 不降级为 safe，否则模型省掉参数就绕过闸门。
        XCTAssertEqual(tool.safetyLevel(for: [:]), .sensitive)
    }

    func testHighlightDispatchPreservesSelectionAndSceneAndReportsFailure() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let session = makeSession()
        session.inspectionSceneIdentifier = "scene-web"
        let missing = try await tool.execute(arguments: ["op": .string("highlight")], session: session)
        XCTAssertNotNil(error(missing))
        XCTAssertTrue(provider.calls.isEmpty)
        _ = try await tool.execute(arguments: [
            "op": .string("highlight"), "webviewId": .string("uuid"), "selector": .string("#button"),
            "path": .string("0/frame/1/shadow")
        ], session: session)
        provider.nextResult = "JS error: Unsupported closed or absent shadow root"
        let failure = try await tool.execute(arguments: [
            "op": .string("highlight"), "path": .string("0/shadow/0")
        ], session: session)
        XCTAssertNotNil(error(failure))
        _ = try await tool.execute(arguments: [
            "op": .string("clear_highlight"), "webviewId": .string("uuid")
        ], session: session)
        XCTAssertEqual(provider.calls, [
            "highlight(uuid,#button,0/frame/1/shadow)", "highlight(-,-,0/shadow/0)", "clear_highlight(uuid)"
        ])
        XCTAssertEqual(provider.contexts, Array(repeating: HostInspectionContext(sceneIdentifier: "scene-web"), count: 3))
    }

    func testReadOnlyRejectsHighlightAndEvalBeforeProvider() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        var profile = AIAgentProfile()
        profile.toolMutationPolicy = .readOnly
        let session = AISession(id: "web-readonly", agentMask: AIAgentMask(profile: profile, toolCentral: ToolCentral()))
        for op in ["highlight", "clear_highlight", "eval"] {
            do {
                _ = try await tool.execute(arguments: [
                    "op": .string(op), "selector": .string("body"), "script": .string("return 1;")
                ], session: session)
                XCTFail("readOnly must reject \(op)")
            } catch {
                XCTAssertEqual(error as? HostInspectionError, .readOnly)
            }
        }
        XCTAssertTrue(provider.calls.isEmpty)
        _ = try await tool.execute(arguments: ["op": .string("targets")], session: session)
        XCTAssertEqual(provider.calls, ["targets"])
    }

    func testExpandedScopeDoesNotReachProviderWithoutApproval() async {
        let provider = StubWebInspectProvider()
        let session = makeSession()
        session.allowsAppAgentInspection = false
        do {
            _ = try await WebInspectTool(provider: provider).execute(
                arguments: ["op": .string("targets"), "scope": .string("all")], session: session
            )
            XCTFail("scope approval is required")
        } catch {
            XCTAssertEqual(error as? HostInspectionError, .denied)
        }
        XCTAssertTrue(provider.calls.isEmpty)
    }

    func testMalformedOptionalTargetsNeverFallBackToDefaultPage() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let session = makeSession()
        for invalid in [JSONValue.null, .number(1), .bool(false), .string(""), .string(" \n")] {
            for op in ["highlight", "clear_highlight", "dom_query"] {
                let arguments: [String: JSONValue] = [
                    "op": .string(op), "webviewId": invalid, "selector": .string("#target")
                ]
                let preflight = await tool.preflightRejection(for: arguments, session: session)
                XCTAssertNotNil(preflight)
                let result = try await tool.execute(arguments: arguments, session: session)
                XCTAssertNotNil(error(result))
            }
        }
        for (key, value) in [
            ("selector", JSONValue.bool(true)), ("selector", .string(" ")),
            ("path", .number(0)), ("pageWorld", .string("false"))
        ] {
            var arguments: [String: JSONValue] = ["op": .string("highlight"), "selector": .string("#target")]
            arguments[key] = value
            let result = try await tool.execute(arguments: arguments, session: session)
            XCTAssertNotNil(error(result))
        }
        XCTAssertTrue(provider.calls.isEmpty)
        // Empty path is a valid explicit body selection; only omitted webviewId selects default.
        _ = try await tool.execute(arguments: ["op": .string("highlight"), "path": .string("")], session: session)
        XCTAssertEqual(provider.calls, ["highlight(-,-,)"])
    }

    func testNumericInputsRejectOverflowNonfiniteFractionsAndWrongTypes() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let session = makeSession()
        for key in ["maxNodes", "maxBytes", "limit", "sinceSeq"] {
            for invalid in [JSONValue.number(.nan), .number(.infinity), .number(-.infinity),
                            .number(1e100), .number(1.5), .string("10"), .null, .bool(true)] {
                let result = try await tool.execute(arguments: ["op": .string("targets"), key: invalid], session: session)
                XCTAssertNotNil(error(result), "Rejected \(key)=\(invalid)")
            }
        }
        for invalid in [Double(UInt64.max), -1] {
            let result = try await tool.execute(arguments: [
                "op": .string("console_read"), "sinceSeq": .number(invalid)
            ], session: session)
            XCTAssertNotNil(error(result))
        }
        let intBoundary = try await tool.execute(arguments: [
            "op": .string("dom_summary"), "maxNodes": .number(Double(Int.max))
        ], session: session)
        XCTAssertNotNil(error(intBoundary))
        for value in [Double.nan, .infinity, -1, 1e100] {
            let result = try await tool.execute(arguments: [
                "op": .string("probe"), "x": .number(value), "y": .number(0)
            ], session: session)
            XCTAssertNotNil(error(result))
        }
        XCTAssertTrue(provider.calls.isEmpty)
    }

    func testNumericBoundariesConvertExactlyAndBudgetsClamp() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let session = makeSession()
        for value in [Double(Int.min), Double(Int.max).nextDown] {
            _ = try await tool.execute(arguments: [
                "op": .string("dom_summary"), "maxNodes": .number(value)
            ], session: session)
            _ = try await tool.execute(arguments: [
                "op": .string("page_source"), "maxBytes": .number(value)
            ], session: session)
            _ = try await tool.execute(arguments: [
                "op": .string("console_read"), "limit": .number(value), "sinceSeq": .number(0)
            ], session: session)
        }
        let largestSequence = Double(UInt64.max).nextDown
        _ = try await tool.execute(arguments: [
            "op": .string("console_read"), "sinceSeq": .number(largestSequence)
        ], session: session)
        XCTAssertEqual(provider.calls, [
            "dom_summary(-,-,10)", "page_source(html,1024)", "console_read(1,0)",
            "dom_summary(-,-,1000)", "page_source(html,524288)", "console_read(1000,0)",
            "console_read(100,\(try XCTUnwrap(UInt64(exactly: largestSequence))))"
        ])
    }

    func testInvalidEnumsAndParameterTypesFailDuringPreflight() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let session = makeSession()
        for (key, invalid) in [
            ("scope", JSONValue.string("HOST")), ("kind", .string("pdf")),
            ("op", .bool(true)), ("script", .array([])), ("selector", .object([:])),
            ("path", .null), ("pageWorld", .number(0)), ("x", .bool(false)), ("y", .string("0"))
        ] {
            var arguments: [String: JSONValue] = ["op": .string("targets")]
            arguments[key] = invalid
            let rejection = await tool.preflightRejection(for: arguments, session: session)
            let output = try await tool.execute(arguments: arguments, session: session)
            XCTAssertNotNil(rejection, key)
            XCTAssertEqual(error(output), rejection, key)
        }
        XCTAssertTrue(provider.calls.isEmpty)
    }

    func testHostExecutionGateReceivesFullHighlightArgumentsAndCanReject() async throws {
        let provider = StubWebInspectProvider()
        let tool = WebInspectTool(provider: provider)
        let gate = WebInspectDenyGate()
        let tools = ToolCentral()
        await tools.register(tool)
        let agent = AIAgent(
            id: "web-gate-\(UUID().uuidString)",
            profile: AIAgentProfile(autoPersist: false, toolExecutionGate: gate, registerBuiltInTools: false),
            toolCentral: tools, memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
        let session = await agent.createSession(title: "Web gate")
        for op in ["highlight", "clear_highlight", "eval"] {
            do {
                _ = try await tool.execute(arguments: [
                    "op": .string(op), "webviewId": .string("explicit-id"), "selector": .string("#target"),
                    "path": .string("0/frame"), "script": .string("return 1;")
                ], session: session)
                XCTFail("Gate must reject \(op)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Web test gate denied"))
            }
        }
        let arguments = await gate.arguments
        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments.first?["path"], .string("0/frame"))
        XCTAssertEqual(arguments.first?["webviewId"], .string("explicit-id"))
        XCTAssertTrue(provider.calls.isEmpty)
        withExtendedLifetime(agent) {
        }
    }

    // MARK: - 抓包通道扩展

    func testCaptureChannelsUseHostDefinedNames() {
        XCTAssertTrue(HookCaptureStore.isValidChannel("bridge_in"))
        XCTAssertTrue(HookCaptureStore.isValidChannel("page.navigation"))
        XCTAssertFalse(HookCaptureStore.isValidChannel("../escape"))
        XCTAssertFalse(HookCaptureStore.isValidChannel(""))
    }
}

private actor WebInspectDenyGate: ToolExecutionGate {
    var arguments: [[String: JSONValue]] = []

    func rejection(for tool: any ToolProtocol, arguments: [String: JSONValue], session: AISession) async -> String? {
        self.arguments.append(arguments)
        return "Web test gate denied"
    }
}
