//
//  ClarifyTool.swift
//  AppAgent
//

import Foundation

/// Tool that allows the agent to ask the user a clarifying question.
///
/// Execution pauses until the host app provides an answer via the AIAgentDelegate callback.
/// Reference: hermes-agent `clarify` tool.
public struct ClarifyTool: ToolProtocol {
    public let name = "clarify"
    public let description = """
        Ask the user a question when you need clarification, feedback, or a decision before proceeding. \
        Supports two modes: (1) Multiple choice — provide up to 4 choices. \
        (2) Open-ended — omit choices entirely. \
        Use this when the task is ambiguous, you want post-task feedback, or a decision has meaningful trade-offs.
        """
    public let parameters = Tool.Schema(
        properties: [
            "question": .string(description: "The question to present to the user."),
            "choices": .array(
                description: "Up to 4 answer choices. Omit for an open-ended question.",
                items: .string(),
                maxItems: 4
            )
        ],
        required: ["question"]
    )
    public let group: String = "core"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let question = arguments["question"]?.stringValue else {
            return .error("Missing required parameter: question")
        }

        let choices: [String]? = arguments["choices"]?.arrayValue?.compactMap { $0.stringValue }

        // Notify UI state
        session.uiState.set("pendingClarification", value: [
            "question": question,
            "choices": choices as Any
        ])

        // Delegate to host app
        guard let agent = session.agentMask?.agent, let delegate = agent.delegate else {
            session.uiState.remove("pendingClarification")
            return .error("No delegate configured to handle clarification requests")
        }

        let answer = await delegate.aiAgent(agent, session: session,
                                          needsClarification: question, choices: choices)

        session.uiState.remove("pendingClarification")

        if let answer {
            return .text(answer)
        } else {
            return .text("User did not provide an answer.")
        }
    }
}
