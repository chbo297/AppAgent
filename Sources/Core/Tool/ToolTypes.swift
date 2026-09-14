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
    public enum SafetyLevel: String, Sendable {
        /// Read-only operations — no confirmation needed.
        case safe
        /// Side effects but reversible — no confirmation needed by default.
        case moderate
        /// Needs user confirmation before execution.
        case sensitive
        /// Needs explicit user authorization (e.g., payments, deletions).
        case dangerous
    }

    /// The result of executing a tool.
    public enum Output: Sendable {
        case text(String)
        case json(JSONValue)
        case error(String)

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
            }
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
}

extension ToolProtocol {
    public var enabled: Bool { true }
    public var group: String { "custom" }
    public var safetyLevel: Tool.SafetyLevel { .safe }
}
