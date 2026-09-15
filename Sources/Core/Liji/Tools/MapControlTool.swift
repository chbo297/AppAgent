//
//  MapControlTool.swift
//  AppAgent — Liji 集成层
//
//  把「地图视野控制」暴露为 agent 工具（app_map_control）。仅当宿主注入 MapControlProvider 时注册。
//

import Foundation

public struct MapControlTool: ToolProtocol {
    public let name = "app_map_control"
    public let description = """
        Control the Baidu Map camera/viewport. Choose an 'op':
        - 'get_camera': return current camera {latitude, longitude, zoom, rotation, overlook}.
        - 'set_center': move center to 'latitude'/'longitude' (required); optional 'zoom'.
        - 'set_zoom': set 'zoom' (required, ~3..21).
        - 'fit_bounds': fit a set of points into view. 'coordinates' is a JSON array of [lat,lng];
            optional 'padding' (points, default 40).
        - 'set_map_type': 'map_type' one of standard|satellite|night.
        Common flow: draw overlays with app_map_draw, then fit_bounds to their coordinates.
        'animated' (default true) applies to set_center/set_zoom/fit_bounds.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.",
                          enumValues: ["get_camera", "set_center", "set_zoom", "fit_bounds", "set_map_type"]),
            "latitude": .number(description: "Center latitude (set_center)."),
            "longitude": .number(description: "Center longitude (set_center)."),
            "zoom": .number(description: "Zoom level (set_center optional / set_zoom required)."),
            "coordinates": .string(description: "JSON array of [lat,lng] points (fit_bounds)."),
            "padding": .number(description: "Edge padding in points for fit_bounds (default 40)."),
            "map_type": .string(description: "Layer type.", enumValues: ["standard", "satellite", "night"]),
            "animated": .boolean(description: "Animate the change (default true).")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapControlProvider

    public init(provider: MapControlProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let animated = arguments["animated"]?.boolValue ?? true
        switch op {
        case "get_camera":
            guard let cam = await provider.currentCamera() else {
                return .error("map view unavailable")
            }
            return .json(.object([
                "latitude": .number(cam.latitude),
                "longitude": .number(cam.longitude),
                "zoom": .number(cam.zoom),
                "rotation": .number(cam.rotation),
                "overlook": .number(cam.overlook)
            ]))
        case "set_center":
            guard let lat = arguments["latitude"]?.numberValue,
                  let lng = arguments["longitude"]?.numberValue else {
                return .error("'latitude' and 'longitude' are required for set_center")
            }
            let ok = await provider.setCenter(latitude: lat, longitude: lng,
                                              zoom: arguments["zoom"]?.numberValue, animated: animated)
            return .json(.object(["ok": .bool(ok)]))
        case "set_zoom":
            guard let zoom = arguments["zoom"]?.numberValue else {
                return .error("'zoom' is required for set_zoom")
            }
            let ok = await provider.setZoom(zoom, animated: animated)
            return .json(.object(["ok": .bool(ok)]))
        case "fit_bounds":
            guard let raw = arguments["coordinates"]?.stringValue, let data = raw.data(using: .utf8),
                  let coords = try? JSONDecoder().decode([[Double]].self, from: data), !coords.isEmpty else {
                return .error("'coordinates' JSON array of [lat,lng] is required for fit_bounds")
            }
            let padding = arguments["padding"]?.numberValue ?? 40
            let ok = await provider.fitBounds(coordinates: coords, paddingPt: padding, animated: animated)
            return .json(.object(["ok": .bool(ok), "count": .number(Double(coords.count))]))
        case "set_map_type":
            let type = arguments["map_type"]?.stringValue ?? "standard"
            let ok = await provider.setMapType(type)
            return .json(.object(["ok": .bool(ok), "map_type": .string(type)]))
        default:
            return .error("unknown op: \(op)")
        }
    }
}
