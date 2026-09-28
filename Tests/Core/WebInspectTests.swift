//
//  WebInspectTests.swift
//  AppAgentTests — web / H5 内省
//
//  Core 侧用例（原生 macOS 也能跑）：工具的参数校验、op 路由、失败判定。
//  真实 WKWebView 的 DOM 查询要在模拟器自检里验（单测拿不到 UIKit 运行时）。
//

import XCTest
@testable import AppAgent

/// 记录被调到哪个 op 的假 provider；返回值刻意带上 sentinel 前缀以验证失败翻译。
private final class StubWebInspectProvider: WebInspectProvider, @unchecked Sendable {
    var calls: [String] = []
    var nextResult = "ok"

    func targets() async -> String {
        calls.append("targets")
        return nextResult
    }

    func domSummary(webviewId: String?, path: String?, maxNodes: Int) async -> String {
        calls.append("dom_summary(\(webviewId ?? "-"),\(path ?? "-"),\(maxNodes))")
        return nextResult
    }

    func domQuery(webviewId: String?, selector: String?, path: String?) async -> String {
        calls.append("dom_query(\(selector ?? "-"),\(path ?? "-"))")
        return nextResult
    }

    func whyHidden(webviewId: String?, selector: String?, path: String?) async -> String {
        calls.append("why_hidden(\(selector ?? "-"),\(path ?? "-"))")
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

    // MARK: - 权限基线（内部阶段放开，见 liji_server docs/WEB_INSPECT_DESIGN.md §6）

    func testReadOpsAreSafeAndEvalIsModerate() {
        let tool = WebInspectTool(provider: StubWebInspectProvider())
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("dom_summary")]), .safe)
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("why_hidden")]), .safe)
        XCTAssertEqual(tool.safetyLevel(for: ["op": .string("eval")]), .moderate)
        // 缺 op 不降级为 safe，否则模型省掉参数就绕过闸门。
        XCTAssertEqual(tool.safetyLevel(for: [:]), .moderate)
    }

    // MARK: - 抓包通道扩展

    func testCaptureChannelsAppendedInOrder() {
        // bitIndex 与宿主侧枚举一一对应，只能在末尾追加；顺序变了就是错通道读数据。
        XCTAssertEqual(HookCaptureStore.channels,
                       ["talos_in", "talos_out", "shell_in", "shell_out", "web_console", "web_nav"])
        XCTAssertTrue(HookCaptureStore.isValidChannel("web_console"))
        XCTAssertTrue(HookCaptureStore.isValidChannel("web_nav"))
    }
}
