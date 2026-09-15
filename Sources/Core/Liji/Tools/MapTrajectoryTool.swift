//
//  MapTrajectoryTool.swift
//  AppAgent — Liji 集成层
//
//  把「轨迹/运动记录」暴露为只读结构化 agent 工具（app_map_trajectory）。仅当宿主注入 MapTrajectoryProvider 时注册。
//

import Foundation

public struct MapTrajectoryTool: ToolProtocol {
    public let name = "app_map_trajectory"
    public let description = """
        Read the user's trajectory / movement records from Baidu Map (READ-ONLY). Choose an 'op':
        - 'status': whether a trajectory is currently being recorded (navigation / sport in progress).
        - 'current': real-time summary of the in-progress trajectory (nil if none).
        - 'recent': the most recent finished trajectories, newest first. Optional 'limit' (default 5).
        Each summary: {id?, title?, mode?, distanceMeters?, durationSeconds?, startTimestamp?, pointCount?}.
        Use this to answer questions like "how far did I run today" or "am I recording right now",
        then optionally visualize with app_map_draw.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["status", "current", "recent"]),
            "limit": .integer(description: "Max records for 'recent' (default 5).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapTrajectoryProvider

    public init(provider: MapTrajectoryProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "status":
            let recording = await provider.isRecording()
            return .json(.object(["recording": .bool(recording)]))
        case "current":
            guard let s = await provider.currentSummary() else {
                return .json(.object(["recording": .bool(false), "current": .null]))
            }
            return .json(.object(["recording": .bool(true), "current": Self.encode(s)]))
        case "recent":
            let limit = Int(arguments["limit"]?.numberValue ?? 5)
            let items = await provider.recentTrajectories(limit: max(1, limit))
            return .json(.object([
                "count": .number(Double(items.count)),
                "trajectories": .array(items.map(Self.encode))
            ]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ s: TrajectorySummary) -> JSONValue {
        var obj: [String: JSONValue] = [:]
        if let v = s.id { obj["id"] = .string(v) }
        if let v = s.title { obj["title"] = .string(v) }
        if let v = s.mode { obj["mode"] = .string(v) }
        if let v = s.distanceMeters { obj["distanceMeters"] = .number(v) }
        if let v = s.durationSeconds { obj["durationSeconds"] = .number(v) }
        if let v = s.startTimestamp { obj["startTimestamp"] = .number(v) }
        if let v = s.pointCount { obj["pointCount"] = .number(Double(v)) }
        return .object(obj)
    }
}
