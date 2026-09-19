//
//  FileWriteTool.swift
//  AppAgent
//

import Foundation

/// Tool for writing files within the app's sandbox directory.
///
/// Reference: hermes-agent `write_file` tool.
public struct FileWriteTool: ToolProtocol {
    public let name = "file_write"
    public let description = """
        Write content to a file in the agent's workspace (the app's Documents directory). \
        Completely replaces existing content. Creates parent directories automatically. \
        For anything outside Documents — Library, tmp, Caches — use app_sandbox_file instead.
        """
    public let parameters = Tool.Schema(
        properties: [
            "path": .string(description: "Relative path within the sandbox."),
            "content": .string(description: "Complete content to write to the file.")
        ],
        required: ["path", "content"]
    )
    public let group: String = "file"
    public let safetyLevel: Tool.SafetyLevel = .moderate

    private let pathResolver: SandboxPathResolver

    public init(sandboxRoot: URL? = nil) {
        self.pathResolver = SandboxPathResolver(sandboxRoot: sandboxRoot)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return .error("Missing required parameter: path")
        }
        guard let content = arguments["content"]?.stringValue else {
            return .error("Missing required parameter: content")
        }

        guard let resolvedURL = pathResolver.resolve(path) else {
            return .error("Invalid path: '\(path)' — path traversal is not allowed.")
        }

        do {
            // Create parent directories
            let parentDir = resolvedURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            try content.write(to: resolvedURL, atomically: true, encoding: .utf8)

            let lineCount = content.components(separatedBy: .newlines).count
            return .json(.object([
                "success": .bool(true),
                "path": .string(path),
                "bytes_written": .number(Double(content.utf8.count)),
                "lines": .number(Double(lineCount))
            ]))
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }
}
