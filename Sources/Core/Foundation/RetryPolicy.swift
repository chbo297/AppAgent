//
//  RetryPolicy.swift
//  AppAgent
//

import Foundation

/// Configuration for automatic retry with exponential backoff and jitter.
///
/// Used by `AIAgentExecutor` to retry transient API errors (rate limits, server errors, etc.).
/// Reference: hermes-agent `retry_utils.py`.
public struct RetryPolicy: Sendable {
    /// Maximum number of retry attempts. Default: 3.
    public var maxRetries: Int
    /// Base delay in seconds for the first retry. Default: 1.0.
    public var baseDelay: TimeInterval
    /// Maximum delay cap in seconds. Default: 30.0.
    public var maxDelay: TimeInterval
    /// Jitter factor (±percentage). Default: 0.25 (±25%).
    public var jitterFactor: Double

    public init(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        jitterFactor: Double = 0.25
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFactor = jitterFactor
    }

    /// Calculate the delay for a given attempt number (0-based).
    ///
    /// Uses exponential backoff: `baseDelay * 2^attempt`, capped at `maxDelay`,
    /// with random jitter applied.
    public func delay(for attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt))
        let capped = min(exponential, maxDelay)
        let jitter = capped * Double.random(in: -jitterFactor...jitterFactor)
        return max(0, capped + jitter)
    }
}
