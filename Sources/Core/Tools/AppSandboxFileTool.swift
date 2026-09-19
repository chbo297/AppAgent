//
//  AppSandboxFileTool.swift
//  AppAgent
//
//  Host-storage tool: browse and edit files anywhere inside the app's sandbox
//  (NSHomeDirectory()). Distinct from the sandboxRoot-scoped File* tools, which
//  are confined to a caller-provided working directory. Categorized under the
//  "host-storage" group so it can be enabled/disabled together with the other
//  host-introspection storage tools.
//

import Foundation

public struct AppSandboxFileTool: ToolProtocol {
    public let name = "app_sandbox_file"
    public let description = """
        Browse and edit files anywhere in the host app's sandbox — its whole home \
        directory, so Library, Caches and tmp as well as Documents. All paths are \
        relative to the sandbox root; absolute paths and '..' escapes are rejected. \
        For ordinary working files prefer file_read / file_write / file_search, which are \
        scoped to Documents; reach for this one when you need the app's own storage \
        (preferences plists, databases, caches). Choose an 'op':
        - 'list': list entries under 'path' (default root). Marks directories.
        - 'read': read the UTF-8 contents of the file at 'path'.
        - 'write': write 'content' to 'path' (creates intermediate dirs).
        - 'delete': remove the file or directory at 'path'.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(description: "Operation.", enumValues: ["list", "read", "write", "delete"]),
            "_why": .string(description: "One sentence on why this is needed. Shown to the user when they are asked to approve; supply it for 'delete'."),
            "path": .string(description: "Sandbox-relative path. Empty/omitted means the sandbox root (list only)."),
            "content": .string(description: "File contents to write for 'write'.")
        ],
        required: ["op"]
    )
    public let group = "host-storage"
    public let safetyLevel: Tool.SafetyLevel = .sensitive

    /// Browsing the sandbox is harmless; deleting from it is not. Without this split
    /// one approval for `list` would carry over to `delete`.
    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue {
        case "list", "read": return .safe
        case "write": return .moderate
        case "delete": return .sensitive
        default: return .sensitive
        }
    }

    private let root: URL

    public init(root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.root = root.standardizedFileURL
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? ""
        let rawPath = arguments["path"]?.stringValue ?? ""

        let target: URL
        do {
            target = try resolve(rawPath)
        } catch let err as ResolveError {
            return .error(err.message)
        }

        let fm = FileManager.default
        switch op {
        case "list":
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else {
                return .error("Path does not exist: '\(rawPath)'.")
            }
            guard isDir.boolValue else {
                return .error("Path is not a directory: '\(rawPath)'. Use 'read' for files.")
            }
            let entries = (try? fm.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let items: [JSONValue] = entries
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let dir = values?.isDirectory ?? false
                    var entry: [String: JSONValue] = [
                        "name": .string(url.lastPathComponent),
                        "path": .string(relative(of: url)),
                        "is_dir": .bool(dir)
                    ]
                    if !dir, let size = values?.fileSize { entry["size"] = .number(Double(size)) }
                    return .object(entry)
                }
            return .json(.object([
                "path": .string(relative(of: target)),
                "count": .number(Double(items.count)),
                "entries": .array(items)
            ]))
        case "read":
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else {
                return .error("File does not exist: '\(rawPath)'.")
            }
            guard !isDir.boolValue else {
                return .error("Path is a directory: '\(rawPath)'. Use 'list' instead.")
            }
            guard let data = fm.contents(atPath: target.path) else {
                return .error("Failed to read file: '\(rawPath)'.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .json(.object([
                    "path": .string(relative(of: target)),
                    "size": .number(Double(data.count)),
                    "binary": .bool(true),
                    "note": .string("File is not valid UTF-8; \(data.count) bytes.")
                ]))
            }
            return .json(.object([
                "path": .string(relative(of: target)),
                "size": .number(Double(data.count)),
                "content": .string(text)
            ]))
        case "write":
            guard !rawPath.isEmpty else { return .error("'path' is required for write.") }
            guard let content = arguments["content"]?.stringValue else {
                return .error("'content' is required for write.")
            }
            let parent = target.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try content.data(using: .utf8)?.write(to: target, options: .atomic)
            } catch {
                return .error("Failed to write '\(rawPath)': \(error.localizedDescription)")
            }
            return .json(.object([
                "success": .bool(true),
                "path": .string(relative(of: target)),
                "size": .number(Double(content.utf8.count))
            ]))
        case "delete":
            guard !rawPath.isEmpty else { return .error("'path' is required for delete.") }
            guard fm.fileExists(atPath: target.path) else {
                return .error("Path does not exist: '\(rawPath)'.")
            }
            do {
                try fm.removeItem(at: target)
            } catch {
                return .error("Failed to delete '\(rawPath)': \(error.localizedDescription)")
            }
            return .json(.object(["success": .bool(true), "path": .string(relative(of: target))]))
        default:
            return .error("Unknown op: '\(op)'. Use 'list', 'read', 'write', or 'delete'.")
        }
    }

    // MARK: - Path safety

    private struct ResolveError: Error { let message: String }

    /// Resolve a sandbox-relative path, rejecting absolute paths and any '..'
    /// escape that would leave the sandbox root.
    private func resolve(_ rawPath: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            throw ResolveError(message: "Absolute paths are not allowed; use a sandbox-relative path.")
        }
        let resolved = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw ResolveError(message: "Path escapes the sandbox root: '\(rawPath)'.")
        }
        return resolved
    }

    /// Sandbox-relative representation of a URL, for reporting back to the caller.
    private func relative(of url: URL) -> String {
        let full = url.standardizedFileURL.path
        let rootPath = root.path
        if full == rootPath { return "" }
        if full.hasPrefix(rootPath + "/") { return String(full.dropFirst(rootPath.count + 1)) }
        return full
    }
}
