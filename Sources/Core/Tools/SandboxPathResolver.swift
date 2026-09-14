//
//  SandboxPathResolver.swift
//  AppAgent
//

import Foundation

/// Safely resolves relative paths within a sandbox directory.
///
/// Uses `resolvingSymlinksInPath()` to prevent symlink-based traversal attacks.
/// Reference: hermes-agent `path_security.py`.
public struct SandboxPathResolver: Sendable {
    public let sandboxRoot: URL

    public init(sandboxRoot: URL? = nil) {
        if let root = sandboxRoot {
            self.sandboxRoot = root
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.sandboxRoot = docs.appendingPathComponent("AppAgent/files")
        }
    }

    /// Resolve a relative path to a safe absolute URL within the sandbox.
    /// Returns nil if the resolved path escapes the sandbox.
    /// Pass "." to get the sandbox root itself.
    public func resolve(_ relativePath: String) -> URL? {
        // 1. Normalize backslashes
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")

        // 2. Handle "." as sandbox root
        if normalized == "." {
            return sandboxRoot.resolvingSymlinksInPath()
        }

        // 3. Resolve symlinks (key improvement over .standardized)
        let resolved = sandboxRoot.appendingPathComponent(normalized).resolvingSymlinksInPath()
        let sandboxResolved = sandboxRoot.resolvingSymlinksInPath()

        // 4. Prefix check only — no fragile pattern matching
        guard resolved.path.hasPrefix(sandboxResolved.path) else { return nil }

        return resolved
    }
}
