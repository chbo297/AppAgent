//
//  Logger.swift
//  AppAgent
//

import Foundation

/// Log level for AppAgent debug logging.
public enum AppAgentLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: AppAgentLogLevel, rhs: AppAgentLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }
}

/// Centralized logger for the AppAgent SDK.
///
/// All log lines are prefixed with `[AppAgent]` followed by the level and subsystem.
/// Logging is disabled by default. Enable via `Logger.isEnabled = true`.
///
/// Host apps can redirect logs by setting a custom handler:
/// ```swift
/// Logger.handler = { level, message in
///     myLogger.log(level: level, message: message)
/// }
/// ```
public enum Logger {

    /// Master switch. When false, no log statements execute. Default: false.
    public static var isEnabled: Bool = false

    /// Minimum log level. Messages below this level are suppressed. Default: .debug.
    public static var minimumLevel: AppAgentLogLevel = .debug

    /// Optional custom log handler. When set, replaces the default `print` output.
    /// The closure receives the log level and the fully-formatted message string
    /// (already including the `[AppAgent]` prefix).
    public static var handler: ((AppAgentLogLevel, String) -> Void)?

    /// Whether to redact sensitive information (API keys, tokens, etc.) from log output.
    /// Default: true.
    public static var redactSensitive: Bool = true

    /// Log a message.
    ///
    /// - Parameters:
    ///   - level: The severity level.
    ///   - subsystem: A short tag identifying the component (e.g., "AISession", "AIAgentExecutor", "Anthropic").
    ///   - message: The log message. Evaluated lazily via @autoclosure.
    public static func log(
        _ level: AppAgentLogLevel,
        subsystem: String,
        _ message: @autoclosure () -> String
    ) {
        guard isEnabled, level >= minimumLevel else { return }
        let raw = "[AppAgent] [\(level.label)] [\(subsystem)] \(message())"
        let formatted = redactSensitive ? redact(raw) : raw
        if let handler = handler {
            handler(level, formatted)
        } else {
            print(formatted)
        }
    }

    // MARK: - Redaction

    /// Regex patterns for detecting sensitive values in log output.
    private static let redactPatterns: [(regex: NSRegularExpression, groupIndex: Int)] = {
        // (pattern, capture group index for the sensitive part)
        // Group 0 = full match when no specific group needed
        let definitions: [(String, Int)] = [
            // API keys: sk-xxx, key-xxx, pat-xxx, ghp_xxx, etc.
            (#"(sk-|key-|pat-|ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_-]{8,}"#, 0),
            // Bearer tokens
            (#"(?i)(Bearer\s+)([A-Za-z0-9._-]{8,})"#, 2),
            // x-api-key / authorization header values
            (#"(?i)((?:x-api-key|authorization)[:\s]+)([^\s,\]\"]{8,})"#, 2),
        ]
        return definitions.compactMap { pattern, group in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, group)
        }
    }()

    /// Redact sensitive values from a log string.
    ///
    /// Values ≤ 8 characters are replaced with equal-length `*`.
    /// Values > 8 characters are replaced with `<*_N>` where N is the original length.
    private static func redact(_ input: String) -> String {
        var result = input

        for (regex, groupIndex) in redactPatterns {
            let fullRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: fullRange)

            // Replace from end to start to preserve offsets
            for match in matches.reversed() {
                let targetRange = match.range(at: groupIndex)
                guard targetRange.location != NSNotFound,
                      let swiftRange = Range(targetRange, in: result) else { continue }

                let original = String(result[swiftRange])
                let replacement: String
                if original.count <= 8 {
                    replacement = String(repeating: "*", count: original.count)
                } else {
                    replacement = "<*_\(original.count)>"
                }
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    // MARK: - Convenience

    public static func debug(_ subsystem: String, _ message: @autoclosure () -> String) {
        log(.debug, subsystem: subsystem, message())
    }

    public static func info(_ subsystem: String, _ message: @autoclosure () -> String) {
        log(.info, subsystem: subsystem, message())
    }

    public static func warning(_ subsystem: String, _ message: @autoclosure () -> String) {
        log(.warning, subsystem: subsystem, message())
    }

    public static func error(_ subsystem: String, _ message: @autoclosure () -> String) {
        log(.error, subsystem: subsystem, message())
    }
}
