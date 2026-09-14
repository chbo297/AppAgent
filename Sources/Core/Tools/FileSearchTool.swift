//
//  FileSearchTool.swift
//  AppAgent
//

import Foundation

/// Tool for searching files within the app's sandbox directory.
///
/// Reference: hermes-agent `search_files` tool.
public struct FileSearchTool: ToolProtocol {
    public let name = "file_search"
    public let description = """
        Search file contents or find files by name within the app sandbox. \
        target='content': search inside file contents. \
        target='files': find files by name pattern (glob-style, e.g., '*.txt').
        """
    public let parameters = Tool.Schema(
        properties: [
            "pattern": .string(description: "Search pattern (substring for content, glob for files)."),
            "target": .string(
                description: "'content' searches inside files, 'files' searches by filename.",
                enumValues: ["content", "files"],
                defaultValue: .string("content")
            ),
            "path": .string(
                description: "Subdirectory to search in (default: sandbox root).",
                defaultValue: .string(".")
            ),
            "limit": .integer(
                description: "Maximum number of results (default: 50).",
                defaultValue: .number(50)
            )
        ],
        required: ["pattern"]
    )
    public let group: String = "file"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let pathResolver: SandboxPathResolver

    public init(sandboxRoot: URL? = nil) {
        self.pathResolver = SandboxPathResolver(sandboxRoot: sandboxRoot)
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let pattern = arguments["pattern"]?.stringValue, !pattern.isEmpty else {
            return .error("Missing required parameter: pattern")
        }

        let targetStr = arguments["target"]?.stringValue ?? "content"
        let subPath = arguments["path"]?.stringValue ?? "."
        let limit = Int(arguments["limit"]?.numberValue ?? 50)

        guard let searchDir = pathResolver.resolve(subPath) else {
            return .error("Invalid path: '\(subPath)'")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: searchDir.path) else {
            return .error("Directory not found: \(subPath)")
        }

        if targetStr == "files" {
            return searchByFilename(pattern: pattern, directory: searchDir, limit: limit)
        } else {
            return searchByContent(pattern: pattern, directory: searchDir, limit: limit)
        }
    }

    // MARK: - Private

    private func searchByFilename(pattern: String, directory: URL, limit: Int) -> Tool.Output {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return .error("Cannot enumerate directory")
        }

        var matches: [JSONValue] = []
        let loweredPattern = pattern.lowercased()

        for case let fileURL as URL in enumerator {
            guard matches.count < limit else { break }
            let fileName = fileURL.lastPathComponent.lowercased()
            if matchGlob(fileName, pattern: loweredPattern) {
                let relativePath = fileURL.path.replacingOccurrences(of: pathResolver.sandboxRoot.resolvingSymlinksInPath().path + "/", with: "")
                matches.append(.string(relativePath))
            }
        }

        return .json(.object([
            "matches": .array(matches),
            "count": .number(Double(matches.count))
        ]))
    }

    private func searchByContent(pattern: String, directory: URL, limit: Int) -> Tool.Output {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return .error("Cannot enumerate directory")
        }

        var matches: [JSONValue] = []
        let lowered = pattern.lowercased()

        for case let fileURL as URL in enumerator {
            guard matches.count < limit else { break }

            // Only search text files (skip binary)
            guard let data = fm.contents(atPath: fileURL.path),
                  let content = String(data: data, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: .newlines)
            for (lineNum, line) in lines.enumerated() {
                guard matches.count < limit else { break }
                if line.lowercased().contains(lowered) {
                    let relativePath = fileURL.path.replacingOccurrences(of: pathResolver.sandboxRoot.resolvingSymlinksInPath().path + "/", with: "")
                    matches.append(.object([
                        "file": .string(relativePath),
                        "line": .number(Double(lineNum + 1)),
                        "content": .string(String(line.prefix(500)))
                    ]))
                }
            }
        }

        return .json(.object([
            "matches": .array(matches),
            "count": .number(Double(matches.count))
        ]))
    }

    /// Simple glob matching (supports * and ?).
    private func matchGlob(_ string: String, pattern: String) -> Bool {
        // Convert glob to simple contains for * prefix/suffix patterns
        if pattern == "*" { return true }
        if pattern.hasPrefix("*") && pattern.hasSuffix("*") {
            let inner = String(pattern.dropFirst().dropLast())
            return string.contains(inner)
        }
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2))
            return string.hasSuffix("." + ext)
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return string.hasPrefix(prefix)
        }
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return string.hasSuffix(suffix)
        }
        return string.contains(pattern)
    }

}
