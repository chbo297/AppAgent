//
//  LijiToolset.swift
//  AppAgent — Liji 集成层
//
//  按 LijiConfig 的能力开关 + 已注入的 provider，组装 app agent 在百度地图中的工具集合。
//  宿主拿到数组后自行注册到 ToolCentral（或通过 AIAgentProfile 暴露）。
//

import Foundation

public enum LijiToolset {

    /// 依据配置与可用 provider 组装工具。未启用或缺失 provider 的能力自动跳过。
    public static func makeTools(
        config: LijiConfig,
        runtimeProvider: RuntimeInspectProvider? = nil,
        hotfixProvider: HotfixProvider? = nil,
        serverClient: LijiServerClient? = nil,
        drawProvider: MapDrawProvider? = nil,
        controlProvider: MapControlProvider? = nil,
        serviceProvider: MapServiceProvider? = nil,
        trajectoryProvider: MapTrajectoryProvider? = nil,
        favoritesProvider: MapFavoritesProvider? = nil,
        layersProvider: MapLayersProvider? = nil,
        searchHistoryProvider: MapSearchHistoryProvider? = nil,
        locationProvider: MapLocationProvider? = nil,
        navigationProvider: MapNavigationProvider? = nil,
        trafficProvider: MapTrafficProvider? = nil,
        nearbyProvider: MapNearbyRecommendationProvider? = nil
    ) -> [any ToolProtocol] {
        var tools: [any ToolProtocol] = []

        if config.lijiServerEnabled {
            let client = serverClient ?? LijiServerClient(config: config)
            tools.append(LijiServerTool(client: client,
                                        hotfix: config.hotfixEnabled ? hotfixProvider : nil))
        }
        if config.runtimeToolsEnabled, let runtimeProvider {
            tools.append(RuntimeInspectTool(provider: runtimeProvider))
        }
        if config.hotfixEnabled, let hotfixProvider {
            tools.append(HotfixTool(provider: hotfixProvider))
        }
        // 图区绘制作为 agent 能力：注入 provider 即开放（默认地图能力）
        if let drawProvider {
            tools.append(MapDrawTool(provider: drawProvider))
        }
        // 地图视野控制：注入 provider 即开放
        if let controlProvider {
            tools.append(MapControlTool(provider: controlProvider))
        }
        // 结构化检索/路线/逆地理：注入 provider 即开放
        if let serviceProvider {
            tools.append(MapServiceTool(provider: serviceProvider))
        }
        // 轨迹/运动记录（只读）：注入 provider 即开放
        if let trajectoryProvider {
            tools.append(MapTrajectoryTool(provider: trajectoryProvider))
        }
        // 收藏点/常用地址（只读）：注入 provider 即开放
        if let favoritesProvider {
            tools.append(MapFavoritesTool(provider: favoritesProvider))
        }
        // 地图图层开关（实时路况/卫星/室内图/3D建筑等）：注入 provider 即开放
        if let layersProvider {
            tools.append(MapLayersTool(provider: layersProvider))
        }
        // 搜索历史（只读）：注入 provider 即开放
        if let searchHistoryProvider {
            tools.append(MapSearchHistoryTool(provider: searchHistoryProvider))
        }
        // 当前定位（只读）：注入 provider 即开放
        if let locationProvider {
            tools.append(MapLocationTool(provider: locationProvider))
        }
        // 实时导航状态（只读）：注入 provider 即开放
        if let navigationProvider {
            tools.append(MapNavigationTool(provider: navigationProvider))
        }
        // 实时路况（只读）：注入 provider 即开放
        if let trafficProvider {
            tools.append(MapTrafficTool(provider: trafficProvider))
        }
        // 周边推荐（只读）：注入 provider 即开放
        if let nearbyProvider {
            tools.append(MapNearbyRecommendationTool(provider: nearbyProvider))
        }
        return tools
    }
}
