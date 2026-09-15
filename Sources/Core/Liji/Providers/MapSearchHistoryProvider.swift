//
//  MapSearchHistoryProvider.swift
//  AppAgent — Liji 集成层
//
//  「搜索历史」作为只读 agent 能力：读取用户最近的地点/POI 搜索记录，
//  供 agent 解析「上次搜的那家店」「重新导航到我搜过的地方」「继续看昨天搜的火锅」等诉求——
//  取到历史条目（含关键词与可选坐标）后再用 app_map_service 检索 / app_map_control 移动视野。
//  宿主（百度地图）在搜索历史存储之上实现。
//

import Foundation

/// 一条搜索历史记录。
public struct SearchHistoryEntry: Sendable, Codable {
    /// 搜索关键词 / 被点选 POI 的名称。
    public var keyword: String
    /// 记录发生的 Unix 时间戳（秒）；未知为 0。
    public var timestamp: Double
    /// 若该历史关联具体地点则带纬度（可空）。
    public var latitude: Double?
    /// 若该历史关联具体地点则带经度（可空）。
    public var longitude: Double?
    /// 城市（可空）。
    public var city: String?
    /// POI uid（可空）。
    public var uid: String?

    public init(keyword: String, timestamp: Double = 0,
                latitude: Double? = nil, longitude: Double? = nil,
                city: String? = nil, uid: String? = nil) {
        self.keyword = keyword
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.uid = uid
    }
}

/// 宿主（百度地图）实现：只读的搜索历史访问。
public protocol MapSearchHistoryProvider: Sendable {
    /// 最近的搜索历史，最多 limit 条（按时间倒序，最新在前）；
    /// keyword 非空时按关键词过滤（子串匹配）。
    func recent(keyword: String?, limit: Int) async -> [SearchHistoryEntry]
}
