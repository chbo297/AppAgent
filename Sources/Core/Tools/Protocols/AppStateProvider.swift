//
//  AppStateProvider.swift
//  AppAgent
//

import Foundation

/// Protocol for host apps to expose current app state to the agent.
///
/// Returns key-value pairs describing the current state (e.g., current page,
/// login status, network connectivity, active user, etc.).
/// This is a host-only contract: do not include AppAgent UI, sessions, settings or
/// diagnostics. Opaque host strings cannot be ownership-filtered by the SDK.
/// SDK debugging belongs in the explicitly authorized inspection tools.
public protocol AppStateProvider: Sendable {
    func currentState() async -> [String: String]
}
