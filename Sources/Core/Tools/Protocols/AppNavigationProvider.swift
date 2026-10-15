//
//  AppNavigationProvider.swift
//  AppAgent
//

import Foundation

/// Protocol for host apps to support in-app navigation via the agent.
///
/// The host app implements this to expose navigable routes (pages/screens)
/// that the agent can direct the user to.
/// Routes belong to the host, not AppAgent's settings/debug/chat UI. The provider
/// is responsible for this boundary; route strings are not an ownership proof.
public protocol AppNavigationProvider: Sendable {
    /// List all navigable routes (so the LLM knows what's available).
    func availableRoutes() async -> [AppRoute]

    /// Submit a navigation request to a specific route.
    ///
    /// A normal return means the host accepted/submitted the request. It does not
    /// confirm that the destination is visible or that navigation has completed.
    /// Throw when the request cannot be accepted/submitted. Once submitted, do not
    /// throw solely because presentation is pending or its completion is unknown;
    /// reporting failure at that point can cause a duplicate request on retry.
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
