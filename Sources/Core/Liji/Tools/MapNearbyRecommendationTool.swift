//
//  MapNearbyRecommendationTool.swift
//  AppAgent — Liji 集成层
//
//  把「周边推荐」暴露为只读结构化 agent 工具（app_map_nearby）。仅当宿主注入 MapNearbyRecommendationProvider 时注册。
//

import Foundation

public struct MapNearbyRecommendationTool: ToolProtocol {
    public let name = "app_map_nearby"
    public let description = """
        Get category-based nearby POI recommendations around the current map view / location
        from Baidu Map (READ-ONLY). Unlike app_map_service's poi_search (which needs an exact
        keyword), use this to resolve open-ended phrases like \"anything good to eat nearby\",
        \"where can I park around here\", or \"fun places nearby\". Choose an 'op':
        - 'recommend': recommended POIs. Optional 'category' (food|gas|parking|scenic|hotel|shopping|other),
            'center' ([lat,lng] JSON; omit to use current location), 'limit' (default 10).
        Each result: {name, category, latitude, longitude, distanceMeters?, rating?, address?, uid?}.
        You can then visualize results with app_map_draw or move the camera with app_map_control.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["recommend"]),
            "category": .string(description: "Category filter (optional).",
                                 enumValues: ["food", "gas", "parking", "scenic", "hotel", "shopping", "other"]),
            "center": .string(description: "JSON [lat,lng] search center (optional; omit to use current location)."),
            "limit": .integer(description: "Max results (default 10).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapNearbyRecommendationProvider

    public init(provider: MapNearbyRecommendationProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "recommend":
            var center: [Double]? = nil
            if let raw = arguments["center"]?.stringValue, let data = raw.data(using: .utf8) {
                center = try? JSONDecoder().decode([Double].self, from: data)
            }
            let limit = Int(arguments["limit"]?.numberValue ?? 10)
            let results = await provider.recommend(category: arguments["category"]?.stringValue,
                                                   center: center, limit: max(1, limit))
            return Self.encode(results)
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ results: [NearbyPlace]) -> Tool.Output {
        let items: [JSONValue] = results.map { p in
            var obj: [String: JSONValue] = [
                "name": .string(p.name),
                "category": .string(p.category),
                "latitude": .number(p.latitude),
                "longitude": .number(p.longitude)
            ]
            if let d = p.distanceMeters { obj["distanceMeters"] = .number(d) }
            if let r = p.rating { obj["rating"] = .number(r) }
            if let a = p.address { obj["address"] = .string(a) }
            if let u = p.uid { obj["uid"] = .string(u) }
            return .object(obj)
        }
        return .json(.object(["count": .number(Double(results.count)), "results": .array(items)]))
    }
}
