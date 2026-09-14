//
//  AppActionProvider.swift
//  AppAgent
//

import Foundation

/// Protocol for host apps to expose executable business actions to the agent.
///
/// Actions are pre-registered operations the agent can trigger
/// (e.g., "add_to_cart", "toggle_favorite", "submit_order").
public protocol AppActionProvider: Sendable {
    /// List all available actions (so the LLM knows what it can do).
    func availableActions() async -> [AppAction]
    /// Execute a named action with parameters.
    func execute(action: String, parameters: [String: JSONValue]) async throws -> Tool.Output
}

/// Describes an executable action within the host app.
public struct AppAction: Sendable {
    /// Action identifier (e.g., "add_to_cart").
    public let name: String
    /// Human-readable description for the LLM.
    public let description: String
    /// Describes accepted parameters as JSON Schema properties.
    public let parameters: [String: JSONSchema]
    /// Required parameter names.
    public let required: [String]

    public init(name: String, description: String,
                parameters: [String: JSONSchema] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
    }
}
