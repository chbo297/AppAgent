//
//  AppNavigateTool.swift
//  AppAgent
//

import Foundation

/// Tool that navigates to pages within the host app.
///
/// Thin wrapper over `AppNavigationProvider` — the host app provides the actual navigation logic.
public struct AppNavigateTool: ToolProtocol {
    public let name = "app_navigate"
    public let description = """
        Navigate to a page within the app. Use this to direct the user to specific screens \
        (settings, profile, order details, etc.). Call with no arguments to list available routes.
        """
    public let parameters = Tool.Schema(
        properties: [
            "route": .string(description: "Route name to navigate to. Omit to list available routes."),
            "parameters": .object(
                description: "Key-value parameters for the route (e.g., {\"order_id\": \"12345\"})."
            )
        ],
        required: []
    )
    public let group: String = "custom"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    private let provider: any AppNavigationProvider

    public init(provider: any AppNavigationProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        // No route → list available routes
        guard let route = arguments["route"]?.stringValue, !route.isEmpty else {
            let routes = await provider.availableRoutes()
            let items: [JSONValue] = routes.map { r in
                var obj: [String: JSONValue] = [
                    "name": .string(r.name),
                    "description": .string(r.description)
                ]
                if !r.parameters.isEmpty {
                    obj["parameters"] = .array(r.parameters.map { .string($0) })
                }
                return .object(obj)
            }
            return .json(.object([
                "available_routes": .array(items),
                "count": .number(Double(items.count))
            ]))
        }

        // Extract parameters
        var params: [String: String] = [:]
        if let paramsObj = arguments["parameters"]?.objectValue {
            for (key, val) in paramsObj {
                if let s = val.stringValue { params[key] = s }
                else if let n = val.numberValue { params[key] = String(n) }
                else if let b = val.boolValue { params[key] = String(b) }
            }
        }

        try await provider.navigate(to: route, parameters: params)

        return .json(.object([
            "success": .bool(true),
            "route": .string(route),
            "message": .string("Navigated to '\(route)'")
        ]))
    }
}
