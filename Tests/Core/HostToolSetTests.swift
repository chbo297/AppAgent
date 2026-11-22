import XCTest
@testable import AppAgent

/// 宿主工具集（namespace 前缀、重名拒绝）与按需加载组（load_tools）。
final class HostToolSetTests: XCTestCase {

    private struct EchoTool: ToolProtocol {
        let name: String
        var deferredGroup: String? = nil
        let description = "Echo."
        let parameters = Tool.Schema(properties: [:], required: [])

        func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
            .text("echo \(name)")
        }
    }

    private func makeAgent(_ toolCentral: ToolCentral) async -> AIAgent {
        await AIAgentCentral().create(
            name: "host-tool-set-\(UUID().uuidString)",
            profile: AIAgentProfile(identity: "Test", autoPersist: false, registerBuiltInTools: false),
            toolCentral: toolCentral,
            providerCentral: ModelProviderCentral(),
            sessionStorage: InMemorySessionStorage()
        )
    }

    func testHostToolsArePrefixedAndKeepTheirLocalName() async throws {
        let central = ToolCentral()
        try await central.registerHost(HostToolSet(
            namespace: "bdmap", displayName: "百度地图", summary: "作用于百度地图的业务与页面",
            tools: [EchoTool(name: "route")]
        ))
        let tools = await central.resolveTools()
        let tool = try XCTUnwrap(tools["bdmap_route"])
        XCTAssertNil(tools["route"])
        XCTAssertEqual(tool.origin, .host(namespace: "bdmap"))
        XCTAssertEqual(tool.localName, "route")
        let output = try await tool.execute(arguments: [:], session: AISession(id: "s"))
        guard case .text(let text) = output else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text, "echo route")
        let sources = await central.toolSourcesPrompt()
        let prompt = try XCTUnwrap(sources)
        XCTAssertTrue(prompt.contains("`bdmap_*` are provided by 百度地图"))
    }

    func testRegistrationRejectsReservedNamespacesAndCollisionsWithoutPartialChanges() async throws {
        let central = ToolCentral()
        await central.register(EchoTool(name: "file"))
        let reserved = HostToolSet(namespace: "file", displayName: "X", summary: "x", tools: [EchoTool(name: "a")])
        await XCTAssertThrowsErrorAsync(try await central.registerHost(reserved))
        let app = HostToolSet(namespace: "app", displayName: "X", summary: "x", tools: [EchoTool(name: "a")])
        await XCTAssertThrowsErrorAsync(try await central.registerHost(app))
        let invalid = HostToolSet(namespace: "Bd-Map", displayName: "X", summary: "x", tools: [EchoTool(name: "a")])
        await XCTAssertThrowsErrorAsync(try await central.registerHost(invalid))
        let duplicate = HostToolSet(
            namespace: "bdmap", displayName: "X", summary: "x",
            tools: [EchoTool(name: "a"), EchoTool(name: "b"), EchoTool(name: "a")]
        )
        await XCTAssertThrowsErrorAsync(try await central.registerHost(duplicate))
        let names = await Set(central.resolveTools().keys)
        XCTAssertEqual(names, ["file"], "失败的注册不能留下部分工具")

        try await central.registerHost(HostToolSet(
            namespace: "bdmap", displayName: "X", summary: "x", tools: [EchoTool(name: "a")]
        ))
        try await central.registerHost(HostToolSet(
            namespace: "bdmap", displayName: "X", summary: "x", tools: [EchoTool(name: "b")]
        ))
        let replaced = await Set(central.resolveTools().keys)
        XCTAssertEqual(replaced, ["file", "bdmap_b"], "同一 namespace 再注册整组替换")
    }

    func testDeferredGroupIsHiddenUntilLoaded() async throws {
        let central = ToolCentral()
        await central.registerDeferredGroup(ToolGroups.debug, summary: "debugging")
        await central.register(LoadToolsTool())
        await central.register(EchoTool(name: "app_debug_probe", deferredGroup: ToolGroups.debug))
        try await central.registerHost(HostToolSet(
            namespace: "bdmap", displayName: "百度地图", summary: "map",
            tools: [EchoTool(name: "route"), EchoTool(name: "fe_capture", deferredGroup: ToolGroups.debug)]
        ))
        let agent = await makeAgent(central)
        let session = await agent.createSession(title: "deferred")

        let before = await session.executor.availableTools(session: session).map(\.name)
        XCTAssertEqual(Set(before), ["load_tools", "bdmap_route"])
        let sources = await central.toolSourcesPrompt()
        let prompt = try XCTUnwrap(sources)
        XCTAssertTrue(prompt.contains("- debug: debugging"))

        let unknown = try await LoadToolsTool().execute(arguments: ["group": .string("nope")], session: session)
        guard case .error = unknown else {
            return XCTFail("unknown group must fail")
        }
        _ = try await LoadToolsTool().execute(arguments: ["group": .string("debug")], session: session)
        let after = await session.executor.availableTools(session: session).map(\.name)
        XCTAssertEqual(Set(after), ["load_tools", "bdmap_route", "app_debug_probe", "bdmap_fe_capture"])
    }

    func testRuntimeToolsAreSplitIntoEverydayUIAndDebugObjects() {
        let provider = StubRuntimeProvider()
        let ui = RuntimeInspectTool.ui(provider: provider)
        let objects = RuntimeInspectTool(provider: provider)
        XCTAssertEqual(ui.name, "app_ui")
        XCTAssertNil(ui.deferredGroup)
        XCTAssertEqual(objects.name, "app_runtime_inspect")
        XCTAssertEqual(objects.deferredGroup, ToolGroups.debug)
        // 看界面两边都有（呈现不同）；模拟操作只在 app_ui，内存与反射只在 app_runtime_inspect。
        let shared: Set<String> = ["ui_hierarchy", "view_tree", "view_info"]
        let uiOps = Set(RuntimeInspectTool.uiOperations)
        let debugOps = Set(RuntimeInspectTool.objectOperations)
        XCTAssertEqual(uiOps.intersection(debugOps), shared)
        XCTAssertTrue(uiOps.subtracting(shared).isDisjoint(with: debugOps))
    }
}

private struct StubRuntimeProvider: RuntimeInspectProvider {
    func uiHierarchy(context: HostInspectionContext) async -> String {
        ""
    }

    func classList(matching filter: String?, context: HostInspectionContext) async -> [String] {
        []
    }

    func methodList(ofClass className: String, context: HostInspectionContext) async -> [String] {
        []
    }

    func propertyList(ofClass className: String, context: HostInspectionContext) async -> [String] {
        []
    }

    func propertyValue(keyPath: String, ofClass className: String?, context: HostInspectionContext) async -> String? {
        nil
    }

    func invoke(className: String, selector: String, argumentsJSON: String, context: HostInspectionContext) async -> String {
        ""
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
    }
}
