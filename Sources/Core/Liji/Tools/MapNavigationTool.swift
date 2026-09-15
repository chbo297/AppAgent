//
//  MapNavigationTool.swift
//  AppAgent — Liji 集成层
//
//  把「实时导航状态」暴露为只读结构化 agent 工具（app_map_navigation）。仅当宿主注入 MapNavigationProvider 时注册。
//

import Foundation

public struct MapNavigationTool: ToolProtocol {
    public let name = "app_map_navigation"
    public let description = """
        Read the user's real-time navigation status from Baidu Map (READ-ONLY).
        Use this to answer phrases like \"how long until I arrive\", \"how far to the destination\",
        or \"what's the next turn\" — then optionally continue with app_map_control (move camera)
        or app_map_draw (annotate). Choose an 'op':
        - 'status': the current navigation snapshot.
        Snapshot: {isNavigating, mode?, destinationName?, destinationLatitude?, destinationLongitude?,
                   remainingDistanceMeters?, remainingTimeSeconds?, nextManeuver?, currentRoad?}.
        When isNavigating is false the user is not navigating and other fields may be absent.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["status"])
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapNavigationProvider

    public init(provider: MapNavigationProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "status":
            let s = await provider.status()
            return .json(.object(["navigation": Self.encode(s)]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ s: NavigationStatus) -> JSONValue {
        var obj: [String: JSONValue] = [
            "isNavigating": .bool(s.isNavigating)
        ]
        if let v = s.mode { obj["mode"] = .string(v) }
        if let v = s.destinationName { obj["destinationName"] = .string(v) }
        if let v = s.destinationLatitude { obj["destinationLatitude"] = .number(v) }
        if let v = s.destinationLongitude { obj["destinationLongitude"] = .number(v) }
        if let v = s.remainingDistanceMeters { obj["remainingDistanceMeters"] = .number(v) }
        if let v = s.remainingTimeSeconds { obj["remainingTimeSeconds"] = .number(v) }
        if let v = s.nextManeuver { obj["nextManeuver"] = .string(v) }
        if let v = s.currentRoad { obj["currentRoad"] = .string(v) }
        return .object(obj)
    }
}
