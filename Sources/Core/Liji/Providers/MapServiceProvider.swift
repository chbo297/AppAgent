//
//  MapServiceProvider.swift
//  AppAgent — Liji 集成层
//
//  「地图检索/路线/逆地理」作为结构化 agent 能力：返回结构化结果，agent 可再用 app_map_draw 可视化、
//  用 app_map_control 移动视野。宿主（百度地图）在既有 BMNearbyCtrl / BMOpenApiSearcher / 路线引擎上实现。
//

import Foundation

/// 一个检索/路线结果条目（provider 无关）。
public struct MapServiceResult: Sendable, Codable {
    /// 名称 / 标题。
    public var name: String
    /// 纬度。
    public var latitude: Double
    /// 经度。
    public var longitude: Double
    /// 地址 / 副标题（可空）。
    public var address: String?
    /// POI uid（可空）。
    public var uid: String?
    /// 附加信息（距离、评分、路线时长等，全字符串）。
    public var extra: [String: String]?

    public init(name: String, latitude: Double, longitude: Double,
                address: String? = nil, uid: String? = nil, extra: [String: String]? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.uid = uid
        self.extra = extra
    }
}

/// 宿主（百度地图）实现：结构化检索/路线/逆地理，返回结果供 agent 后续处理。
public protocol MapServiceProvider: Sendable {
    /// POI/周边检索。center 为可选 [lat,lng]；返回命中列表。
    func poiSearch(keyword: String, city: String?, center: [Double]?, limit: Int) async -> [MapServiceResult]
    /// 路线规划。mode: driving|walking|riding|transit。返回关键途经点/终点（附 extra 里的距离/时长）。
    func route(origin: String, destination: String, mode: String) async -> [MapServiceResult]
    /// 逆地理编码：坐标 → 地址描述。
    func reverseGeocode(latitude: Double, longitude: Double) async -> MapServiceResult?
}
