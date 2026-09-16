//
//  AIAgentError.swift
//  AppAgent
//

import Foundation

/// Errors from the agent execution layer.
public enum AIAgentError: Error, LocalizedError, Sendable {
    case maxIterationsReached
    case toolNotFound(String)
    case toolExecutionFailed(toolName: String, underlying: Error)
    case sessionNotFound(String)
    case cancelled
    case sessionReleased
    case toolExecutionDenied(String)
    case toolLoopDetected(String)
    case toolExecutionTimedOut(toolName: String)
    case concurrencyLimitReached(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .maxIterationsReached:
            return "AIAgent loop exceeded maximum iterations"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .toolExecutionFailed(let name, let error):
            return "Tool '\(name)' failed: \(error.localizedDescription)"
        case .sessionNotFound(let id):
            return "AISession not found: \(id)"
        case .cancelled:
            return "Operation cancelled"
        case .sessionReleased:
            return "AISession was released during execution"
        case .toolExecutionDenied(let name):
            return "User denied execution of tool '\(name)'"
        case .toolLoopDetected(let name):
            return "Tool loop detected: '\(name)' called repeatedly with identical arguments"
        case .toolExecutionTimedOut(let name):
            return "Tool '\(name)' execution timed out"
        case .concurrencyLimitReached(let limit):
            return "已达并行上限(\(limit))，请先暂停其他任务再重试。"
        }
    }
}

/// Errors from the model provider layer.
public enum ModelError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        case .providerError(let msg):
            return "Provider error: \(msg)"
        }
    }
}
