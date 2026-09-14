//
//  MapDrawTool.swift
//  OpenAPP — Liji 集成层
//
//  把「图区绘制」暴露为 agent 工具：agent 可用任意坐标/样式/数据在地图上画任意内容。
//  仅当宿主注入 MapDrawProvider 时注册。
//

import Foundation

public struct MapDrawTool: ToolProtocol {
    public let name = "app_map_draw"
    public let description = """
        Draw arbitrary overlays on the Baidu Map. Choose an 'op':
        - 'draw': render/update shapes. 'shapes' is a JSON array; each item:
            {"kind":"marker|polyline|polygon|circle|text|image",
             "coordinates":[[lat,lng],...],
             "style":{"color":"#RRGGBB","fillColor":"#RRGGBB","width":"3","alpha":"0.8","radius":"100","text":"...","url":"...","zIndex":"1"},
             "id":"optional-stable-id","data":{"any":"payload"}}
          marker/text/circle use coordinates[0]. Returns overlay ids.
        - 'clear': remove overlays by 'ids' (JSON array); omit ids to clear ALL agent overlays.
        - 'list': list current agent overlay ids.
        You can visualize any data (search results, trajectories, custom analytics) by drawing points/lines/polygons/text.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.", enumValues: ["draw", "clear", "list"]),
            "shapes": .string(description: "JSON array of shape descriptors (for draw)."),
            "ids": .string(description: "JSON array of overlay ids (for clear).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    private let provider: MapDrawProvider

    public init(provider: MapDrawProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "draw":
            guard let raw = arguments["shapes"]?.stringValue, let data = raw.data(using: .utf8) else {
                return .error("'shapes' JSON array is required for draw")
            }
            let shapes: [MapDrawShape]
            do {
                shapes = try JSONDecoder().decode([MapDrawShape].self, from: data)
            } catch {
                return .error("cannot parse shapes: \(error)")
            }
            guard !shapes.isEmpty else { return .error("no shapes to draw") }
            let ids = await provider.draw(shapes: shapes)
            return .json(.object(["drawn": .number(Double(ids.count)),
                                  "ids": .array(ids.map { .string($0) })]))
        case "clear":
            var ids: [String]? = nil
            if let raw = arguments["ids"]?.stringValue, let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                ids = parsed
            }
            let n = await provider.clear(ids: ids)
            return .json(.object(["cleared": .number(Double(n))]))
        case "list":
            let ids = await provider.listOverlays()
            return .json(.object(["ids": .array(ids.map { .string($0) })]))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
