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
        The card always lets the user type their own answer, so do not add an "Other" choice. \
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
    /// 没有超时：用户不答就一直等，直到作答、跳过或会话被取消。
    public let waitsForUser = true

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let question = arguments["question"]?.stringValue else {
            return .error("Missing required parameter: question")
        }

        let choices: [String] = arguments["choices"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        // 和工具授权走同一条链路：AppAgent 面板在对话列表里渲染同一种卡片，
        // 宿主不必实现任何异步管道。
        let outcome = await session.requestDecision(.clarification(question: question,
                                                                  choices: choices))
        switch outcome {
        case .answer(let answer?):
            return .text(answer)
        case .answer(nil), .deny:
            return .text(Self.noAnswer)
        case .allowOnce, .allowForSession, .allowAlways:
            // 澄清类不该收到授权语义；当作没回答，别让模型以为拿到了内容。
            return .text(Self.noAnswer)
        }
    }

    /// 用户点「跳过」走这里：告诉模型怎么继续，而不是原地再问一遍。
    static let noAnswer = """
        User did not answer (skipped). \
        Continue with the most reasonable option and tell the user which one you chose; \
        if no safe default exists, stop and explain what you need.
        """
}
