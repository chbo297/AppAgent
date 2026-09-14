//
//  ErrorClassifier.swift
//  AppAgent
//

import Foundation

/// Why an API call failed — determines recovery strategy.
/// Reference: hermes-agent `error_classifier.py` FailoverReason.
public enum FailoverReason: String, Sendable {
    /// 401/403 — authentication failed, not retryable
    case authError = "auth_error"
    /// 402 — billing/quota exhausted, not retryable
    case billing = "billing"
    /// 429 — rate limited, retryable with backoff
    case rateLimited = "rate_limited"
    /// 503/529 — provider overloaded, retryable with longer backoff
    case overloaded = "overloaded"
    /// 500/502 — server error, retryable
    case serverError = "server_error"
    /// 400 + context patterns, or 413 — context too large, needs compression
    case contextOverflow = "context_overflow"
    /// 404 — model not found, needs fallback
    case modelNotFound = "model_not_found"
    /// 400 other — format/request error, not retryable
    case formatError = "format_error"
    /// Network timeout — retryable
    case timeout = "timeout"
    /// Unclassifiable — retryable with backoff
    case unknown = "unknown"
}

/// Structured classification of an API error with recovery hints.
public struct ClassifiedError: Sendable {
    public let reason: FailoverReason
    public let statusCode: Int?
    public let message: String
    /// Whether the error can be retried (with backoff).
    public let retryable: Bool
    /// Whether context compression should be attempted.
    public let shouldCompress: Bool
    /// Whether fallback to another model should be attempted.
    public let shouldFallback: Bool
}

/// Classifies API errors into structured recovery recommendations.
///
/// Priority-ordered pipeline:
/// 1. HTTP status code + message-aware refinement
/// 2. Message pattern matching
/// 3. Transport error heuristics
/// 4. Fallback: unknown (retryable)
///
/// Reference: hermes-agent `error_classifier.py`
public enum ErrorClassifier {

    // MARK: - Public API

    /// Classify an error into a structured recovery recommendation.
    public static func classify(_ error: Error) -> ClassifiedError {
        // ModelError.httpError — the primary classification target
        if let modelError = error as? ModelError {
            return classifyModelError(modelError)
        }

        // URLError — network/transport issues
        if let urlError = error as? URLError {
            return ClassifiedError(
                reason: .timeout,
                statusCode: nil,
                message: urlError.localizedDescription,
                retryable: true,
                shouldCompress: false,
                shouldFallback: false
            )
        }

        // AIAgentError — internal errors (not retryable)
        if let agentError = error as? AIAgentError {
            return ClassifiedError(
                reason: .unknown,
                statusCode: nil,
                message: agentError.errorDescription ?? String(describing: agentError),
                retryable: false,
                shouldCompress: false,
                shouldFallback: false
            )
        }

        // Fallback: unknown, retryable
        return ClassifiedError(
            reason: .unknown,
            statusCode: nil,
            message: error.localizedDescription,
            retryable: true,
            shouldCompress: false,
            shouldFallback: false
        )
    }

    // MARK: - Private

    private static func classifyModelError(_ error: ModelError) -> ClassifiedError {
        switch error {
        case .httpError(let statusCode, let body):
            return classifyHTTPError(statusCode: statusCode, body: body)
        case .invalidURL, .invalidResponse, .decodingError:
            return ClassifiedError(
                reason: .formatError,
                statusCode: nil,
                message: error.errorDescription ?? String(describing: error),
                retryable: false,
                shouldCompress: false,
                shouldFallback: false
            )
        case .providerError(let msg):
            let lowered = msg.lowercased()
            if matchesAny(lowered, patterns: contextOverflowPatterns) {
                return ClassifiedError(reason: .contextOverflow, statusCode: nil, message: msg,
                                       retryable: true, shouldCompress: true, shouldFallback: false)
            }
            return ClassifiedError(reason: .unknown, statusCode: nil, message: msg,
                                   retryable: true, shouldCompress: false, shouldFallback: false)
        }
    }

    private static func classifyHTTPError(statusCode: Int, body: String) -> ClassifiedError {
        let loweredBody = body.lowercased()

        switch statusCode {
        case 401, 403:
            return ClassifiedError(reason: .authError, statusCode: statusCode, message: body,
                                   retryable: false, shouldCompress: false, shouldFallback: true)

        case 402:
            return ClassifiedError(reason: .billing, statusCode: statusCode, message: body,
                                   retryable: false, shouldCompress: false, shouldFallback: true)

        case 404:
            return ClassifiedError(reason: .modelNotFound, statusCode: statusCode, message: body,
                                   retryable: false, shouldCompress: false, shouldFallback: true)

        case 413:
            return ClassifiedError(reason: .contextOverflow, statusCode: statusCode, message: body,
                                   retryable: true, shouldCompress: true, shouldFallback: false)

        case 429:
            return ClassifiedError(reason: .rateLimited, statusCode: statusCode, message: body,
                                   retryable: true, shouldCompress: false, shouldFallback: true)

        case 400:
            // Context overflow patterns in 400 body
            if matchesAny(loweredBody, patterns: contextOverflowPatterns) {
                return ClassifiedError(reason: .contextOverflow, statusCode: 400, message: body,
                                       retryable: true, shouldCompress: true, shouldFallback: false)
            }
            // Model not found as 400 (some providers)
            if matchesAny(loweredBody, patterns: modelNotFoundPatterns) {
                return ClassifiedError(reason: .modelNotFound, statusCode: 400, message: body,
                                       retryable: false, shouldCompress: false, shouldFallback: true)
            }
            // Rate limit as 400 (some providers)
            if matchesAny(loweredBody, patterns: rateLimitPatterns) {
                return ClassifiedError(reason: .rateLimited, statusCode: 400, message: body,
                                       retryable: true, shouldCompress: false, shouldFallback: true)
            }
            return ClassifiedError(reason: .formatError, statusCode: 400, message: body,
                                   retryable: false, shouldCompress: false, shouldFallback: true)

        case 500, 502:
            return ClassifiedError(reason: .serverError, statusCode: statusCode, message: body,
                                   retryable: true, shouldCompress: false, shouldFallback: false)

        case 503, 529:
            return ClassifiedError(reason: .overloaded, statusCode: statusCode, message: body,
                                   retryable: true, shouldCompress: false, shouldFallback: false)

        default:
            if (400..<500).contains(statusCode) {
                return ClassifiedError(reason: .formatError, statusCode: statusCode, message: body,
                                       retryable: false, shouldCompress: false, shouldFallback: true)
            }
            if (500..<600).contains(statusCode) {
                return ClassifiedError(reason: .serverError, statusCode: statusCode, message: body,
                                       retryable: true, shouldCompress: false, shouldFallback: false)
            }
            return ClassifiedError(reason: .unknown, statusCode: statusCode, message: body,
                                   retryable: true, shouldCompress: false, shouldFallback: false)
        }
    }

    // MARK: - Pattern Matching

    private static func matchesAny(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }

    /// Patterns indicating context/token limit exceeded.
    private static let contextOverflowPatterns = [
        "context length", "context size", "maximum context",
        "token limit", "too many tokens", "reduce the length",
        "exceeds the limit", "context window", "prompt is too long",
        "prompt exceeds max length", "max_tokens",
        "maximum number of tokens",
    ]

    /// Patterns indicating rate limiting.
    private static let rateLimitPatterns = [
        "rate limit", "rate_limit", "too many requests",
        "throttled", "requests per minute", "tokens per minute",
    ]

    /// Patterns indicating model not found.
    private static let modelNotFoundPatterns = [
        "model not found", "model_not_found", "invalid model",
        "does not exist", "unknown model", "unsupported model",
    ]
}
