//
//  MapTrafficProvider.swift
//  AppAgent — Liji 集成层
//
//  「实时路况」作为只读 agent 能力：读取当前视野 / 路线附近的实时交通拥堵状况。
//  供 agent 解析「现在堵不堵」「这条路通畅吗」「附近哪段最堵」等诉求——
//  取到结构化路况后可直接答复，或用 app_map_layers 打开路况图层、app_map_control 移动视野。
//  与 app_map_layers 的 traffic 图层开关互补：图层管的是"显示与否"，本工具读的是"具体拥堵数据"。
//  宿主（百度地图）在其路况服务（BMKMapView.trafficEnabled 数据源 / 路况 searcher）之上实现。
//

import Foundation

/// 一段道路的实时路况。
public struct TrafficSegment: Sendable, Codable {
    /// 道路 / 路段名称。
    public var roadName: String
    /// 拥堵等级：smooth|slow|congested|severe|unknown。
    public var level: String
    /// 路段长度（米）；未知为 nil。
    public var lengthMeters: Double?
    /// 当前平均车速（公里/小时）；未知为 nil。
    public var speedKmh: Double?

    public init(roadName: String, level: String,
                lengthMeters: Double? = nil, speedKmh: Double? = nil) {
        self.roadName = roadName
        self.level = level
        self.lengthMeters = lengthMeters
        self.speedKmh = speedKmh
    }
}

/// 当前区域的实时路况快照。
public struct TrafficCondition: Sendable, Codable {
    /// 整体拥堵等级：smooth|slow|congested|severe|unknown。
    public var overallLevel: String
    /// 人类可读的整体描述（可空，如「多数道路通畅，机场高速拥堵」）。
    public var summary: String?
    /// 分路段路况明细（可能为空）。
    public var segments: [TrafficSegment]
    /// 采集时间的 Unix 时间戳（秒）；未知为 0。
    public var timestamp: Double

    public init(overallLevel: String, summary: String? = nil,
                segments: [TrafficSegment] = [], timestamp: Double = 0) {
        self.overallLevel = overallLevel
        self.summary = summary
        self.segments = segments
        self.timestamp = timestamp
    }
}

/// 宿主（百度地图）实现：只读的实时路况访问。
public protocol MapTrafficProvider: Sendable {
    /// 当前视野 / 定位附近的实时路况快照（路况不可用时返回 nil）。
    func current() async -> TrafficCondition?
}
