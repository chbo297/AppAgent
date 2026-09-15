//
//  LijiTests.swift
//  AppAgent — Liji 集成层测试
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
        XCTAssertEqual(Set(tools.map(\.name)), ["liji_server", "app_runtime_inspect", "app_hotfix"])

        // 开启但不注入 provider → 跳过对应工具
        let toolsNoProvider = LijiToolset.makeTools(config: c)
        XCTAssertEqual(toolsNoProvider.map(\.name).sorted(), ["liji_server"])
    }

    func testMapDrawShapeDecodingAndTool() async throws {
        let json = """
        [{"kind":"marker","coordinates":[[39.9,116.4]],"style":{"color":"#FF0000"},"id":"m1"},
         {"kind":"polyline","coordinates":[[39.9,116.4],[39.95,116.45]],"style":{"width":"3"}}]
        """
        let shapes = try JSONDecoder().decode([MapDrawShape].self, from: Data(json.utf8))
        XCTAssertEqual(shapes.count, 2)
        XCTAssertEqual(shapes[0].kind, .marker)
        XCTAssertEqual(shapes[0].id, "m1")
        XCTAssertEqual(shapes[1].kind, .polyline)
        XCTAssertEqual(shapes[1].coordinates.count, 2)

        // toolset：注入 drawProvider 即开放 app_map_draw
        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c, drawProvider: MockDraw())
        XCTAssertEqual(tools.map(\.name), ["app_map_draw"])
    }

    func testMapControlCameraCodableAndToolsetWiring() throws {
        // MapCamera Codable round-trip
        let cam = MapCamera(latitude: 39.915, longitude: 116.404, zoom: 14, rotation: 30, overlook: -20)
        let data = try JSONEncoder().encode(cam)
        let back = try JSONDecoder().decode(MapCamera.self, from: data)
        XCTAssertEqual(cam, back)

        // toolset：注入 controlProvider 即开放 app_map_control；与 draw 可同时开放
        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c, drawProvider: MockDraw(), controlProvider: MockControl())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_control"])
        // app_map_control 参数 schema 含 op（required）
        let control = tools.first { $0.name == "app_map_control" }
        XCTAssertNotNil(control)
        XCTAssertTrue(control?.parameters.required.contains("op") ?? false)
    }

    func testMapControlProviderFitBounds() async {
        let m = MockControl()
        let ok = await m.fitBounds(coordinates: [[39.9, 116.4], [39.95, 116.45]], paddingPt: 40, animated: true)
        XCTAssertTrue(ok)
        let cam = await m.currentCamera()
        XCTAssertNotNil(cam)
    }

    func testMapServiceResultCodableAndToolsetWiring() throws {
        let r = MapServiceResult(name: "天安门", latitude: 39.908, longitude: 116.397,
                                 address: "北京市东城区", uid: "poi1", extra: ["distance": "1200"])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(MapServiceResult.self, from: data)
        XCTAssertEqual(back.name, "天安门")
        XCTAssertEqual(back.uid, "poi1")
        XCTAssertEqual(back.extra?["distance"], "1200")

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          controlProvider: MockControl(),
                                          serviceProvider: MockService())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_control", "app_map_service"])
    }

    func testMapServiceProviderSearch() async {
        let m = MockService()
        let hits = await m.poiSearch(keyword: "咖啡", city: "北京", center: [39.9, 116.4], limit: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.name.contains("咖啡"), true)
        let route = await m.route(origin: "A", destination: "B", mode: "driving")
        XCTAssertFalse(route.isEmpty)
        XCTAssertNotNil(route.last?.extra?["duration"])
    }

    func testMapTrajectorySummaryCodableAndToolsetWiring() throws {
        let s = TrajectorySummary(id: "t1", title: "晨跑", mode: "running",
                                  distanceMeters: 5300, durationSeconds: 1800,
                                  startTimestamp: 1_700_000_000, pointCount: 420)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(TrajectorySummary.self, from: data)
        XCTAssertEqual(back.id, "t1")
        XCTAssertEqual(back.mode, "running")
        XCTAssertEqual(back.distanceMeters, 5300)
        XCTAssertEqual(back.pointCount, 420)

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          trajectoryProvider: MockTrajectory())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_trajectory"])
        let traj = tools.first { $0.name == "app_map_trajectory" }
        XCTAssertTrue(traj?.parameters.required.contains("op") ?? false)
    }

    func testMapTrajectoryProviderReads() async {
        let m = MockTrajectory()
        let recording = await m.isRecording()
        XCTAssertTrue(recording)
        let cur = await m.currentSummary()
        XCTAssertEqual(cur?.mode, "walking")
        let recent = await m.recentTrajectories(limit: 2)
        XCTAssertEqual(recent.count, 2)
        XCTAssertNotNil(recent.first?.distanceMeters)
    }

    func testMapFavoritesCodableAndToolsetWiring() throws {
        let p = SavedPlace(name: "家", latitude: 39.90, longitude: 116.40, category: "home",
                           address: "北京市朝阳区", uid: "home1")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SavedPlace.self, from: data)
        XCTAssertEqual(back.category, "home")
        XCTAssertEqual(back.uid, "home1")

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          favoritesProvider: MockFavorites())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_favorites"])
        let fav = tools.first { $0.name == "app_map_favorites" }
        XCTAssertTrue(fav?.parameters.required.contains("op") ?? false)
    }

    func testMapFavoritesProviderReads() async {
        let m = MockFavorites()
        let home = await m.home()
        XCTAssertEqual(home?.category, "home")
        let company = await m.company()
        XCTAssertEqual(company?.category, "company")
        let all = await m.favorites(keyword: nil, limit: 10)
        XCTAssertEqual(all.count, 2)
        let filtered = await m.favorites(keyword: "咖啡", limit: 10)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name.contains("咖啡"), true)
    }

    func testMapLayerStateCodableAndToolsetWiring() throws {
        let s = MapLayerState(key: "traffic", enabled: true, supported: true)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MapLayerState.self, from: data)
        XCTAssertEqual(back.key, "traffic")
        XCTAssertTrue(back.enabled)
        XCTAssertEqual(back.supported, true)

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          layersProvider: MockLayers())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_layers"])
        let layers = tools.first { $0.name == "app_map_layers" }
        XCTAssertTrue(layers?.parameters.required.contains("op") ?? false)
    }

    func testMapLayersProviderReads() async {
        let m = MockLayers()
        let states = await m.layerStates()
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.contains { $0.key == "traffic" })
        let toggled = await m.setLayer(key: "traffic", enabled: true)
        XCTAssertEqual(toggled?.key, "traffic")
        XCTAssertEqual(toggled?.enabled, true)
        let unknown = await m.setLayer(key: "nope", enabled: true)
        XCTAssertNil(unknown)
    }

    func testMapSearchHistoryCodableAndToolsetWiring() throws {
        let e = SearchHistoryEntry(keyword: "火锅", timestamp: 1_700_000_000,
                                   latitude: 39.91, longitude: 116.41, city: "北京", uid: "h1")
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(SearchHistoryEntry.self, from: data)
        XCTAssertEqual(back.keyword, "火锅")
        XCTAssertEqual(back.uid, "h1")
        XCTAssertEqual(back.city, "北京")

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          searchHistoryProvider: MockSearchHistory())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_search_history"])
        let sh = tools.first { $0.name == "app_map_search_history" }
        XCTAssertTrue(sh?.parameters.required.contains("op") ?? false)
    }

    func testMapSearchHistoryProviderReads() async {
        let m = MockSearchHistory()
        let all = await m.recent(keyword: nil, limit: 10)
        XCTAssertEqual(all.count, 3)
        // 最新在前
        XCTAssertEqual(all.first?.keyword, "火锅")
        let filtered = await m.recent(keyword: "咖啡", limit: 10)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.keyword.contains("咖啡"), true)
        let limited = await m.recent(keyword: nil, limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    func testMapLocationCodableAndToolsetWiring() throws {
        let l = UserLocation(latitude: 39.915, longitude: 116.404,
                             accuracy: 12, heading: 90, speed: 1.4,
                             city: "北京", address: "东城区", timestamp: 1_700_000_000)
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(UserLocation.self, from: data)
        XCTAssertEqual(back.latitude, 39.915)
        XCTAssertEqual(back.city, "北京")
        XCTAssertEqual(back.heading, 90)

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          locationProvider: MockLocation())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_location"])
        let loc = tools.first { $0.name == "app_map_location" }
        XCTAssertTrue(loc?.parameters.required.contains("op") ?? false)
    }

    func testMapLocationProviderReads() async {
        let m = MockLocation()
        let loc = await m.current()
        XCTAssertNotNil(loc)
        XCTAssertEqual(loc?.city, "北京")
        XCTAssertEqual(loc?.latitude, 39.915)
        let denied = await MockLocationDenied().current()
        XCTAssertNil(denied)
    }

    func testMapNavigationStatusCodableAndToolsetWiring() throws {
        let s = NavigationStatus(isNavigating: true, mode: "driving",
                                 destinationName: "首都机场",
                                 destinationLatitude: 40.08, destinationLongitude: 116.58,
                                 remainingDistanceMeters: 12500, remainingTimeSeconds: 1500,
                                 nextManeuver: "前方 500 米右转", currentRoad: "机场高速")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(NavigationStatus.self, from: data)
        XCTAssertTrue(back.isNavigating)
        XCTAssertEqual(back.mode, "driving")
        XCTAssertEqual(back.destinationName, "首都机场")
        XCTAssertEqual(back.remainingDistanceMeters, 12500)
        XCTAssertEqual(back.nextManeuver, "前方 500 米右转")

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          navigationProvider: MockNavigation())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_navigation"])
        let nav = tools.first { $0.name == "app_map_navigation" }
        XCTAssertTrue(nav?.parameters.required.contains("op") ?? false)
    }

    func testMapNavigationProviderReads() async {
        let navigating = await MockNavigation().status()
        XCTAssertTrue(navigating.isNavigating)
        XCTAssertEqual(navigating.mode, "driving")
        XCTAssertEqual(navigating.destinationName, "首都机场")
        XCTAssertNotNil(navigating.remainingTimeSeconds)
        let idle = await MockNavigationIdle().status()
        XCTAssertFalse(idle.isNavigating)
        XCTAssertNil(idle.destinationName)
    }

    func testMapTrafficCodableAndToolsetWiring() throws {
        let seg = TrafficSegment(roadName: "机场高速", level: "congested",
                                 lengthMeters: 3200, speedKmh: 18)
        let cond = TrafficCondition(overallLevel: "slow", summary: "多数道路通畅，机场高速拥堵",
                                    segments: [seg], timestamp: 1_700_000_000)
        let data = try JSONEncoder().encode(cond)
        let back = try JSONDecoder().decode(TrafficCondition.self, from: data)
        XCTAssertEqual(back.overallLevel, "slow")
        XCTAssertEqual(back.summary, "多数道路通畅，机场高速拥堵")
        XCTAssertEqual(back.segments.count, 1)
        XCTAssertEqual(back.segments.first?.roadName, "机场高速")
        XCTAssertEqual(back.segments.first?.level, "congested")
        XCTAssertEqual(back.segments.first?.speedKmh, 18)

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          trafficProvider: MockTraffic())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_traffic"])
        let t = tools.first { $0.name == "app_map_traffic" }
        XCTAssertTrue(t?.parameters.required.contains("op") ?? false)
    }

    func testMapTrafficProviderReads() async {
        let cond = await MockTraffic().current()
        XCTAssertNotNil(cond)
        XCTAssertEqual(cond?.overallLevel, "slow")
        XCTAssertEqual(cond?.segments.count, 2)
        XCTAssertEqual(cond?.segments.first?.roadName, "机场高速")
        let none = await MockTrafficUnavailable().current()
        XCTAssertNil(none)
    }

    func testMapNearbyCodableAndToolsetWiring() throws {
        let place = NearbyPlace(name: "老王火锅", category: "food",
                                latitude: 39.91, longitude: 116.41,
                                distanceMeters: 320, rating: 4.6, address: "东城区", uid: "u9")
        let data = try JSONEncoder().encode(place)
        let back = try JSONDecoder().decode(NearbyPlace.self, from: data)
        XCTAssertEqual(back.name, "老王火锅")
        XCTAssertEqual(back.category, "food")
        XCTAssertEqual(back.distanceMeters, 320)
        XCTAssertEqual(back.rating, 4.6)
        XCTAssertEqual(back.uid, "u9")

        var c = LijiConfig.baiduMapDefault()
        c.lijiServerEnabled = false
        let tools = LijiToolset.makeTools(config: c,
                                          drawProvider: MockDraw(),
                                          nearbyProvider: MockNearby())
        XCTAssertEqual(Set(tools.map(\.name)), ["app_map_draw", "app_map_nearby"])
        let t = tools.first { $0.name == "app_map_nearby" }
        XCTAssertTrue(t?.parameters.required.contains("op") ?? false)
    }

    func testMapNearbyProviderReads() async {
        let all = await MockNearby().recommend(category: nil, center: nil, limit: 10)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.name, "老王火锅")
        let food = await MockNearby().recommend(category: "food", center: [39.9, 116.4], limit: 10)
        XCTAssertEqual(food.count, 1)
        XCTAssertEqual(food.first?.category, "food")
        let limited = await MockNearby().recommend(category: nil, center: nil, limit: 2)
        XCTAssertEqual(limited.count, 2)
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

private struct MockDraw: MapDrawProvider {
    func draw(shapes: [MapDrawShape]) async -> [String] { shapes.map { $0.id ?? "auto" } }
    func clear(ids: [String]?) async -> Int { ids?.count ?? 0 }
    func listOverlays() async -> [String] { [] }
}

private struct MockControl: MapControlProvider {
    func currentCamera() async -> MapCamera? { MapCamera(latitude: 39.9, longitude: 116.4, zoom: 12) }
    func setCenter(latitude: Double, longitude: Double, zoom: Double?, animated: Bool) async -> Bool { true }
    func setZoom(_ zoom: Double, animated: Bool) async -> Bool { zoom >= 3 && zoom <= 21 }
    func fitBounds(coordinates: [[Double]], paddingPt: Double, animated: Bool) async -> Bool { !coordinates.isEmpty }
    func setMapType(_ type: String) async -> Bool { ["standard", "satellite", "night"].contains(type) }
}

private struct MockService: MapServiceProvider {
    func poiSearch(keyword: String, city: String?, center: [Double]?, limit: Int) async -> [MapServiceResult] {
        [MapServiceResult(name: "\(keyword)店", latitude: 39.91, longitude: 116.40,
                          address: city ?? "", uid: "u1", extra: ["distance": "800"])]
    }
    func route(origin: String, destination: String, mode: String) async -> [MapServiceResult] {
        [MapServiceResult(name: destination, latitude: 39.92, longitude: 116.41,
                          extra: ["duration": "1200", "distance": "5300", "mode": mode])]
    }
    func reverseGeocode(latitude: Double, longitude: Double) async -> MapServiceResult? {
        MapServiceResult(name: "某地", latitude: latitude, longitude: longitude, address: "示例地址")
    }
}

private struct MockTrajectory: MapTrajectoryProvider {
    func isRecording() async -> Bool { true }
    func currentSummary() async -> TrajectorySummary? {
        TrajectorySummary(id: "cur", title: "进行中", mode: "walking",
                          distanceMeters: 1200, durationSeconds: 600, pointCount: 90)
    }
    func recentTrajectories(limit: Int) async -> [TrajectorySummary] {
        let all = [
            TrajectorySummary(id: "r1", title: "晨跑", mode: "running", distanceMeters: 5300, durationSeconds: 1800),
            TrajectorySummary(id: "r2", title: "骑行", mode: "riding", distanceMeters: 12000, durationSeconds: 2700),
            TrajectorySummary(id: "r3", title: "步行", mode: "walking", distanceMeters: 800, durationSeconds: 500)
        ]
        return Array(all.prefix(limit))
    }
}

private final class MockLayers: MapLayersProvider {
    private var enabled: Set<String> = []
    private let known: Set<String> = ["traffic", "satellite", "indoor", "building3d"]
    func layerStates() async -> [MapLayerState] {
        known.sorted().map { MapLayerState(key: $0, enabled: enabled.contains($0), supported: true) }
    }
    func setLayer(key: String, enabled on: Bool) async -> MapLayerState? {
        guard known.contains(key) else { return nil }
        if on { enabled.insert(key) } else { enabled.remove(key) }
        return MapLayerState(key: key, enabled: on, supported: true)
    }
}

private struct MockSearchHistory: MapSearchHistoryProvider {
    func recent(keyword: String?, limit: Int) async -> [SearchHistoryEntry] {
        // 已按时间倒序（最新在前）
        let all = [
            SearchHistoryEntry(keyword: "火锅", timestamp: 1_700_000_300, latitude: 39.91, longitude: 116.41, city: "北京"),
            SearchHistoryEntry(keyword: "常去咖啡", timestamp: 1_700_000_200, city: "北京"),
            SearchHistoryEntry(keyword: "地铁站", timestamp: 1_700_000_100)
        ]
        let filtered = keyword.map { kw in all.filter { $0.keyword.contains(kw) } } ?? all
        return Array(filtered.prefix(limit))
    }
}

private struct MockLocation: MapLocationProvider {
    func current() async -> UserLocation? {
        UserLocation(latitude: 39.915, longitude: 116.404,
                     accuracy: 10, heading: 45, speed: 0.8,
                     city: "北京", address: "东城区", timestamp: 1_700_000_000)
    }
}

private struct MockLocationDenied: MapLocationProvider {
    func current() async -> UserLocation? { nil }
}

private struct MockNavigation: MapNavigationProvider {
    func status() async -> NavigationStatus {
        NavigationStatus(isNavigating: true, mode: "driving",
                         destinationName: "首都机场",
                         destinationLatitude: 40.08, destinationLongitude: 116.58,
                         remainingDistanceMeters: 12500, remainingTimeSeconds: 1500,
                         nextManeuver: "前方 500 米右转", currentRoad: "机场高速")
    }
}

private struct MockNavigationIdle: MapNavigationProvider {
    func status() async -> NavigationStatus { NavigationStatus(isNavigating: false) }
}

private struct MockTraffic: MapTrafficProvider {
    func current() async -> TrafficCondition? {
        TrafficCondition(overallLevel: "slow", summary: "多数道路通畅，机场高速拥堵",
                         segments: [
                            TrafficSegment(roadName: "机场高速", level: "congested", lengthMeters: 3200, speedKmh: 18),
                            TrafficSegment(roadName: "东三环", level: "smooth", lengthMeters: 5000, speedKmh: 55)
                         ],
                         timestamp: 1_700_000_000)
    }
}

private struct MockTrafficUnavailable: MapTrafficProvider {
    func current() async -> TrafficCondition? { nil }
}

private struct MockNearby: MapNearbyRecommendationProvider {
    func recommend(category: String?, center: [Double]?, limit: Int) async -> [NearbyPlace] {
        let all = [
            NearbyPlace(name: "老王火锅", category: "food", latitude: 39.91, longitude: 116.41,
                        distanceMeters: 320, rating: 4.6, address: "东城区", uid: "u1"),
            NearbyPlace(name: "中石化加油站", category: "gas", latitude: 39.92, longitude: 116.42,
                        distanceMeters: 800, uid: "u2"),
            NearbyPlace(name: "银河SOHO停车场", category: "parking", latitude: 39.93, longitude: 116.43,
                        distanceMeters: 500, rating: 4.1)
        ]
        let filtered = category.map { cat in all.filter { $0.category == cat } } ?? all
        return Array(filtered.prefix(limit))
    }
}

private struct MockFavorites: MapFavoritesProvider {
    func home() async -> SavedPlace? {
        SavedPlace(name: "家", latitude: 39.90, longitude: 116.40, category: "home", address: "朝阳区")
    }
    func company() async -> SavedPlace? {
        SavedPlace(name: "公司", latitude: 39.98, longitude: 116.31, category: "company", address: "海淀区")
    }
    func favorites(keyword: String?, limit: Int) async -> [SavedPlace] {
        let all = [
            SavedPlace(name: "常去咖啡", latitude: 39.91, longitude: 116.41, category: "favorite"),
            SavedPlace(name: "健身房", latitude: 39.92, longitude: 116.42, category: "favorite")
        ]
        let filtered = keyword.map { kw in all.filter { $0.name.contains(kw) } } ?? all
        return Array(filtered.prefix(limit))
    }
}
