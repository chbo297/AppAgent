//
//  MapLocationTool.swift
//  AppAgent — Liji 集成层
//
//  把「当前定位」暴露为只读结构化 agent 工具（app_map_location）。仅当宿主注入 MapLocationProvider 时注册。
//

import Foundation

public struct MapLocationTool: ToolProtocol {
    public let name = "app_map_location"
    public let description = """
        Read the user's current location from Baidu Map (READ-ONLY).
        Use this to resolve phrases like \"where am I\", \"from here to X\", or \"what's nearby\"
        into concrete coordinates — then continue with app_map_service (search/route) or
        app_map_control (move camera). Choose an 'op':
        - 'current': the current location snapshot (null if location is unavailable/denied).
        Snapshot: {latitude, longitude, accuracy?, heading?, speed?, city?, address?, timestamp}.
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

    private let provider: MapLocationProvider

    public init(provider: MapLocationProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "current":
            guard let loc = await provider.current() else {
                return .json(.object(["location": .null]))
            }
            return .json(.object(["location": Self.encode(loc)]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ l: UserLocation) -> JSONValue {
        var obj: [String: JSONValue] = [
            "latitude": .number(l.latitude),
            "longitude": .number(l.longitude),
            "timestamp": .number(l.timestamp)
        ]
        if let a = l.accuracy { obj["accuracy"] = .number(a) }
        if let h = l.heading { obj["heading"] = .number(h) }
        if let s = l.speed { obj["speed"] = .number(s) }
        if let c = l.city { obj["city"] = .string(c) }
        if let addr = l.address { obj["address"] = .string(addr) }
        return .object(obj)
    }
}
