//
//  MapFavoritesTool.swift
//  AppAgent — Liji 集成层
//
//  把「收藏点 / 常用地址」暴露为只读结构化 agent 工具（app_map_favorites）。仅当宿主注入 MapFavoritesProvider 时注册。
//

import Foundation

public struct MapFavoritesTool: ToolProtocol {
    public let name = "app_map_favorites"
    public let description = """
        Read the user's saved places from Baidu Map (READ-ONLY): home, company, and favorites.
        Use this to resolve phrases like "take me home", "go to the office", or "navigate to my saved cafe"
        into concrete coordinates, then plan with app_map_service / move with app_map_control. Choose an 'op':
        - 'home': the user's home address (null if unset).
        - 'company': the user's company/work address (null if unset).
        - 'favorites': saved favorite places; optional 'keyword' to filter by name/address, 'limit' (default 10).
        Each place: {name, latitude, longitude, category(home|company|favorite|other), address?, uid?}.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["home", "company", "favorites"]),
            "keyword": .string(description: "Filter favorites by name/address (favorites, optional)."),
            "limit": .integer(description: "Max favorites (default 10).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapFavoritesProvider

    public init(provider: MapFavoritesProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "home":
            guard let p = await provider.home() else {
                return .json(.object(["place": .null]))
            }
            return .json(.object(["place": Self.encode(p)]))
        case "company":
            guard let p = await provider.company() else {
                return .json(.object(["place": .null]))
            }
            return .json(.object(["place": Self.encode(p)]))
        case "favorites":
            let limit = Int(arguments["limit"]?.numberValue ?? 10)
            let places = await provider.favorites(keyword: arguments["keyword"]?.stringValue,
                                                  limit: max(1, limit))
            return .json(.object([
                "count": .number(Double(places.count)),
                "places": .array(places.map(Self.encode))
            ]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ p: SavedPlace) -> JSONValue {
        var obj: [String: JSONValue] = [
            "name": .string(p.name),
            "latitude": .number(p.latitude),
            "longitude": .number(p.longitude),
            "category": .string(p.category)
        ]
        if let a = p.address { obj["address"] = .string(a) }
        if let u = p.uid { obj["uid"] = .string(u) }
        return .object(obj)
    }
}
