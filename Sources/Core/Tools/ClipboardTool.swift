//
//  ClipboardTool.swift
//  AppAgent
//

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Tool for reading and writing the system clipboard.
public struct ClipboardTool: ToolProtocol {
    public let name = "clipboard"
    public let description = """
        Read or write the system clipboard. \
        Use action 'read' to get current clipboard content. \
        Use action 'write' to set clipboard content.
        """
    public let parameters = Tool.Schema(
        properties: [
            "action": .string(
                description: "The action to perform.",
                enumValues: ["read", "write"]
            ),
            "content": .string(
                description: "Text to copy to clipboard. Required for 'write'."
            )
        ],
        required: ["action"]
    )
    public let group: String = "system"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        arguments["action"]?.stringValue == "read" ? .safe : .moderate
    }

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let action = arguments["action"]?.stringValue else {
            return .error("Missing required parameter: action")
        }

        #if canImport(UIKit)
        switch action {
        case "read":
            let text = UIPasteboard.general.string ?? ""
            return .json(.object([
                "content": .string(text),
                "has_content": .bool(!text.isEmpty)
            ]))

        case "write":
            guard let content = arguments["content"]?.stringValue else {
                return .error("Missing required parameter: content (for action 'write')")
            }
            UIPasteboard.general.string = content
            return .json(.object([
                "success": .bool(true),
                "message": .string("Copied \(content.count) characters to clipboard.")
            ]))

        default:
            return .error("Unknown action: '\(action)'. Use 'read' or 'write'.")
        }
        #elseif canImport(AppKit)
        // macOS support
        switch action {
        case "read":
            let pb = NSPasteboard.general
            let text = pb.string(forType: .string) ?? ""
            return .json(.object([
                "content": .string(text),
                "has_content": .bool(!text.isEmpty)
            ]))

        case "write":
            guard let content = arguments["content"]?.stringValue else {
                return .error("Missing required parameter: content (for action 'write')")
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(content, forType: .string)
            return .json(.object([
                "success": .bool(true),
                "message": .string("Copied \(content.count) characters to clipboard.")
            ]))

        default:
            return .error("Unknown action: '\(action)'. Use 'read' or 'write'.")
        }
        #else
        return .error("Clipboard is not available on this platform.")
        #endif
    }
}
