//
//  MapSearchHistoryTool.swift
//  AppAgent — Liji 集成层
//
//  把「搜索历史」暴露为只读结构化 agent 工具（app_map_search_history）。仅当宿主注入 MapSearchHistoryProvider 时注册。
//

import Foundation

public struct MapSearchHistoryTool: ToolProtocol {
    public let name = "app_map_search_history"
    public let description = """
        Read the user's recent place/POI search history from Baidu Map (READ-ONLY).
        Use this to resolve phrases like "the place I searched last time", "re-navigate to that
        restaurant I looked up", or "the hotpot I searched yesterday" into a concrete keyword and,
        when available, coordinates — then continue with app_map_service / app_map_control. Choose an 'op':
        - 'recent': recent search entries (newest first); optional 'keyword' to filter by substring, 'limit' (default 10).
        Each entry: {keyword, timestamp, latitude?, longitude?, city?, uid?}.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["recent"]),
            "keyword": .string(description: "Filter history by keyword substring (optional)."),
            "limit": .integer(description: "Max entries (default 10).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapSearchHistoryProvider

    public init(provider: MapSearchHistoryProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "recent":
            let limit = Int(arguments["limit"]?.numberValue ?? 10)
            let entries = await provider.recent(keyword: arguments["keyword"]?.stringValue,
                                                limit: max(1, limit))
            return .json(.object([
                "count": .number(Double(entries.count)),
                "entries": .array(entries.map(Self.encode))
            ]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ e: SearchHistoryEntry) -> JSONValue {
        var obj: [String: JSONValue] = [
            "keyword": .string(e.keyword),
            "timestamp": .number(e.timestamp)
        ]
        if let lat = e.latitude { obj["latitude"] = .number(lat) }
        if let lon = e.longitude { obj["longitude"] = .number(lon) }
        if let c = e.city { obj["city"] = .string(c) }
        if let u = e.uid { obj["uid"] = .string(u) }
        return .object(obj)
    }
}
