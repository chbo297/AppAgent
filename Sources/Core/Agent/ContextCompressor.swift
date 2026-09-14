//
//  ContextCompressor.swift
//  AppAgent
//

import Foundation

/// Protocol for compressing message context when it approaches the model's context window limit.
///
/// Reference: hermes-agent `ContextCompressor`.
public protocol ContextCompressor: Sendable {
    /// Estimate the token count of a message list.
    func estimateTokens(messages: [AIAgentMessage]) -> Int

    /// Compress messages to fit within a target token count.
    ///
    /// Implementations should preserve the first few and last few messages (head + tail),
    /// and summarize or truncate the middle portion.
    func compress(messages: [AIAgentMessage], targetTokens: Int) async -> [AIAgentMessage]
}
