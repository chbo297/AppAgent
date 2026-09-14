//
//  AppNavigationProvider.swift
//  AppAgent
//

import Foundation

/// Protocol for host apps to support in-app navigation via the agent.
///
/// The host app implements this to expose navigable routes (pages/screens)
/// that the agent can direct the user to.
public protocol AppNavigationProvider: Sendable {
    /// List all navigable routes (so the LLM knows what's available).
    func availableRoutes() async -> [AppRoute]
    /// Navigate to a specific route.
    func navigate(to route: String, parameters: [String: String]) async throws
}

/// Describes a navigable route within the host app.
public struct AppRoute: Sendable {
    /// Route identifier (e.g., "settings", "profile", "order_detail").
    public let name: String
    /// Human-readable description for the LLM.
    public let description: String
    /// Names of accepted parameters (e.g., ["order_id"]).
    public let parameters: [String]

    public init(name: String, description: String, parameters: [String] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
