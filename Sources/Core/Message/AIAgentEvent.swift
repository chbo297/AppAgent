//
//  AIAgentEvent.swift
//  AppAgent
//

import Foundation

/// Events emitted by AIAgentExecutor during execution, consumed by the UI layer.
public enum AIAgentEvent: Sendable {
    /// AIAgent run started (a new LLM request turn).
    case started(turn: Int)
    /// A chunk of streaming content from the assistant.
    case streamingContent(String)
    /// The assistant is requesting a tool call.
    case toolCallStarted(AIAgentMessage.ToolCall)
    /// A tool finished executing successfully.
    case toolCallCompleted(toolCallId: String, result: Tool.Output)
    /// A tool execution failed with an error.
    case toolCallFailed(toolCallId: String, name: String, error: Error)
    /// The entire agent run completed successfully.
    case completed(AIAgentFinish)
    /// The agent run failed with an error.
    case error(Error)
    /// Token usage update.
    case usage(inputTokens: Int, outputTokens: Int)
}

/// The final result of an agent run.
public struct AIAgentFinish: Sendable {
    /// The final assistant text response.
    public let text: String
    /// The full updated conversation history.
    public let updatedMessages: [AIAgentMessage]

    public init(text: String, updatedMessages: [AIAgentMessage]) {
        self.text = text
        self.updatedMessages = updatedMessages
    }
}
