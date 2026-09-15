//
//  MapTrajectoryProvider.swift
//  AppAgent — Liji 集成层
//
//  「轨迹/运动记录」作为只读 agent 能力：读取当前录制状态、汇总与最近轨迹点。
//  宿主（百度地图）在 BMTrackManager / BMTrajectoryManager / BMSportDataManager 之上实现，
//  通常经稳定 seam LijiTrajectoryBridge 反射取值，便于后续热修复。
//

import Foundation

/// 单条轨迹（一次运动/导航记录）的摘要。
public struct TrajectorySummary: Sendable, Codable {
    /// 稳定标识（可空）。
    public var id: String?
    /// 标题 / 名称（如「晨跑」）。
    public var title: String?
    /// 出行方式：walking|riding|driving|running 等（provider 自定，可空）。
    public var mode: String?
    /// 里程（米）。
    public var distanceMeters: Double?
    /// 时长（秒）。
    public var durationSeconds: Double?
    /// 起点时间戳（Unix 秒，可空）。
    public var startTimestamp: Double?
    /// 采样点数量（可空）。
    public var pointCount: Int?

    public init(id: String? = nil, title: String? = nil, mode: String? = nil,
                distanceMeters: Double? = nil, durationSeconds: Double? = nil,
                startTimestamp: Double? = nil, pointCount: Int? = nil) {
        self.id = id
        self.title = title
        self.mode = mode
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.startTimestamp = startTimestamp
        self.pointCount = pointCount
    }
}

/// 宿主（百度地图）实现：只读的轨迹/运动数据访问。
public protocol MapTrajectoryProvider: Sendable {
    /// 是否正在录制轨迹（导航/运动进行中）。
    func isRecording() async -> Bool
    /// 当前进行中轨迹的实时汇总；无进行中轨迹返回 nil。
    func currentSummary() async -> TrajectorySummary?
    /// 最近的历史轨迹（按时间倒序），最多 limit 条。
    func recentTrajectories(limit: Int) async -> [TrajectorySummary]
}
