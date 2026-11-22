//
//  FileTool.swift
//  AppAgent
//

import Foundation

public struct FileTool: ToolProtocol {
    public let name = "file"
    public let description = """
        Access registered AppAgent and host file resources through logical URIs. \
        Use op='catalog' first to discover resources. Use list, read, search, write, \
        delete, or reveal_path with a URI such as agent://workspace/notes.txt or host://source/.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(
                description: "Operation.",
                enumValues: ["catalog", "list", "read", "search", "write", "delete", "reveal_path"],
                defaultValue: .string("catalog")
            ),
            "uri": .string(
                description: "Logical resource URI. Omit only for catalog."
            ),
            "pattern": .string(
                description: "Content substring or filename glob for search."
            ),
            "target": .string(
                description: "Search target.",
                enumValues: ["content", "files"],
                defaultValue: .string("content")
            ),
            "content": .string(description: "UTF-8 content for write."),
            "offset": .integer(
                description: "One-based line offset for read.",
                minimum: 1,
                defaultValue: .number(1)
            ),
            "limit": .integer(
                description: "Maximum lines or results.",
                minimum: 1,
                maximum: 2000,
                defaultValue: .number(500)
            ),
            "scope": HostInspectionScope.parameter
        ],
        required: []
    )
    public let group = ToolGroups.file
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let registry: FileResourceRegistry

    public init(registry: FileResourceRegistry = FileResourceRegistry()) {
        self.registry = registry
    }

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        guard let rawOp = arguments["op"]?.stringValue else {
            return .sensitive
        }
        switch rawOp {
        case "catalog", "list", "read", "search":
            return .safe
        case "write":
            return .moderate
        case "delete", "reveal_path":
            return .sensitive
        default:
            return .sensitive
        }
    }

    public func execute(
        arguments: [String: JSONValue],
        session: AISession
    ) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? "catalog"
        if op == "catalog" {
            return catalog()
        }
        guard let uri = arguments["uri"]?.stringValue, !uri.isEmpty else {
            return .error("'uri' is required for op='\(op)'. Use op='catalog' to discover resources.")
        }
        guard let resolved = registry.resolve(uri) else {
            return .error("Unknown file resource URI '\(uri)'. Use op='catalog' first.")
        }
        guard let operation = FileResourceOperation(rawValue: op) else {
            return .error("Unknown op '\(op)'.")
        }
        guard resolved.descriptor.operations.contains(operation) else {
            let allowed = resolved.descriptor.operations.map(\.rawValue).sorted().joined(separator: ", ")
            let readOnly = resolved.descriptor.operations.isDisjoint(with: [.write, .delete])
                ? " (read-only resource)"
                : ""
            return .error(
                "Operation '\(op)' is not allowed for '\(resolved.descriptor.uri)'\(readOnly). Allowed: \(allowed)."
            )
        }
        guard let paths = safePaths(
            resource: resolved.descriptor,
            relativePath: resolved.relativePath
        ) else {
            return .error("Invalid resource path.")
        }

        let isMutation = op == "write" || op == "delete"
        var hostGate: HostStorageGate?
        if resolved.descriptor.owner == .host {
            let context: HostInspectionContext
            do {
                context = try await HostInspectionAccess.context(
                    arguments: arguments,
                    session: session,
                    tool: name,
                    isMutation: isMutation
                )
            } catch {
                return .error(error.localizedDescription)
            }
            // Build the protected-alias snapshot once, after authorization, and reuse it
            // for the target and every listed or searched entry.
            let gate = HostStorageGate(resource: resolved.descriptor, scope: context.scope)
            if let denial = gate.denial(
                logical: paths.logical,
                resolved: paths.resolved,
                operation: Self.policyOperation(for: operation, target: paths.resolved)
            ) {
                return .error(denial)
            }
            hostGate = gate
        } else if isMutation, let denial = SessionRepositoryProtection.mutationDenial(
            logical: paths.logical,
            resolved: paths.resolved,
            sandboxRoot: resolved.descriptor.rootURL
        ) {
            return .error(denial)
        }

        switch op {
        case "list":
            return list(resource: resolved.descriptor, relativePath: resolved.relativePath, gate: hostGate)
        case "read":
            return read(
                resource: resolved.descriptor,
                relativePath: resolved.relativePath,
                arguments: arguments
            )
        case "search":
            return search(
                resource: resolved.descriptor,
                relativePath: resolved.relativePath,
                arguments: arguments,
                gate: hostGate
            )
        case "write":
            return write(
                resource: resolved.descriptor,
                relativePath: resolved.relativePath,
                content: arguments["content"]?.stringValue
            )
        case "delete":
            return delete(resource: resolved.descriptor, relativePath: resolved.relativePath)
        case "reveal_path":
            return revealPath(resource: resolved.descriptor, relativePath: resolved.relativePath)
        case "catalog":
            return catalog()
        default:
            return .error("Unknown op '\(op)'.")
        }
    }

    private func catalog() -> Tool.Output {
        let items = registry.resources.values.sorted { $0.uri < $1.uri }.map { resource in
            JSONValue.object([
                "uri": .string(resource.uri),
                "summary": .string(resource.summary),
                "owner": .string(resource.owner.rawValue),
                "operations": .array(resource.operations.map { .string($0.rawValue) }.sorted {
                    $0.stringValue ?? "" < $1.stringValue ?? ""
                })
            ])
        }
        return .json(.object([
            "resources": .array(items),
            "count": .number(Double(items.count))
        ]))
    }

    private func safePaths(
        resource: FileResourceDescriptor,
        relativePath: String
    ) -> (logical: URL, resolved: URL)? {
        SandboxPathResolver(sandboxRoot: resource.rootURL).paths(for: relativePath)
    }

    /// Every file op maps onto one storage-policy check. Search and reveal_path read
    /// a file's content or path, or navigate a directory, so they reuse read/list.
    private static func policyOperation(
        for operation: FileResourceOperation,
        target: URL
    ) -> HostStoragePolicy.Operation {
        switch operation {
        case .list:
            return .list
        case .read:
            return .read
        case .write:
            return .write
        case .delete:
            return .delete
        case .search, .revealPath:
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? .list : .read
        }
    }

    private func list(
        resource: FileResourceDescriptor,
        relativePath: String,
        gate: HostStorageGate?
    ) -> Tool.Output {
        guard let paths = safePaths(resource: resource, relativePath: relativePath) else {
            return .error("Invalid resource path.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.resolved.path, isDirectory: &isDirectory) else {
            return .error("Path does not exist.")
        }
        guard isDirectory.boolValue else {
            return .error("Path is not a directory.")
        }
        let resolver = SandboxPathResolver(sandboxRoot: resource.rootURL)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.resolved,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let result: [JSONValue] = entries.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.compactMap { entry -> JSONValue? in
            let logical = paths.logical.appendingPathComponent(entry.lastPathComponent)
            guard let resolved = resolver.validatedURL(logical),
                  let relative = resolver.relativePath(of: logical) else {
                return nil
            }
            // Hide protected entries by name, not just by content.
            if let gate, gate.denial(logical: logical, resolved: resolved, operation: .list) != nil {
                return nil
            }
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            var item: [String: JSONValue] = [
                "uri": .string(resource.uri + "/" + relative),
                "name": .string(entry.lastPathComponent),
                "is_dir": .bool(values?.isDirectory ?? false)
            ]
            if let size = values?.fileSize, values?.isDirectory == false {
                item["size"] = .number(Double(size))
            }
            return JSONValue.object(item)
        }
        let displayURI = relativePath == "."
            ? resource.uri
            : resource.uri + "/" + relativePath
        return .json(.object([
            "uri": .string(displayURI),
            "entries": .array(result),
            "count": .number(Double(result.count))
        ]))
    }

    private func read(
        resource: FileResourceDescriptor,
        relativePath: String,
        arguments: [String: JSONValue]
    ) -> Tool.Output {
        guard let paths = safePaths(resource: resource, relativePath: relativePath) else {
            return .error("Invalid resource path.")
        }
        guard let offset = ToolArgumentValues.integer(arguments, "offset", default: 1),
              let limit = ToolArgumentValues.integer(arguments, "limit", default: 500, range: 1...2000) else {
            return .error("'offset' and 'limit' must be valid positive integers.")
        }
        guard let data = FileManager.default.contents(atPath: paths.resolved.path) else {
            return .error("File does not exist or could not be read.")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return .json(.object([
                "uri": .string(resource.uri + "/" + relativePath),
                "binary": .bool(true),
                "size": .number(Double(data.count))
            ]))
        }
        let lines = content.components(separatedBy: .newlines)
        let start = offset - 1
        guard start < lines.count else {
            return .json(.object([
                "uri": .string(resource.uri + "/" + relativePath),
                "content": .string(""),
                "total_lines": .number(Double(lines.count))
            ]))
        }
        let end = min(lines.count, start + limit)
        let numbered = lines[start..<end].enumerated().map { index, line in
            "\(start + index + 1)|\(line)"
        }
        return .json(.object([
            "uri": .string(resource.uri + "/" + relativePath),
            "content": .string(numbered.joined(separator: "\n")),
            "total_lines": .number(Double(lines.count)),
            "lines_returned": .number(Double(end - start))
        ]))
    }

    private func search(
        resource: FileResourceDescriptor,
        relativePath: String,
        arguments: [String: JSONValue],
        gate: HostStorageGate?
    ) -> Tool.Output {
        guard let pattern = arguments["pattern"]?.stringValue, !pattern.isEmpty else {
            return .error("'pattern' is required for search.")
        }
        guard let limit = ToolArgumentValues.integer(arguments, "limit", default: 50, range: 1...2000) else {
            return .error("'limit' must be an integer between 1 and 2000.")
        }
        guard let paths = safePaths(resource: resource, relativePath: relativePath) else {
            return .error("Invalid resource path.")
        }
        let target = arguments["target"]?.stringValue ?? "content"
        guard target == "content" || target == "files" else {
            return .error("'target' must be 'content' or 'files'.")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: paths.resolved,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .error("Resource directory could not be enumerated.")
        }
        let resolver = SandboxPathResolver(sandboxRoot: resource.rootURL)
        var matches: [JSONValue] = []
        let loweredPattern = pattern.lowercased()
        for case let fileURL as URL in enumerator {
            guard matches.count < limit else {
                break
            }
            guard let safeURL = resolver.validatedURL(fileURL),
                  let relative = resolver.relativePath(of: fileURL) else {
                enumerator.skipDescendants()
                continue
            }
            let values = try? safeURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if let gate {
                let logical = resource.rootURL.appendingPathComponent(relative)
                if gate.denial(logical: logical, resolved: safeURL, operation: .list) != nil {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if target == "content", values?.isRegularFile == true,
                   gate.denial(logical: logical, resolved: safeURL, operation: .read) != nil {
                    continue
                }
            }
            if target == "files" {
                if matchGlob(fileURL.lastPathComponent.lowercased(), pattern: loweredPattern) {
                    matches.append(.string(resource.uri + "/" + relative))
                }
                continue
            }
            guard values?.isRegularFile == true,
                  let data = FileManager.default.contents(atPath: safeURL.path),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }
            for (lineNumber, line) in content.components(separatedBy: .newlines).enumerated() {
                guard matches.count < limit else {
                    break
                }
                if line.lowercased().contains(loweredPattern) {
                    matches.append(.object([
                        "uri": .string(resource.uri + "/" + relative),
                        "line": .number(Double(lineNumber + 1)),
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

    private func write(
        resource: FileResourceDescriptor,
        relativePath: String,
        content: String?
    ) -> Tool.Output {
        guard let content else {
            return .error("'content' is required for write.")
        }
        guard let paths = safePaths(resource: resource, relativePath: relativePath) else {
            return .error("Invalid resource path.")
        }
        do {
            try FileManager.default.createDirectory(
                at: paths.resolved.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let current = safePaths(resource: resource, relativePath: relativePath),
                  SandboxPathResolver.samePath(current.resolved, paths.resolved) else {
                return .error("Write destination changed.")
            }
            if let denial = SessionRepositoryProtection.mutationDenial(
                logical: current.logical,
                resolved: current.resolved,
                sandboxRoot: resource.rootURL
            ) {
                return .error(denial)
            }
            try content.write(to: current.resolved, atomically: true, encoding: .utf8)
            return .json(.object([
                "success": .bool(true),
                "uri": .string(resource.uri + "/" + relativePath),
                "bytes_written": .number(Double(content.utf8.count))
            ]))
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }

    private func delete(
        resource: FileResourceDescriptor,
        relativePath: String
    ) -> Tool.Output {
        guard let paths = safePaths(resource: resource, relativePath: relativePath) else {
            return .error("Invalid resource path.")
        }
        // Compare paths, not the raw string: `./.` also standardizes to the root.
        guard !SandboxPathResolver.samePath(paths.logical, resource.rootURL) else {
            return .error("Deleting a resource root is not allowed.")
        }
        if let denial = SessionRepositoryProtection.mutationDenial(
            logical: paths.logical,
            resolved: paths.resolved,
            sandboxRoot: resource.rootURL
        ) {
            return .error(denial)
        }
        do {
            try FileManager.default.removeItem(at: paths.logical)
            return .json(.object([
                "success": .bool(true),
                "uri": .string(resource.uri + "/" + relativePath)
            ]))
        } catch {
            return .error("Failed to delete file: \(error.localizedDescription)")
        }
    }

    private func revealPath(
        resource: FileResourceDescriptor,
        relativePath: String
    ) -> Tool.Output {
        guard let paths = safePaths(resource: resource, relativePath: relativePath) else {
            return .error("Invalid resource path.")
        }
        return .json(.object([
            "uri": .string(resource.uri + "/" + relativePath),
            "path": .string(paths.logical.path),
            "note": .string("Use this physical path only for the current local process; logical URIs remain the stable address.")
        ]))
    }

    private func matchGlob(_ value: String, pattern: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else {
            return value.contains(pattern)
        }
        let text = Array(value)
        let glob = Array(pattern)
        var textIndex = 0
        var patternIndex = 0
        var retryIndex = 0
        var lastStar: Int?
        while textIndex < text.count {
            if patternIndex < glob.count,
               glob[patternIndex] == "?" || glob[patternIndex] == text[textIndex] {
                textIndex += 1
                patternIndex += 1
            } else if patternIndex < glob.count, glob[patternIndex] == "*" {
                lastStar = patternIndex
                patternIndex += 1
                retryIndex = textIndex
            } else if let star = lastStar {
                retryIndex += 1
                textIndex = retryIndex
                patternIndex = star + 1
            } else {
                return false
            }
        }
        while patternIndex < glob.count, glob[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == glob.count
    }
}

/// Host storage ownership for one `file` call. The policy snapshot is built once and
/// reused for the target and every listed or searched entry. Resources registered below
/// the host sandbox root are checked with sandbox-relative names, so `Documents/AppAgent`
/// stays protected even when the resource root is `Documents`.
private struct HostStorageGate {
    private let policy: HostStoragePolicy
    private let scope: HostInspectionScope
    private let resourceRoot: URL
    private let policyRoot: URL

    init(resource: FileResourceDescriptor, scope: HostInspectionScope) {
        let storageRoot = resource.hostSandboxRootURL ?? resource.rootURL
        let policyRoot = SandboxPathResolver.contains(resource.rootURL, in: storageRoot)
            ? storageRoot
            : resource.rootURL
        self.policy = HostStoragePolicy(root: policyRoot)
        self.scope = scope
        self.resourceRoot = resource.rootURL
        self.policyRoot = policyRoot
    }

    func denial(logical: URL, resolved: URL, operation: HostStoragePolicy.Operation) -> String? {
        let paths = policyPaths(logical: logical, resolved: resolved)
        return policy.denial(
            logical: paths.logical,
            resolved: paths.resolved,
            scope: scope,
            operation: operation
        )
    }

    private func policyPaths(logical: URL, resolved: URL) -> (logical: URL, resolved: URL) {
        if SandboxPathResolver.samePath(resourceRoot, policyRoot) {
            return (logical, resolved)
        }
        let relative = logical.pathComponents.dropFirst(resourceRoot.pathComponents.count)
        let policyLogical = relative.reduce(policyRoot) {
            $0.appendingPathComponent($1)
        }
        let policyResolved = SandboxPathResolver.canonicalURL(policyLogical) ?? policyLogical.standardizedFileURL
        return (policyLogical, policyResolved)
    }
}
