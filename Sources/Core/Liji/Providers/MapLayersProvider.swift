//
//  MapLayersProvider.swift
//  AppAgent — Liji 集成层
//
//  「地图图层开关」作为 agent 能力：查询与切换实时路况、卫星图、室内图、3D 建筑等图层。
//  与 app_map_control 的 set_map_type（底图类型）互补——本工具管的是叠加/显示类图层开关。
//  宿主（百度地图）在 BMKMapView 的 trafficEnabled / baiduHeatMapEnabled / showsBuildingInfo 等属性上实现。
//

import Foundation

/// 一个可开关的地图图层的当前状态。
public struct MapLayerState: Sendable, Codable {
    /// 图层键：traffic|satellite|indoor|building3d|heatmap 等（provider 自定）。
    public var key: String
    /// 是否开启。
    public var enabled: Bool
    /// 该图层是否可用/受支持（可空，nil 视为可用）。
    public var supported: Bool?

    public init(key: String, enabled: Bool, supported: Bool? = nil) {
        self.key = key
        self.enabled = enabled
        self.supported = supported
    }
}

/// 宿主（百度地图）实现：地图叠加图层的查询与开关。
public protocol MapLayersProvider: Sendable {
    /// 列出所有可开关图层的当前状态。
    func layerStates() async -> [MapLayerState]
    /// 开关某个图层；返回该图层切换后的最新状态（不支持/无此图层返回 nil）。
    func setLayer(key: String, enabled: Bool) async -> MapLayerState?
}
