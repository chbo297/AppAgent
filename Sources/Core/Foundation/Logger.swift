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

    /// 进程级日志配置。
    ///
    /// 这四项是真正的跨线程共享可变状态：宿主在启动时写，`log` 在任何线程读。Swift 6 下裸
    /// `static var` 直接是错误（`#MutableGlobalVariable`），而且原来的写法确实没有任何保护。
    /// 统一收进一把锁，并且**一次取一份快照**——`log` 原来要分别读 4 个字段，既是 4 次加锁，
    /// 也可能读到宿主改了一半的配置（比如换 handler 的同时关掉开关）。
    private final class Configuration: @unchecked Sendable {
        struct Snapshot {
            var isEnabled: Bool
            var minimumLevel: AppAgentLogLevel
            var handler: (@Sendable (AppAgentLogLevel, String) -> Void)?
            var redactSensitive: Bool
        }

        private let lock = UnfairLock()
        private var value = Snapshot(
            isEnabled: false,
            minimumLevel: .debug,
            handler: nil,
            redactSensitive: true
        )

        var snapshot: Snapshot { lock.withLock { value } }

        func mutate(_ body: (inout Snapshot) -> Void) {
            lock.withLock { body(&value) }
        }
    }

    private static let configuration = Configuration()

    /// Master switch. When false, no log statements execute. Default: false.
    public static var isEnabled: Bool {
        get { configuration.snapshot.isEnabled }
        set { configuration.mutate { $0.isEnabled = newValue } }
    }

    /// Minimum log level. Messages below this level are suppressed. Default: .debug.
    public static var minimumLevel: AppAgentLogLevel {
        get { configuration.snapshot.minimumLevel }
        set { configuration.mutate { $0.minimumLevel = newValue } }
    }

    /// Optional custom log handler. When set, replaces the default `print` output.
    /// The closure receives the log level and the fully-formatted message string
    /// (already including the `[AppAgent]` prefix).
    ///
    /// 必须是 `@Sendable`：它会在任何产生日志的线程上被调用，这一点本来就成立，现在只是让类型
    /// 把它说出来。
    public static var handler: (@Sendable (AppAgentLogLevel, String) -> Void)? {
        get { configuration.snapshot.handler }
        set { configuration.mutate { $0.handler = newValue } }
    }

    /// Whether to redact sensitive information (API keys, tokens, etc.) from log output.
    /// Default: true.
    /// Diagnostic payloads always redact, regardless of this setting.
    public static var redactSensitive: Bool {
        get { configuration.snapshot.redactSensitive }
        set { configuration.mutate { $0.redactSensitive = newValue } }
    }

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
        // 一次快照：整行日志用同一份配置，不会出现「按旧开关放行、按新 handler 投递」。
        let config = configuration.snapshot
        guard config.isEnabled, level >= config.minimumLevel else { return }
        let raw = "[AppAgent] [\(level.label)] [\(subsystem)] \(message())"
        let formatted = config.redactSensitive ? redact(raw) : raw
        if let handler = config.handler {
            handler(level, formatted)
        } else {
            print(formatted)
        }
    }

    /// 完整诊断载荷沿用现有 handler；强制脱敏后按 Character 分块，不截断正文。
    /// `bytes` 是原始 UTF-8 字节数，逐块 JSONDecode `payload=` 后按 part 拼接可还原脱敏正文。
    internal static func diagnosticPayload(
        _ subsystem: String,
        metadata: String,
        payload: String,
        secrets: [String] = []
    ) {
        let config = configuration.snapshot
        guard config.isEnabled, AppAgentLogLevel.debug >= config.minimumLevel else {
            return
        }

        let variants = diagnosticSecretVariants(secrets)
        let safePayload = redact(payload, secrets: variants)
        let safeMetadata = diagnosticSingleLine(redact(metadata, secrets: variants))
        let safeSubsystem = diagnosticSingleLine(redact(subsystem, secrets: variants))
        let bytes = payload.utf8.count
        let partCount = max(1, (safePayload.count + 2047) / 2048)
        let encoder = JSONEncoder()
        var start = safePayload.startIndex

        for part in 1...partCount {
            let end = safePayload.index(start, offsetBy: 2048, limitedBy: safePayload.endIndex)
                ?? safePayload.endIndex
            guard let data = try? encoder.encode(String(safePayload[start..<end])) else {
                return
            }
            let encoded = diagnosticSingleLine(String(decoding: data, as: UTF8.self))
            let line = "[AppAgent] [DEBUG] [\(safeSubsystem)] \(safeMetadata)"
                + " bytes=\(bytes) part=\(part)/\(partCount) payload=\(encoded)"
            if let handler = config.handler {
                handler(.debug, line)
            } else {
                print(line)
            }
            start = end
        }
    }

    /// 错误摘要也可复用强制脱敏；运行时凭据只参与匹配，不保存或打印。
    internal static func redactDiagnostic(_ input: String, secrets: [String] = []) -> String {
        redact(input, secrets: diagnosticSecretVariants(secrets))
    }

    private static func diagnosticSecretVariants(_ secrets: [String]) -> [String] {
        var variants = Set<String>()
        let encoder = JSONEncoder()
        let formats: [JSONEncoder.OutputFormatting] = [[], .withoutEscapingSlashes]
        for secret in secrets where !secret.isEmpty {
            variants.insert(secret)
            for formatting in formats {
                encoder.outputFormatting = formatting
                if let data = try? encoder.encode(secret) {
                    let encoded = String(decoding: data, as: UTF8.self)
                    variants.insert(String(encoded.dropFirst().dropLast()))
                }
            }
        }

        // 先匹配长值，避免重叠的短凭据破坏完整匹配。
        return variants.sorted {
            $0.count > $1.count
        }
    }

    private static func diagnosticSingleLine(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - Redaction

    /// Regex patterns for detecting sensitive values in log output.
    private static let redactPatterns: [(regex: NSRegularExpression, groupIndex: Int)] = {
        // (pattern, capture group index for the sensitive part)
        // Group 0 = full match when no specific group needed
        let credential = #"(?:api[_-]?key|x-api-key|(?:proxy-)?authorization|x-zt-authorization|(?:access[_-]?|refresh[_-]?|id[_-]?)?token|password|passwd|secret|client[_-]?secret|comate_custom_header)"#
        let definitions: [(String, Int)] = [
            // JSON 字符串值：包括短凭据、空格与转义引号，不吞掉相邻业务字段。
            (#"(?i)""# + credential + #""\s*:\s*"((?:\\.|[^"\\])*)""#, 1),
            // 非字符串凭据值（例如数字密码）。
            (#"(?i)""# + credential + #""\s*:\s*((?:-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null))(?=\s*[,}\]])"#, 1),
            // API keys: sk-xxx, key-xxx, pat-xxx, ghp_xxx, etc.
            (#"(sk-|key-|pat-|ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_-]{8,}"#, 0),
            // Bearer / Basic 凭据及普通 header、key=value 形式。
            (#"(?i)\b(?:Bearer|Basic)\s+([A-Za-z0-9._~+/=-]+)"#, 1),
            (#"(?i)(?<![\w-])"# + credential + #"\s*[:=]\s*(?:Bearer\s+|Basic\s+)?([^\s,\]\[}"\\]+)"#, 1),
            (#"(?i)\b(?:x-api-key|authorization)\s+([^\s,\]\[}"\\]+)"#, 1),
        ]
        return definitions.compactMap { pattern, group in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return (regex, group)
        }
    }()

    private static let jsonStringPattern = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)

    /// Redact sensitive values from a log string.
    ///
    /// Values ≤ 8 characters are replaced with equal-length `*`.
    /// Values > 8 characters are replaced with `<*_N>` where N is the original length.
    private static func redact(_ input: String, secrets: [String] = [], depth: Int = 0) -> String {
        var result = input

        // 先完整遮盖已知值，避免通用规则只改写其中一段后无法再匹配整个凭据。
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "<redacted>", options: .literal)
        }

        for (regex, groupIndex) in redactPatterns {
            let fullRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: fullRange)

            // Replace from end to start to preserve offsets
            for match in matches.reversed() {
                let targetRange = match.range(at: groupIndex)
                guard targetRange.location != NSNotFound,
                      let swiftRange = Range(targetRange, in: result) else {
                    continue
                }

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

        // 只重编码发生脱敏的 JSON 字符串，普通正文与 JSON 排版保持原样。
        // 逐层解码兼顾工具参数中的嵌套 JSON、Unicode 转义及裸露的转义 JSON 片段。
        if depth < 8 {
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            if result.contains("\\\""),
               let decoded = try? decoder.decode(String.self, from: Data(("\"" + result + "\"").utf8)) {
                let safe = redact(decoded, secrets: secrets, depth: depth + 1)
                if safe != decoded, let data = try? encoder.encode(safe) {
                    result = String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
                }
            } else if let pattern = jsonStringPattern {
                let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: result),
                          let decoded = try? decoder.decode(String.self, from: Data(result[range].utf8)) else {
                        continue
                    }
                    let safe = redact(decoded, secrets: secrets, depth: depth + 1)
                    if safe != decoded, let data = try? encoder.encode(safe) {
                        result.replaceSubrange(range, with: String(decoding: data, as: UTF8.self))
                    }
                }
            }
        }

        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "<redacted>", options: .literal)
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
