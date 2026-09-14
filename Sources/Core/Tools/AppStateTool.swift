//
//  AppStateTool.swift
//  AppAgent
//

import Foundation

/// Tool that exposes the host app's current state to the agent.
///
/// Thin wrapper over `AppStateProvider`.
public struct AppStateTool: ToolProtocol {
    public let name = "app_state"
    public let description = """
        Get the current state of the app (current page, login status, network connectivity, etc.).
        """
    public let parameters = Tool.Schema(properties: [:], required: [])
    public let group: String = "custom"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: any AppStateProvider

    public init(provider: any AppStateProvider) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let state = await provider.currentState()
        let jsonObj: [String: JSONValue] = state.mapValues { .string($0) }
        return .json(.object(jsonObj))
    }
}
