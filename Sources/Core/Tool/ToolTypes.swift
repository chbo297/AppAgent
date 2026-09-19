//
//  ToolTypes.swift
//  AppAgent
//

import Foundation

// MARK: - Tool Namespace

/// Namespace for tool-related types.
///
/// `Tool` is a caseless enum used purely as a namespace. The protocol for
/// tool conformance is `ToolProtocol`.
public enum Tool {

    /// Describes the input parameters of a tool (maps to a JSON Schema object type).
    public struct Schema: Sendable {
        public let properties: [String: JSONSchema]
        public let required: [String]

        public init(properties: [String: JSONSchema] = [:], required: [String] = []) {
            self.properties = properties
            self.required = required
        }
    }

    /// Determines whether user confirmation is required before executing a tool.
    public enum SafetyLevel: String, Sendable, Comparable {
        /// Read-only operations — no confirmation needed.
        case safe
        /// Side effects but reversible — no confirmation needed by default.
        case moderate
        /// Needs user confirmation before execution.
        case sensitive
        /// Needs explicit user authorization (e.g., payments, deletions).
        case dangerous

        /// Ordering so callers can say "anything above `safe` mutates state".
        public var rank: Int {
            switch self {
            case .safe: return 0
            case .moderate: return 1
            case .sensitive: return 2
            case .dangerous: return 3
            }
        }

        public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// How much the agent is allowed to change at runtime.
    ///
    /// On iOS the app sandbox is decided by entitlements and cannot be tightened at
    /// runtime, so the equivalent of Codex's `sandbox_mode` has to be enforced by the
    /// tool layer itself. `readOnly` makes every call above `.safe` fail outright
    /// rather than prompting — crossing the boundary should be a hard failure, not a
    /// dialog the user clicks through.
    public enum MutationPolicy: String, Sendable {
        /// Inspection only. Anything that writes, deletes, or reflects into the
        /// runtime is refused before it executes.
        case readOnly
        /// Mutations run, still subject to the per-call safety gate.
        case allowed
    }

    /// The result of executing a tool.
    /// 工具返回的图片。走多模态 content block，不占文本上下文预算。
    public struct ImageOutput: Sendable, Equatable {
        /// 原始字节（PNG / JPEG…）。转 base64 在 mapper 里做，避免在核心层里存两份。
        public let data: Data
        /// IANA media type，如 "image/png"。
        public let mediaType: String
        /// 给纯文本通道的说明：尺寸、来源。模型即使看不到图也知道发生了什么。
        public let caption: String

        public init(data: Data, mediaType: String = "image/png", caption: String) {
            self.data = data
            self.mediaType = mediaType
            self.caption = caption
        }
    }

    public enum Output: Sendable {
        case text(String)
        case json(JSONValue)
        case error(String)
        /// 图片 + 一句文字说明。文本部分照常进上下文，图片交给 provider 的多模态通道。
        case image(ImageOutput)

        /// Convert to a string representation for sending back to the model.
        public var stringValue: String {
            switch self {
            case .text(let s): return s
            case .json(let v):
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                if let data = try? encoder.encode(v),
                   let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return "\(v)"
            case .error(let s): return "Error: \(s)"
            case .image(let image):
                return "\(image.caption) [\(image.mediaType), \(image.data.count) bytes attached]"
            }
        }

        /// 随这次结果一起送给模型的图片（目前最多一张）。
        public var images: [ImageOutput] {
            if case .image(let image) = self { return [image] }
            return []
        }
    }
}

// MARK: - ToolProtocol

/// Unified protocol for all tools — stateless and stateful share the same interface.
/// The distinction is in registration (shared instance vs factory), not in the protocol.
public protocol ToolProtocol: Sendable {
    /// Unique tool name (used for matching, sorting, and toolPrompts lookup).
    var name: String { get }
    /// Human-readable description of what the tool does.
    var description: String { get }
    /// JSON Schema describing the tool's input parameters.
    var parameters: Tool.Schema { get }
    /// Whether this tool is currently enabled (default: true).
    var enabled: Bool { get }

    /// Execute the tool with the given arguments.
    /// Stateless tools may ignore the session parameter;
    /// stateful tools use it to access per-session state.
    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output

    /// Logical grouping for batch enable/disable and UI organization.
    /// SDK built-in groups: "core", "file", "skills", "media", "web", "system", "custom".
    /// Host apps can use any string (e.g., "commerce", "social").
    var group: String { get }

    /// Safety level — determines whether user confirmation is required.
    var safetyLevel: Tool.SafetyLevel { get }

    /// Safety level for one specific call.
    ///
    /// Multi-op tools override this so a `list` is not gated like a `delete`:
    /// the static `safetyLevel` would otherwise have to be the most dangerous
    /// common denominator, which means either every read prompts the user or no
    /// write does. The mutation policy is evaluated against this value too.
    func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel

    /// Cap on the UTF-8 byte size of this tool's result before it reaches the model.
    /// `nil` uses the agent-wide budget (`AIAgentProfile.toolOutputMaxBytes`).
    /// Override only for tools whose value genuinely lies in bulk output.
    var outputMaxBytes: Int? { get }
}

extension ToolProtocol {
    public var enabled: Bool { true }
    public var group: String { "custom" }
    public var safetyLevel: Tool.SafetyLevel { .safe }
    public var outputMaxBytes: Int? { nil }

    /// Single-purpose tools keep one level for every call.
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        safetyLevel
    }
}
