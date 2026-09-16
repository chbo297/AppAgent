//
//  MapDrawProvider.swift
//  AppAgent — Liji 集成层
//
//  「图区绘制」作为 agent 能力（tool）：让 app agent 用任意坐标/样式/数据在地图上绘制任意内容。
//  不改地图 C++ 渲染引擎——由宿主实现一个覆盖物(overlay)层，agent 通过本 provider 增删改。
//

import Foundation

/// 一个可绘制图形的描述（provider 无关；坐标为 [纬度, 经度]）。
public struct MapDrawShape: Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case marker      // 点标注
        case polyline    // 折线
        case polygon     // 多边形
        case circle      // 圆（coordinates[0] 为圆心，style["radius"] 米）
        case text        // 文本标注（coordinates[0] 处）
        case image       // 图片覆盖物（style["url"]）
    }
    public var kind: Kind
    /// 坐标数组，每个元素为 [lat, lng]。marker/text/circle 取第一个点。
    public var coordinates: [[Double]]
    /// 样式与附加参数：color/fillColor/width/alpha/radius/text/url/zIndex 等，全部字符串，宿主自解释。
    public var style: [String: String]
    /// 稳定 id：用于后续更新/删除；不传则由宿主分配。
    public var id: String?
    /// 任意业务数据载荷（点击回传、标签等）。
    public var data: [String: String]?

    public init(kind: Kind, coordinates: [[Double]], style: [String: String] = [:],
                id: String? = nil, data: [String: String]? = nil) {
        self.kind = kind
        self.coordinates = coordinates
        self.style = style
        self.id = id
        self.data = data
    }
}

/// 宿主（百度地图）实现：把 agent 的绘制意图落到地图覆盖物层。
public protocol MapDrawProvider: Sendable {
    /// 绘制/更新一批图形，返回它们的 overlay id（与传入 id 对应或新分配）。
    func draw(shapes: [MapDrawShape]) async -> [String]
    /// 清除指定 id 的覆盖物；ids 为 nil 时清除全部由 agent 绘制的覆盖物。
    func clear(ids: [String]?) async -> Int
    /// 列出当前 agent 覆盖物 id。
    func listOverlays() async -> [String]
}
