//
//  FileReadTool.swift
//  AppAgent
//

import Foundation

/// Tool for reading files within the app's sandbox directory.
///
/// Reference: hermes-agent `read_file` tool.
public struct FileReadTool: ToolProtocol {
    public let name = "file_read"
    public let description = """
        Read a text file within the app sandbox. Returns content with line numbers. \
        Use offset and limit for large files.
        """
    public let parameters = Tool.Schema(
        properties: [
            "path": .string(description: "Relative path within the sandbox."),
            "offset": .integer(
                description: "Line number to start reading from (1-indexed, default: 1).",
                minimum: 1,
                defaultValue: .number(1)
            ),
            "limit": .integer(
                description: "Maximum number of lines to read (default: 500).",
                maximum: 2000,
                defaultValue: .number(500)
            )
        ],
        required: ["path"]
    )
    public let group: String = "file"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let pathResolver: SandboxPathResolver

    public init(sandboxRoot: URL? = nil) {
        self.pathResolver = SandboxPathResolver(sandboxRoot: sandboxRoot)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return .error("Missing required parameter: path")
        }

        guard let resolvedURL = pathResolver.resolve(path) else {
            return .error("Invalid path: '\(path)' — path traversal is not allowed.")
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return .error("File not found: \(path)")
        }

        let offset = Int(arguments["offset"]?.numberValue ?? 1)
        let limit = Int(arguments["limit"]?.numberValue ?? 500)

        do {
            let content = try String(contentsOf: resolvedURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let startIdx = max(0, offset - 1)
            let endIdx = min(lines.count, startIdx + limit)

            if startIdx >= lines.count {
                return .json(.object([
                    "content": .string(""),
                    "total_lines": .number(Double(lines.count)),
                    "message": .string("Offset \(offset) exceeds file length (\(lines.count) lines)")
                ]))
            }

            let slice = lines[startIdx..<endIdx]
            let numbered = slice.enumerated().map { "\(startIdx + $0.offset + 1)|\($0.element)" }
            let result = numbered.joined(separator: "\n")

            return .json(.object([
                "content": .string(result),
                "total_lines": .number(Double(lines.count)),
                "lines_returned": .number(Double(endIdx - startIdx))
            ]))
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }
}
