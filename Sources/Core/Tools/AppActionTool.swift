//
//  AppActionTool.swift
//  AppAgent
//

import Foundation

/// Tool that executes business actions registered by the host app.
///
/// Thin wrapper over `AppActionProvider`. The agent can trigger pre-registered
/// operations like "add_to_cart", "toggle_favorite", "submit_order", etc.
public struct AppActionTool: ToolProtocol {
    public let name = "app_action"
    public let description = """
        Execute a business action within the app. \
        Call with no arguments to list available actions. \
        Provide 'action' and optional 'parameters' to execute.
        """
    public let parameters = Tool.Schema(
        properties: [
            "action": .string(description: "Action name to execute. Omit to list available actions."),
            "parameters": .object(
                description: "Key-value parameters for the action."
            )
        ],
        required: []
    )
    public let group: String = "custom"
    public let safetyLevel: Tool.SafetyLevel = .sensitive

    private let provider: any AppActionProvider

    public init(provider: any AppActionProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        // No action → list available actions
        guard let actionName = arguments["action"]?.stringValue, !actionName.isEmpty else {
            let actions = await provider.availableActions()
            let items: [JSONValue] = actions.map { a in
                var obj: [String: JSONValue] = [
                    "name": .string(a.name),
                    "description": .string(a.description)
                ]
                if !a.required.isEmpty {
                    obj["required_parameters"] = .array(a.required.map { .string($0) })
                }
                return .object(obj)
            }
            return .json(.object([
                "available_actions": .array(items),
                "count": .number(Double(items.count))
            ]))
        }

        let params = arguments["parameters"]?.objectValue ?? [:]
        return try await provider.execute(action: actionName, parameters: params)
    }
}
