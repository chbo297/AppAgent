//
//  AIAgentDelegate.swift
//  AppAgent
//

import Foundation

/// Delegate protocol for agent lifecycle callbacks.
public protocol AIAgentDelegate: AnyObject, Sendable {
    /// Called when a new session is created.
    func aiAgent(_ aiAgent: AIAgent, didCreateSession session: AISession)

    /// Called when a session is deleted.
    func aiAgent(_ aiAgent: AIAgent, didDeleteSession sessionId: String)

    /// Called when a session completes an agent run.
    func aiAgent(_ aiAgent: AIAgent, session: AISession, didCompleteRun result: AIAgentFinish)

    /// Called when a session encounters an error.
    func aiAgent(_ aiAgent: AIAgent, session: AISession, didEncounterError error: Error)

    /// Called when a tool with `sensitive` or `dangerous` safety level is about to execute.
    /// Return `true` to allow execution, `false` to reject (tool returns an error to the LLM).
    func aiAgent(_ aiAgent: AIAgent, session: AISession, shouldExecuteTool name: String,
               safetyLevel: Tool.SafetyLevel, arguments: [String: JSONValue]) async -> Bool

    /// Called when the ClarifyTool needs user input.
    /// Return the user's answer string.
    func aiAgent(_ aiAgent: AIAgent, session: AISession,
               needsClarification question: String, choices: [String]?) async -> String?
}

// Default no-op implementations.
extension AIAgentDelegate {
    public func aiAgent(_ aiAgent: AIAgent, didCreateSession session: AISession) {}
    public func aiAgent(_ aiAgent: AIAgent, didDeleteSession sessionId: String) {}
    public func aiAgent(_ aiAgent: AIAgent, session: AISession, didCompleteRun result: AIAgentFinish) {}
    public func aiAgent(_ aiAgent: AIAgent, session: AISession, didEncounterError error: Error) {}

    /// Default: allow all tool executions.
    public func aiAgent(_ aiAgent: AIAgent, session: AISession, shouldExecuteTool name: String,
                      safetyLevel: Tool.SafetyLevel, arguments: [String: JSONValue]) async -> Bool {
        true
    }

    /// Default: return nil (tool reports no answer to LLM).
    public func aiAgent(_ aiAgent: AIAgent, session: AISession,
                      needsClarification question: String, choices: [String]?) async -> String? {
        nil
    }
}
