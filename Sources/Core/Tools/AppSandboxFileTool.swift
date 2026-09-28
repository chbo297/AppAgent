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
        Browse and edit scoped files in the host app's sandbox, including Library, \
        Caches, tmp and Documents. Default scope 'host' excludes SDK internals; \
        'appagent' selects SDK storage only, and 'all' selects both. Non-host scopes \
        require explicit inspection approval. Shared preferences files require 'all'; \
        prefer app_user_defaults for scoped key access. All paths are sandbox-relative; \
        absolute paths, parent traversal and symlink escapes are rejected. \
        Shared ancestor directories are navigation-only, never write/delete targets. \
        For ordinary working files prefer file_read / file_write / file_search, which are \
        confined to a configured workspace (default: Documents/AppAgent/files). Choose an 'op':
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
            "content": .string(description: "File contents to write for 'write'."),
            "scope": HostInspectionScope.parameter
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
        let context: HostInspectionContext
        do {
            context = try await HostInspectionAccess.context(
                arguments: arguments, session: session, tool: name,
                isMutation: op == "write" || op == "delete"
            )
        } catch {
            return .error(error.localizedDescription)
        }
        guard let operation = HostStoragePolicy.Operation(rawValue: op) else {
            return .error("Unknown op: '\(op)'. Use 'list', 'read', 'write', or 'delete'.")
        }
        let resolver = SandboxPathResolver(sandboxRoot: root)
        guard let paths = resolver.paths(for: rawPath) else {
            return .error("Invalid path: use a sandbox-relative path without traversal or symlink escapes.")
        }
        // Build the protected-alias snapshot once, AFTER authorization, and reuse
        // it for the target and every list entry. Never rescan per child.
        let policy = HostStoragePolicy(root: root)
        try Task.checkCancellation()
        if let denial = policy.denial(
            logical: paths.logical, resolved: paths.resolved, scope: context.scope, operation: operation
        ) {
            return .error(denial)
        }
        let target = paths.resolved
        // Report the requested logical name, never a canonical alias to filtered storage.
        let displayPath = resolver.relativePath(of: paths.logical) ?? ""

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
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let items: [JSONValue] = entries
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url in
                    let logical = paths.logical.appendingPathComponent(url.lastPathComponent)
                    guard let resolved = resolver.validatedURL(logical),
                          policy.denial(logical: logical, resolved: resolved,
                                        scope: context.scope, operation: .list) == nil else { return nil }
                    let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let dir = values?.isDirectory ?? false
                    var entry: [String: JSONValue] = [
                        "name": .string(url.lastPathComponent),
                        "path": .string(resolver.relativePath(of: logical) ?? ""),
                        "is_dir": .bool(dir)
                    ]
                    if !dir, let size = values?.fileSize { entry["size"] = .number(Double(size)) }
                    return .object(entry)
                }
            return .json(.object([
                "path": .string(displayPath),
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
                    "path": .string(displayPath),
                    "size": .number(Double(data.count)),
                    "binary": .bool(true),
                    "note": .string("File is not valid UTF-8; \(data.count) bytes.")
                ]))
            }
            return .json(.object([
                "path": .string(displayPath),
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
                "path": .string(displayPath),
                "size": .number(Double(content.utf8.count))
            ]))
        case "delete":
            guard !rawPath.isEmpty else { return .error("'path' is required for delete.") }
            guard fm.fileExists(atPath: target.path) else {
                return .error("Path does not exist: '\(rawPath)'.")
            }
            do {
                // Validate the referent as well, but delete the requested entry:
                // removing an allowed symlink must not recursively delete its target.
                try fm.removeItem(at: paths.logical)
            } catch {
                return .error("Failed to delete '\(rawPath)': \(error.localizedDescription)")
            }
            return .json(.object(["success": .bool(true), "path": .string(displayPath)]))
        default:
            return .error("Unknown op: '\(op)'. Use 'list', 'read', 'write', or 'delete'.")
        }
    }

}
