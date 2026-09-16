//
//  MapNearbyRecommendationProvider.swift
//  AppAgent — Liji 集成层
//
//  「周边推荐」作为只读 agent 能力：围绕当前视野 / 定位，按类别（美食/加油站/停车场/景点等）
//  返回一批推荐 POI。与 app_map_service 的 poi_search 互补——后者需要用户给出明确关键词做精确检索，
//  本工具面向「附近有什么好吃的」「附近哪里能停车」「周边有什么好玩的」这类无精确关键词、
//  要按品类拿推荐清单的诉求。取到结构化推荐后可直接答复，或用 app_map_draw 标注、app_map_control 移动视野。
//  宿主（百度地图）在其周边推荐 / 分类检索服务之上实现。
//

import Foundation

/// 一个周边推荐点。
public struct NearbyPlace: Sendable, Codable {
    /// POI 名称。
    public var name: String
    /// 品类标签（如 food|gas|parking|scenic|hotel|shopping|other）。
    public var category: String
    /// 纬度。
    public var latitude: Double
    /// 经度。
    public var longitude: Double
    /// 距当前位置的直线距离（米）；未知为 nil。
    public var distanceMeters: Double?
    /// 评分（0~5）；未知为 nil。
    public var rating: Double?
    /// 地址（可空）。
    public var address: String?
    /// POI 唯一标识（可空）。
    public var uid: String?

    public init(name: String, category: String,
                latitude: Double, longitude: Double,
                distanceMeters: Double? = nil, rating: Double? = nil,
                address: String? = nil, uid: String? = nil) {
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.rating = rating
        self.address = address
        self.uid = uid
    }
}

/// 宿主（百度地图）实现：只读的周边推荐访问。
public protocol MapNearbyRecommendationProvider: Sendable {
    /// 围绕给定中心（nil 表示用当前定位/视野中心）按类别推荐 POI。
    /// - Parameters:
    ///   - category: 品类过滤（nil 表示不限品类，返回综合推荐）。
    ///   - center: 搜索中心 [lat, lng]（nil 表示宿主自行取当前位置）。
    ///   - limit: 最大返回条数。
    func recommend(category: String?, center: [Double]?, limit: Int) async -> [NearbyPlace]
}
