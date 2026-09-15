//
//  MapFavoritesProvider.swift
//  AppAgent — Liji 集成层
//
//  「收藏点 / 常用地址（家、公司）」作为只读 agent 能力：读取用户已保存的地点，
//  供 agent 在「带我回家」「去公司」「导航到我收藏的那家店」等场景取到坐标后再规划路线 / 移动视野。
//  宿主（百度地图）在收藏夹 / 常用地址存储之上实现。
//

import Foundation

/// 一个已保存地点（收藏点或常用地址）。
public struct SavedPlace: Sendable, Codable {
    /// 地点显示名（如「家」「公司」「XX 咖啡」）。
    public var name: String
    /// 纬度。
    public var latitude: Double
    /// 经度。
    public var longitude: Double
    /// 分类：home|company|favorite|other（provider 自定）。
    public var category: String
    /// 详细地址（可空）。
    public var address: String?
    /// POI uid（可空）。
    public var uid: String?

    public init(name: String, latitude: Double, longitude: Double,
                category: String, address: String? = nil, uid: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.address = address
        self.uid = uid
    }
}

/// 宿主（百度地图）实现：只读的收藏点 / 常用地址访问。
public protocol MapFavoritesProvider: Sendable {
    /// 家的地址（未设置返回 nil）。
    func home() async -> SavedPlace?
    /// 公司的地址（未设置返回 nil）。
    func company() async -> SavedPlace?
    /// 收藏点列表，最多 limit 条；keyword 非空时按名称/地址过滤。
    func favorites(keyword: String?, limit: Int) async -> [SavedPlace]
}
