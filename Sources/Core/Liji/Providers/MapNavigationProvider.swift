//
//  MapNavigationProvider.swift
//  AppAgent — Liji 集成层
//
//  「实时导航状态」作为只读 agent 能力：读取当前是否在导航、目的地、剩余里程/时间、
//  下一步转向提示、当前道路等。供 agent 解析「还有多久到」「下一个路口怎么走」「离目的地多远」
//  等诉求——取到结构化导航态后可直接答复，或用 app_map_control 移动视野、app_map_draw 标注。
//  宿主（百度地图）在其导航管理器（BNaviManager / BMKNaviManager 等）之上实现，
//  通常经稳定 seam 反射取值，便于后续热修复。
//

import Foundation

/// 当前导航状态快照。
public struct NavigationStatus: Sendable, Codable {
    /// 是否正在导航。
    public var isNavigating: Bool
    /// 出行方式：driving|walking|riding|transit 等（provider 自定，可空）。
    public var mode: String?
    /// 目的地名称（可空）。
    public var destinationName: String?
    /// 目的地纬度（可空）。
    public var destinationLatitude: Double?
    /// 目的地经度（可空）。
    public var destinationLongitude: Double?
    /// 距目的地剩余里程（米）；未知为 nil。
    public var remainingDistanceMeters: Double?
    /// 预计剩余时间（秒）；未知为 nil。
    public var remainingTimeSeconds: Double?
    /// 下一步转向文案（如「前方 200 米右转」）；未知为 nil。
    public var nextManeuver: String?
    /// 当前所在道路名（可空）。
    public var currentRoad: String?

    public init(isNavigating: Bool, mode: String? = nil,
                destinationName: String? = nil,
                destinationLatitude: Double? = nil, destinationLongitude: Double? = nil,
                remainingDistanceMeters: Double? = nil, remainingTimeSeconds: Double? = nil,
                nextManeuver: String? = nil, currentRoad: String? = nil) {
        self.isNavigating = isNavigating
        self.mode = mode
        self.destinationName = destinationName
        self.destinationLatitude = destinationLatitude
        self.destinationLongitude = destinationLongitude
        self.remainingDistanceMeters = remainingDistanceMeters
        self.remainingTimeSeconds = remainingTimeSeconds
        self.nextManeuver = nextManeuver
        self.currentRoad = currentRoad
    }
}

/// 宿主（百度地图）实现：只读的实时导航状态访问。
public protocol MapNavigationProvider: Sendable {
    /// 当前导航状态快照（未在导航时 isNavigating=false，其余字段可为空）。
    func status() async -> NavigationStatus
}
