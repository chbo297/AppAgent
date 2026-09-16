//
//  MapLocationProvider.swift
//  AppAgent — Liji 集成层
//
//  「当前定位」作为只读 agent 能力：读取用户此刻的定位（坐标、精度、朝向、速度、城市、地址）。
//  供 agent 解析「我现在在哪」「从这里出发去 X」「附近有什么」等诉求——
//  取到当前坐标后再用 app_map_service 检索 / 规划路线，或用 app_map_control 移动视野。
//  宿主（百度地图）在其定位管理器（BMKLocationManager 等）之上实现。
//

import Foundation

/// 用户当前定位快照。
public struct UserLocation: Sendable, Codable {
    /// 纬度。
    public var latitude: Double
    /// 经度。
    public var longitude: Double
    /// 水平精度（米）；未知为 nil。
    public var accuracy: Double?
    /// 朝向（度，0=正北，顺时针）；未知为 nil。
    public var heading: Double?
    /// 速度（米/秒）；未知为 nil。
    public var speed: Double?
    /// 所在城市（可空）。
    public var city: String?
    /// 逆地理地址（可空）。
    public var address: String?
    /// 定位时间的 Unix 时间戳（秒）；未知为 0。
    public var timestamp: Double

    public init(latitude: Double, longitude: Double,
                accuracy: Double? = nil, heading: Double? = nil, speed: Double? = nil,
                city: String? = nil, address: String? = nil, timestamp: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.heading = heading
        self.speed = speed
        self.city = city
        self.address = address
        self.timestamp = timestamp
    }
}

/// 宿主（百度地图）实现：只读的当前定位访问。
public protocol MapLocationProvider: Sendable {
    /// 用户当前定位快照（定位不可用 / 未授权时返回 nil）。
    func current() async -> UserLocation?
}
