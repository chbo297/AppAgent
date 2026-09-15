//
//  MapLayersTool.swift
//  AppAgent — Liji 集成层
//
//  把「地图图层开关」暴露为结构化 agent 工具（app_map_layers）。仅当宿主注入 MapLayersProvider 时注册。
//

import Foundation

public struct MapLayersTool: ToolProtocol {
    public let name = "app_map_layers"
    public let description = """
        Query and toggle overlay layers on Baidu Map (e.g. real-time traffic, satellite, indoor map,
        3D buildings, heatmap). This is complementary to app_map_control's set_map_type (base map type).
        Choose an 'op':
        - 'list': list all toggleable layers and their current state.
        - 'set': turn a layer on/off. Requires 'key' and 'enabled'. Returns the resulting layer state.
        Each state: {key, enabled, supported?}. Use this for requests like \"show traffic\" or \"turn off satellite\".
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.", enumValues: ["list", "set"]),
            "key": .string(description: "Layer key for 'set' (e.g. traffic|satellite|indoor|building3d|heatmap)."),
            "enabled": .boolean(description: "Desired on/off state for 'set'.")
        ],
        required: ["op"]
    )
    public let group = "liji-map"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: MapLayersProvider

    public init(provider: MapLayersProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        switch op {
        case "list":
            let states = await provider.layerStates()
            return .json(.object([
                "count": .number(Double(states.count)),
                "layers": .array(states.map(Self.encode))
            ]))
        case "set":
            guard let key = arguments["key"]?.stringValue, !key.isEmpty else {
                return .error("'key' is required for set")
            }
            guard let enabled = arguments["enabled"]?.boolValue else {
                return .error("'enabled' is required for set")
            }
            guard let state = await provider.setLayer(key: key, enabled: enabled) else {
                return .json(.object(["ok": .bool(false), "key": .string(key)]))
            }
            return .json(.object(["ok": .bool(true), "layer": Self.encode(state)]))
        default:
            return .error("unknown op: \(op)")
        }
    }

    private static func encode(_ s: MapLayerState) -> JSONValue {
        var obj: [String: JSONValue] = [
            "key": .string(s.key),
            "enabled": .bool(s.enabled)
        ]
        if let sup = s.supported { obj["supported"] = .bool(sup) }
        return .object(obj)
    }
}
