//
//  ToolLoopDetector.swift
//  AppAgent
//

import Foundation

/// Detects when the model gets stuck in a tool-calling loop.
///
/// Maintains a sliding window of recent tool calls and checks for:
/// 1. **Exact repeat**: same (name, argsHash) called consecutively
/// 2. **Ping-pong**: alternating A-B-A-B pattern
///
/// Reference: openclaw `tool-loop-detection.ts`
public struct ToolLoopDetector: Sendable {

    /// Detection result.
    public enum Result: Sendable {
        /// No loop detected.
        case ok
        /// Warning — inject a message telling the model it's repeating.
        case warning(message: String)
        /// Critical — terminate execution.
        case critical(message: String)
    }

    /// Configuration for detection thresholds.
    public struct Config: Sendable {
        /// Maximum history entries to track. Default: 20.
        public var historySize: Int
        /// Consecutive identical calls to trigger a warning. Default: 3.
        public var repeatThreshold: Int
        /// Consecutive identical calls to trigger termination. Default: 5.
        public var criticalThreshold: Int
        /// A-B-A-B alternating pairs to trigger warning. Default: 4.
        public var pingPongThreshold: Int

        public init(
            historySize: Int = 20,
            repeatThreshold: Int = 3,
            criticalThreshold: Int = 5,
            pingPongThreshold: Int = 4
        ) {
            self.historySize = historySize
            self.repeatThreshold = repeatThreshold
            self.criticalThreshold = criticalThreshold
            self.pingPongThreshold = pingPongThreshold
        }
    }

    private struct Record: Sendable {
        let name: String
        let argsHash: Int
    }

    private var history: [Record] = []
    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Record a tool call and check for loop patterns.
    ///
    /// - Parameters:
    ///   - name: The tool name being called.
    ///   - arguments: The arguments passed to the tool.
    /// - Returns: Detection result (ok, warning, or critical).
    public mutating func record(name: String, arguments: [String: JSONValue]) -> Result {
        let hash = stableHash(arguments)
        let record = Record(name: name, argsHash: hash)

        history.append(record)
        if history.count > config.historySize {
            history.removeFirst(history.count - config.historySize)
        }

        // Check exact repeat pattern
        if let result = detectRepeat() {
            return result
        }

        // Check ping-pong pattern
        if let result = detectPingPong() {
            return result
        }

        return .ok
    }

    /// Reset the detector (e.g., between sessions or after a warning injection).
    public mutating func reset() {
        history.removeAll()
    }

    // MARK: - Detectors

    /// Detect consecutive identical tool calls (same name + args).
    private func detectRepeat() -> Result? {
        guard let last = history.last else { return nil }

        var streak = 0
        for record in history.reversed() {
            if record.name == last.name && record.argsHash == last.argsHash {
                streak += 1
            } else {
                break
            }
        }

        if streak >= config.criticalThreshold {
            return .critical(message:
                "Tool '\(last.name)' called \(streak) times with identical arguments. "
                + "Stopping execution to prevent infinite loop."
            )
        }

        if streak >= config.repeatThreshold {
            return .warning(message:
                "WARNING: You have called '\(last.name)' \(streak) times in a row with the same arguments. "
                + "This appears to be a loop. Please try a different approach or tool."
            )
        }

        return nil
    }

    /// Detect A-B-A-B ping-pong pattern between two tools.
    private func detectPingPong() -> Result? {
        guard history.count >= config.pingPongThreshold * 2 else { return nil }

        let tail = Array(history.suffix(config.pingPongThreshold * 2))

        // Check if alternating: A B A B A B ...
        guard tail.count >= 4 else { return nil }
        let a = tail[tail.count - 2]
        let b = tail[tail.count - 1]

        // a and b must be different
        guard a.name != b.name || a.argsHash != b.argsHash else { return nil }

        var pairs = 0
        var i = tail.count - 1
        while i >= 1 {
            let current = tail[i]
            let prev = tail[i - 1]
            if (current.name == b.name && current.argsHash == b.argsHash &&
                prev.name == a.name && prev.argsHash == a.argsHash) ||
               (current.name == a.name && current.argsHash == a.argsHash &&
                prev.name == b.name && prev.argsHash == b.argsHash) {
                pairs += 1
                i -= 2
            } else {
                break
            }
        }

        if pairs >= config.pingPongThreshold {
            return .warning(message:
                "WARNING: Detected ping-pong pattern between '\(a.name)' and '\(b.name)' "
                + "(\(pairs) alternating pairs). Please try a different approach."
            )
        }

        return nil
    }

    // MARK: - Hashing

    /// Produce a stable hash of JSONValue arguments for comparison.
    private func stableHash(_ arguments: [String: JSONValue]) -> Int {
        // Sort keys for deterministic hashing
        var hasher = Hasher()
        for key in arguments.keys.sorted() {
            hasher.combine(key)
            hasher.combine(String(describing: arguments[key]!))
        }
        return hasher.finalize()
    }
}
