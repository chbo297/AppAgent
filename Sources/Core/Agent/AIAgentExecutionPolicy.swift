//
//  AIAgentExecutionPolicy.swift
//  AppAgent
//

import Foundation

/// Execution and safety settings captured by a session at creation time.
///
/// `AIAgentProfile` remains mutable so hosts can change defaults for future
/// sessions. A session receives a value copy of this policy and keeps using it
/// for its entire lifetime.
public struct AIAgentExecutionPolicy: Sendable, Codable {
    public static let defaultMaxIterations = 70
    public static let defaultToolTimeout: TimeInterval = 60
    public static let defaultToolOutputMaxBytes = 8192
    public static let defaultAutoPersist = true
    public static let defaultToolMutationPolicy: Tool.MutationPolicy = .allowed

    public static let `default` = AIAgentExecutionPolicy()

    /// Shared budget for model requests, tool follow-ups, retries, and fallbacks.
    public let maxIterations: Int

    /// Maximum duration of one tool execution.
    public let toolTimeout: TimeInterval

    /// Agent-wide UTF-8 byte cap for one tool result.
    public let toolOutputMaxBytes: Int

    /// Whether completed runs are automatically persisted.
    public let autoPersist: Bool

    /// Runtime mutation boundary enforced before a tool executes.
    public let toolMutationPolicy: Tool.MutationPolicy

    public init(
        maxIterations: Int = AIAgentExecutionPolicy.defaultMaxIterations,
        toolTimeout: TimeInterval = AIAgentExecutionPolicy.defaultToolTimeout,
        toolOutputMaxBytes: Int = AIAgentExecutionPolicy.defaultToolOutputMaxBytes,
        autoPersist: Bool = AIAgentExecutionPolicy.defaultAutoPersist,
        toolMutationPolicy: Tool.MutationPolicy = AIAgentExecutionPolicy.defaultToolMutationPolicy
    ) {
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.toolOutputMaxBytes = toolOutputMaxBytes
        self.autoPersist = autoPersist
        self.toolMutationPolicy = toolMutationPolicy
    }
}
