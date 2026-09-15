//
//  MapControlProvider.swift
//  AppAgent — Liji 集成层
//
//  「地图视野控制」作为 agent 能力：让 app agent 读取/设置地图相机（中心点、缩放、旋转、俯视）、
//  按一组坐标自适应视野、切换图层类型。宿主（百度地图）在既有 BMKMapView 之上实现本协议。
//  与 MapDrawProvider 配合：agent 可以「画完覆盖物后把视野移动到覆盖物范围」。
//

import Foundation

/// 地图相机状态（provider 无关）。
public struct MapCamera: Sendable, Codable, Equatable {
    /// 中心点纬度。
    public var latitude: Double
    /// 中心点经度。
    public var longitude: Double
    /// 缩放级别（百度地图通常 3~21）。
    public var zoom: Double
    /// 旋转角（度，0 为正北）。
    public var rotation: Double
    /// 俯视角（度，0 为正视）。
    public var overlook: Double

    public init(latitude: Double, longitude: Double, zoom: Double,
                rotation: Double = 0, overlook: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.zoom = zoom
        self.rotation = rotation
        self.overlook = overlook
    }
}

/// 宿主（百度地图）实现：把 agent 的视野控制意图落到当前地图控件。
public protocol MapControlProvider: Sendable {
    /// 读取当前相机；拿不到地图控件返回 nil。
    func currentCamera() async -> MapCamera?
    /// 设置中心点（可选同时设缩放）。返回是否成功下发。
    func setCenter(latitude: Double, longitude: Double, zoom: Double?, animated: Bool) async -> Bool
    /// 单独设置缩放级别。
    func setZoom(_ zoom: Double, animated: Bool) async -> Bool
    /// 让一组坐标（每个 [lat,lng]）自适应进可视区域，padding 为四周留白（点）。
    func fitBounds(coordinates: [[Double]], paddingPt: Double, animated: Bool) async -> Bool
    /// 切换图层类型：standard / satellite / night（宿主自解释）。
    func setMapType(_ type: String) async -> Bool
}
