//
//  DelegateTaskTool.swift
//  AppAgent
//

import Foundation

/// Tool for spawning a sub-session to handle a subtask independently.
///
/// Creates a temporary session, sends the goal as a user message, waits for completion,
/// and returns the final response. The sub-session is not persisted.
///
/// Reference: hermes-agent `delegate_task` tool.
public struct DelegateTaskTool: ToolProtocol {
    public let name = "delegate_task"
    public let description = """
        Spawn a sub-agent to work on a task in an isolated context. \
        The sub-agent gets its own conversation and toolset. Only the final response is returned. \
        Use for: reasoning-heavy subtasks, tasks that would flood your context, parallel research. \
        Pass all relevant info via 'context' — the sub-agent knows nothing about your conversation.
        """
    public let parameters = Tool.Schema(
        properties: [
            "goal": .string(description: "What the sub-agent should accomplish."),
            "context": .string(description: "Background information: file paths, constraints, etc.")
        ],
        required: ["goal"]
    )
    public let group: String = "core"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    public init() {}

    /// Maximum delegation depth to prevent unbounded recursion.
    private static let maxDepth = 2

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let goal = arguments["goal"]?.stringValue, !goal.isEmpty else {
            return .error("Missing required parameter: goal")
        }

        // Check depth limit
        guard session.delegationDepth < Self.maxDepth else {
            return .error("Maximum delegation depth (\(Self.maxDepth)) reached. Cannot create sub-agent.")
        }

        guard session.agentMask?.agent != nil else {
            return .error("Cannot delegate: no agent available.")
        }

        let context = arguments["context"]?.stringValue ?? ""

        // Build the message for the sub-session
        var userMessage = goal
        if !context.isEmpty {
            userMessage = "Context:\n\(context)\n\nTask:\n\(goal)"
        }

        // Create a temporary sub-session (not persisted), with incremented depth.
        // Use empty tools — reinstallTools() will create independent instances.
        // Inherit the parent session's mask so the sub-session operates under the same frozen config.
        let subAgentId = session.agentMask?.agent?.id ?? "sub"
        let subSessionId = "\(subAgentId)_sub_\(UUID().uuidString.prefix(8).lowercased())"
        let subSession = AISession(
            id: subSessionId,
            title: "Subtask: \(goal.prefix(50))",
            agentMask: session.agentMask,
            installedTools: [:],
            delegationDepth: session.delegationDepth + 1
        )

        // Exclude delegate_task from sub-session to prevent recursion
        subSession.toolPolicy = ToolCentral.ToolPolicy(excludedNames: ["delegate_task"])
        await subSession.reinstallTools()

        // Send the message and collect the final response
        let stream = subSession.sendMessage(userMessage)
        var finalText = ""

        for await event in stream {
            switch event {
            case .completed(let result):
                finalText = result.text
            case .error(let error):
                return .error("Sub-agent error: \(error.localizedDescription)")
            default:
                break
            }
        }

        if finalText.isEmpty {
            return .error("Sub-agent returned no response.")
        }

        return .json(.object([
            "result": .string(finalText),
            "goal": .string(goal)
        ]))
    }
}
