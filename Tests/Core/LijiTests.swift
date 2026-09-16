//
//  LijiTests.swift
//  AppAgent — Liji 集成层测试
//
//  仅覆盖 AppAgent 侧保留的通用集成能力（config / provider factory / auth /
//  面板数据源 / liji_server + runtime + hotfix 工具装配 / DTO 解码）。
//  地图领域能力（app_map_*）已迁至宿主 mapframework，其测试随宿主工程。
//

import XCTest
@testable import AppAgent

final class LijiTests: XCTestCase {

    func testDefaultConfigIsOneAPI() {
        let c = LijiConfig.baiduMapDefault()
        XCTAssertEqual(c.baseURL, "https://oneapi-comate.baidu-int.com/v1")
        XCTAssertEqual(c.apiProtocol, .openaiCompletions)
        XCTAssertEqual(c.model, "gpt-5.6-sol")
        XCTAssertNotNil(c.customHeaders["comate_custom_header"])
        XCTAssertTrue(c.lijiServerEnabled)
        XCTAssertFalse(c.runtimeToolsEnabled)
        XCTAssertFalse(c.hotfixEnabled)
        XCTAssertEqual(c.lijiServerBaseURL, "https://liji.n.baidu.com")
    }

    func testProviderFactory() {
        var c = LijiConfig.baiduMapDefault()
        c.apiKey = "dummy"
        let (provider, policy) = LijiProviderFactory.makeProviderAndPolicy(from: c)
        XCTAssertEqual(provider.baseURL, c.baseURL)
        XCTAssertEqual(provider.apiProtocol, .openaiCompletions)
        XCTAssertEqual(provider.customHeaders["comate_custom_header"], c.customHeaders["comate_custom_header"])
        XCTAssertNotNil(provider.modelSpec(for: c.model))
        XCTAssertEqual(policy.primary, "\(provider.name)/\(c.model)")
    }

    func testAuthApplyBindResult() {
        var c = LijiConfig.baiduMapDefault()
        let dto = LijiBindDTO(token: "tok123", uuapname: "erik", cuid: "CUID9",
                              expiresAt: 0, endpoints: ["10.1.2.3:18070"], port: 18070)
        c = LijiAuthManager.applyBindResult(dto, to: c)
        XCTAssertEqual(c.cuid, "CUID9")
        XCTAssertEqual(c.clientToken, "tok123")
        XCTAssertEqual(c.directBaseURL, "http://10.1.2.3:18070")
        XCTAssertEqual(LijiAuthManager.normalizeEndpoint("https://x.y"), "https://x.y")
        XCTAssertEqual(LijiAuthManager.normalizeEndpoint("1.2.3.4:80"), "http://1.2.3.4:80")
        _ = LijiServerClient(config: c)
    }

    func testPanelDataSourceRequirementRows() throws {
        let json = """
        [{"id":"t1","title":"任务A","created_at":0,"updated_at":0,"requirements":[
          {"id":"r1","task_id":"t1","prompt":"p1","status":"patch_generated","summary":"s1","error":"","iteration":1,
           "patch":{"id":"p1","name":"n1","apply_mode":"instant","js_sha256":"abc","download_url":"/x"}},
          {"id":"r2","task_id":"t1","prompt":"p2","status":"failed","summary":"","error":"boom","iteration":0,"patch":null}
        ]}]
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let tasks = try dec.decode([LijiTaskDTO].self, from: json)

        let rows = LijiPanelDataSource.requirementRows(from: tasks)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].status, .patchGenerated)
        XCTAssertEqual(rows[0].status.displayText, "已生成补丁")
        XCTAssertTrue(rows[0].canApply)
        XCTAssertTrue(rows[0].canShare)
        XCTAssertFalse(rows[0].canCancel)
        XCTAssertEqual(rows[1].status, .failed)
        XCTAssertTrue(rows[1].canRegenerate)
        XCTAssertFalse(rows[1].canApply)
    }

    func testPanelDataSourceGrantRows() throws {
        let json = """
        [{"token":"tok1","title":"分享标题","note":"备注","owner":"bob","enabled":true,
          "patch":{"id":"p9","name":"n9","apply_mode":"restart","js_sha256":"xyz","download_url":"/y"}}]
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let grants = try dec.decode([LijiGrantDTO].self, from: json)

        let rows = LijiPanelDataSource.grantRows(from: grants)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].owner, "bob")
        XCTAssertEqual(rows[0].patchId, "p9")
        XCTAssertTrue(rows[0].enabled)
    }

    func testToolsetRespectsFlags() {
        // 默认：仅 liji_server 工具
        let defaultTools = LijiToolset.makeTools(config: .baiduMapDefault())
        XCTAssertEqual(defaultTools.map(\.name).sorted(), ["liji_server"])

        // 开启 runtime + hotfix，并注入 provider
        var c = LijiConfig.baiduMapDefault()
        c.runtimeToolsEnabled = true
        c.hotfixEnabled = true
        let tools = LijiToolset.makeTools(config: c,
                                          runtimeProvider: MockRuntime(),
                                          hotfixProvider: MockHotfix())
        // app_hook_capture 随 runtimeToolsEnabled 开放（自包含，无需 provider）。
        XCTAssertEqual(Set(tools.map(\.name)),
                       ["liji_server", "app_runtime_inspect", "app_hook_capture", "app_hotfix"])

        // 开启但不注入 provider → 需要 provider 的工具跳过；app_hook_capture 仍在。
        let toolsNoProvider = LijiToolset.makeTools(config: c)
        XCTAssertEqual(toolsNoProvider.map(\.name).sorted(), ["app_hook_capture", "liji_server"])
    }

    func testRequirementDTODecoding() throws {
        let json = """
        {"id":"r1","task_id":"t1","prompt":"p","status":"patch_generated","summary":"s","error":"","iteration":1,
         "patch":{"id":"p1","name":"liji_x","apply_mode":"instant","js_sha256":"abc","download_url":"/api/v1/patches/p1"}}
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let req = try dec.decode(LijiRequirementDTO.self, from: json)
        XCTAssertEqual(req.id, "r1")
        XCTAssertEqual(req.taskId, "t1")
        XCTAssertEqual(req.status, "patch_generated")
        XCTAssertEqual(req.patch?.applyMode, "instant")
        XCTAssertEqual(req.patch?.jsSha256, "abc")
    }
}

// MARK: - Mocks

private struct MockRuntime: RuntimeInspectProvider {
    func uiHierarchy() async -> String { "root" }
    func classList(matching filter: String?) async -> [String] { ["BMFoo"] }
    func methodList(ofClass className: String) async -> [String] { ["- (void)foo"] }
    func propertyList(ofClass className: String) async -> [String] { ["title"] }
    func propertyValue(keyPath: String, ofClass className: String?) async -> String? { "v" }
    func invoke(className: String, selector: String, argumentsJSON: String) async -> String { "ok" }
}

private struct MockHotfix: HotfixProvider {
    func apply(name: String, javascript: String, applyMode: String, summary: String) async -> HotfixApplyResult {
        HotfixApplyResult(success: true, applyMode: applyMode, message: "ok", needsRestart: applyMode == "restart")
    }
    func setEnabled(name: String, enabled: Bool) async -> Bool { true }
    func list() async -> [HotfixPatchInfo] { [] }
    func remove(name: String) async -> Bool { true }
}
