//
//  AIAgentMask.swift
//  AppAgent
//

import Foundation

/// Immutable configuration snapshot captured at session creation time.
///
/// Sessions hold this via `let agentMask`, decoupling them from live AIAgent mutations.
/// Also carries a thread-safe weak back-reference to the source AIAgent, so sessions
/// reach AIAgent exclusively through `agentMask.agent`.
///
/// When AIAgent config changes, newly created sessions automatically get a fresh snapshot
/// via `AIAgent.buildMask()`, which is called by `AISessionManager.createSession()`.
public struct AIAgentMask: Sendable {
    public let profile: AIAgentProfile
    public let toolPolicy: ToolCentral.ToolPolicy?
    public let toolCentral: ToolCentral

    /// Thread-safe weak back-reference to the source AIAgent.
    /// Stored as `let` (reference-type); internal state mutated via WeakLocked's lock.
    private let _agent: WeakLocked<AIAgent>

    /// The owning AIAgent (weak reference, thread-safe).
    public var agent: AIAgent? { _agent.wrappedValue }

    public init(
        profile: AIAgentProfile,
        toolPolicy: ToolCentral.ToolPolicy? = nil,
        toolCentral: ToolCentral,
        agent: AIAgent? = nil
    ) {
        self.profile = profile
        self.toolPolicy = toolPolicy
        self.toolCentral = toolCentral
        self._agent = WeakLocked(wrappedValue: agent)
    }
}
