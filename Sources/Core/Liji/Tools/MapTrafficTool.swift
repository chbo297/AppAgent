//
//  MapTrafficTool.swift
//  AppAgent — Liji 集成层
//
//  把「实时路况」暴露为只读结构化 agent 工具（app_map_traffic）。仅当宿主注入 MapTrafficProvider 时注册。
//

import Foundation

public struct MapTrafficTool: ToolProtocol {
    public let name = "app_map_traffic"
    public let description = """
        Read real-time traffic conditions around the current map view from Baidu Map (READ-ONLY).
        Use this to resolve phrases like \"is it congested now\", \"is this road clear\", or
        \"which segment is most jammed\". Complements app_map_layers (which toggles the traffic
        overlay's visibility) by returning the actual structured congestion data. Choose an 'op':
        - 'current': the current traffic snapshot (null if traffic data is unavailable).
        Snapshot: {overallLevel, summary?, timestamp, segments:[{roadName, level, lengthMeters?, speedKmh?}]}.
        Levels: smooth|slow|congested|severe|unknown.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["current"])
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapTrafficProvider

    public init(provider: MapTrafficProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "current":
            guard let cond = await provider.current() else {
                return .json(.object(["traffic": .null]))
            }
            return .json(.object(["traffic": Self.encode(cond)]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ c: TrafficCondition) -> JSONValue {
        var obj: [String: JSONValue] = [
            "overallLevel": .string(c.overallLevel),
            "timestamp": .number(c.timestamp),
            "segments": .array(c.segments.map(Self.encodeSegment))
        ]
        if let s = c.summary { obj["summary"] = .string(s) }
        return .object(obj)
    }

    private static func encodeSegment(_ s: TrafficSegment) -> JSONValue {
        var obj: [String: JSONValue] = [
            "roadName": .string(s.roadName),
            "level": .string(s.level)
        ]
        if let l = s.lengthMeters { obj["lengthMeters"] = .number(l) }
        if let v = s.speedKmh { obj["speedKmh"] = .number(v) }
        return .object(obj)
    }
}
