//
//  MapServiceTool.swift
//  AppAgent — Liji 集成层
//
//  把「检索/路线/逆地理」暴露为结构化 agent 工具（app_map_service）。仅当宿主注入 MapServiceProvider 时注册。
//

import Foundation

public struct MapServiceTool: ToolProtocol {
    public let name = "app_map_service"
    public let description = """
        Query Baidu Map services and get STRUCTURED results (which you can then visualize with
        app_map_draw and move the camera to with app_map_control). Choose an 'op':
        - 'poi_search': search POIs. 'keyword' required; optional 'city', 'center' ([lat,lng] JSON), 'limit'.
        - 'route': plan a route. 'origin' and 'destination' required (names or "lat,lng");
            optional 'mode' one of driving|walking|riding|transit.
        - 'reverse_geocode': 'latitude'/'longitude' → address.
        Each result: {name, latitude, longitude, address?, uid?, extra?}.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["poi_search", "route", "reverse_geocode"]),
            "keyword": .string(description: "Search keyword (poi_search)."),
            "city": .string(description: "City name (poi_search, optional)."),
            "center": .string(description: "JSON [lat,lng] search center (poi_search, optional)."),
            "limit": .integer(description: "Max results (poi_search, default 10)."),
            "origin": .string(description: "Route origin (route)."),
            "destination": .string(description: "Route destination (route)."),
            "mode": .string(description: "Route mode.", enumValues: ["driving", "walking", "riding", "transit"]),
            "latitude": .number(description: "Latitude (reverse_geocode)."),
            "longitude": .number(description: "Longitude (reverse_geocode).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapServiceProvider

    public init(provider: MapServiceProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "poi_search":
            guard let keyword = arguments["keyword"]?.stringValue, !keyword.isEmpty else {
                return .error("'keyword' is required for poi_search")
            }
            var center: [Double]? = nil
            if let raw = arguments["center"]?.stringValue, let data = raw.data(using: .utf8) {
                center = try? JSONDecoder().decode([Double].self, from: data)
            }
            let limit = Int(arguments["limit"]?.numberValue ?? 10)
            let results = await provider.poiSearch(keyword: keyword,
                                                   city: arguments["city"]?.stringValue,
                                                   center: center, limit: max(1, limit))
            return Self.encode(results)
        case "route":
            guard let origin = arguments["origin"]?.stringValue,
                  let destination = arguments["destination"]?.stringValue else {
                return .error("'origin' and 'destination' are required for route")
            }
            let mode = arguments["mode"]?.stringValue ?? "driving"
            let results = await provider.route(origin: origin, destination: destination, mode: mode)
            return Self.encode(results)
        case "reverse_geocode":
            guard let lat = arguments["latitude"]?.numberValue,
                  let lng = arguments["longitude"]?.numberValue else {
                return .error("'latitude' and 'longitude' are required for reverse_geocode")
            }
            guard let r = await provider.reverseGeocode(latitude: lat, longitude: lng) else {
                return .error("no address found")
            }
            return Self.encode([r])
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ results: [MapServiceResult]) -> Tool.Output {
        let items: [JSONValue] = results.map { r in
            var obj: [String: JSONValue] = [
                "name": .string(r.name),
                "latitude": .number(r.latitude),
                "longitude": .number(r.longitude)
            ]
            if let a = r.address { obj["address"] = .string(a) }
            if let u = r.uid { obj["uid"] = .string(u) }
            if let e = r.extra { obj["extra"] = .object(e.mapValues { .string($0) }) }
            return .object(obj)
        }
        return .json(.object(["count": .number(Double(results.count)), "results": .array(items)]))
    }
}
