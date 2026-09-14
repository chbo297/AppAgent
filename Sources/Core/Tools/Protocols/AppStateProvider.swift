//
//  AppStateProvider.swift
//  AppAgent
//

import Foundation

/// Protocol for host apps to expose current app state to the agent.
///
/// Returns key-value pairs describing the current state (e.g., current page,
/// login status, network connectivity, active user, etc.).
public protocol AppStateProvider: Sendable {
    func currentState() async -> [String: String]
}
