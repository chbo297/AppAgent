//
//  SandboxPathResolver.swift
//  AppAgent
//

import Foundation
import Darwin

/// Safely resolves relative paths within a sandbox directory.
///
/// Resolves every component, including dangling links and parents of new files.
/// Reference: hermes-agent `path_security.py`.
public struct SandboxPathResolver: Sendable {
    public let sandboxRoot: URL

    public init(sandboxRoot: URL? = nil) {
        if let root = sandboxRoot {
            self.sandboxRoot = root.standardizedFileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.sandboxRoot = docs.appendingPathComponent("AppAgent/files")
        }
    }

    /// Resolve a relative path to a safe absolute URL within the sandbox.
    /// Returns nil for absolute paths, parent traversal or a symlink escape.
    /// Pass "." to get the sandbox root itself.
    public func resolve(_ relativePath: String) -> URL? {
        paths(for: relativePath)?.resolved
    }

    /// Keep both names: a scope check must not lose the logical name of a symlink.
    func paths(for relativePath: String) -> (logical: URL, resolved: URL)? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !normalized.split(separator: "/").contains("..") else { return nil }
        let logical = sandboxRoot.appendingPathComponent(normalized).standardizedFileURL
        guard Self.contains(logical, in: sandboxRoot),
              let resolved = validatedURL(logical) else { return nil }
        return (logical, resolved)
    }

    /// Enumeration needs the same check for EVERY entry, not just its starting directory.
    func validatedURL(_ url: URL) -> URL? {
        guard let canonicalRoot = Self.canonicalURL(sandboxRoot) else { return nil }
        guard Self.contains(url, in: sandboxRoot) || Self.contains(url, in: canonicalRoot) else {
            return nil
        }
        guard let resolved = Self.canonicalURL(url) else { return nil }
        return Self.contains(resolved, in: canonicalRoot) ? resolved : nil
    }

    func relativePath(of url: URL) -> String? {
        for root in [sandboxRoot, Self.canonicalURL(sandboxRoot)].compactMap({ $0 }) {
            guard Self.contains(url, in: root) else { continue }
            return url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        }
        return nil
    }

    /// Compare the candidate ancestor's filesystem identity, not a lowercased
    /// pathname. Case variants may be aliases on APFS, but distinct on APFSX.
    /// Checking a component boundary still rejects prefix siblings.
    static func contains(_ url: URL, in root: URL) -> Bool {
        let extra = url.pathComponents.count - root.pathComponents.count
        guard extra >= 0 else { return false }
        var ancestor = url
        for _ in 0..<extra { ancestor.deleteLastPathComponent() }
        return samePath(ancestor, root)
    }

    struct FileIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
        return FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Also handles not-yet-created targets by comparing their existing ancestors.
    /// Only fold a missing basename when its parent filesystem says names are
    /// case insensitive. Distinct existing objects are NEVER merged by spelling.
    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.pathComponents == rhs.pathComponents { return true }
        if let left = identity(of: lhs), let right = identity(of: rhs) { return left == right }
        guard lhs.pathComponents.count > 1, rhs.pathComponents.count > 1 else { return false }
        let leftParent = lhs.deletingLastPathComponent()
        let rightParent = rhs.deletingLastPathComponent()
        guard samePath(leftParent, rightParent) else { return false }
        return namesEqual(lhs.lastPathComponent, rhs.lastPathComponent, in: leftParent)
    }

    static func namesEqual(_ lhs: String, _ rhs: String, in directory: URL) -> Bool {
        lhs == rhs || (lhs.caseInsensitiveCompare(rhs) == .orderedSame
                      && caseSensitiveNames(in: directory) == false)
    }

    static func caseSensitiveNames(in directory: URL) -> Bool? {
        var ancestor = directory
        while true {
            if let value = try? ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let sensitive = value.volumeSupportsCaseSensitiveNames { return sensitive }
            guard ancestor.pathComponents.count > 1 else { return nil }
            ancestor.deleteLastPathComponent()
        }
    }

    /// Foundation's resolvingSymlinksInPath can return the UNRESOLVED input when
    /// the last component is missing. That is unsafe for writes through a symlink
    /// parent and for dangling symlinks. Walk components before appending a new tail.
    /// This is pathname validation, not a descriptor-based defense against a
    /// concurrent process replacing links between validation and the actual I/O.
    static func canonicalURL(_ url: URL) -> URL? {
        resolution(of: url)?.canonical
    }

    struct PathResolution: Sendable {
        let canonical: URL
        /// Full path at each hop, NOT just the final referent.
        let aliases: [URL]
        /// Prefix links are dependencies, not protected subtrees. For example
        /// /var -> /private/var must not make every file below /var read-only.
        let links: [URL]
    }

    static func resolution(of url: URL) -> PathResolution? {
        guard url.isFileURL, !url.path.contains("\0") else { return nil }
        var pending = Array(url.pathComponents.dropFirst())
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var aliases = [url.standardizedFileURL]
        var links: [URL] = []
        var linkCount = 0
        let fm = FileManager.default
        while !pending.isEmpty {
            guard !Task.isCancelled else { return nil }
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                resolved.deleteLastPathComponent()
                continue
            }
            let next = resolved.appendingPathComponent(component)
            guard let metadata = metadata(of: next) else { return nil }
            if metadata.kind == .missing {
                // ENOENT/ENOTDIR is a verified absent tail, including a
                // dangling symlink destination. Preserve the future pathname
                // so its known alias remains protected on a later write.
                guard !pending.contains("..") else { return nil }
                let canonical = pending.reduce(next) { $0.appendingPathComponent($1) }
                aliases.append(canonical)
                return PathResolution(canonical: canonical, aliases: aliases, links: links)
            }
            if metadata.kind == .link {
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: next.path),
                      !destination.isEmpty else { return nil }
                linkCount += 1
                guard linkCount <= 40, !destination.contains("\0") else { return nil }
                links.append(next)
                // Preserve the complete target at each hop, never a bare prefix
                // such as /var. Link-node dependencies are tracked separately.
                aliases.append(pending.reduce(next) { $0.appendingPathComponent($1) })
                if destination.hasPrefix("/") {
                    resolved = URL(fileURLWithPath: "/", isDirectory: true)
                } else {
                    resolved = next.deletingLastPathComponent()
                }
                pending = destination.split(separator: "/").map(String.init) + pending
            } else {
                resolved = next
            }
        }
        aliases.append(resolved)
        return PathResolution(canonical: resolved, aliases: aliases, links: links)
    }

    enum NodeKind: Sendable, Equatable { case missing, directory, link, leaf }

    /// Fresh lstat metadata, never URLResourceValues' cached attributes. ctime is
    /// needed even if a caller restores mtime; identity detects directory replacement.
    struct Metadata: Equatable, Sendable {
        let identity: FileIdentity?
        let kind: NodeKind
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    static func metadata(of url: URL) -> Metadata? {
        guard url.isFileURL, !url.path.contains("\0") else { return nil }
        var info = stat()
        let status = url.path.withCString { fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            // ENOTDIR is also a known unreachable tail (e.g. a file occupying a
            // reserved directory name). Permissions, ELOOP and I/O errors are unknown.
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            return Metadata(identity: nil, kind: .missing, mode: 0,
                            modifiedSeconds: 0, modifiedNanoseconds: 0,
                            changedSeconds: 0, changedNanoseconds: 0)
        }
        let kind: NodeKind
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .link
        default: kind = .leaf
        }
        return Metadata(
            identity: FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino)),
            kind: kind, mode: UInt16(info.st_mode),
            modifiedSeconds: Int(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            changedSeconds: Int(info.st_ctimespec.tv_sec), changedNanoseconds: Int(info.st_ctimespec.tv_nsec)
        )
    }
}

/// Shared metadata alias index. A cold/changed directory is enumerated once; warm
/// calls revalidate its identity + nanosecond mtime/ctime and reuse only directory
/// and symlink names. Ordinary snapshots/tombstones never need canonical resolution
/// and never consume the topology budget. No file contents are read here.
///
/// Every caller walks all retained directories and resolves every retained symlink
/// afresh, including external backing paths. Thus changes below a nested directory,
/// replacement of an external link, and a previously dangling target becoming a
/// directory are observed without requiring the repository root's mtime to change.
/// This assumes normal local-filesystem metadata semantics, not hostile native
/// timestamp manipulation / concurrent TOCTOU / global hard-link discovery.
enum MetadataAliasDirectoryCache {
    struct Child: Sendable {
        let name: String
        let kind: SandboxPathResolver.NodeKind
    }

    struct Listing: Sendable {
        let metadata: SandboxPathResolver.Metadata
        let children: [Child]
    }

    private struct Key: Hashable, Sendable {
        let path: String
        let includeLeaves: Bool
    }

    private static let cache = Locked<[Key: Listing]>(wrappedValue: [:])

    /// `directory` has already been resolved by the caller. includeLeaves is only
    /// for shallow discovery of dynamic names (e.g. diagnostic exports in tmp).
    /// nil means UNKNOWN, never "no aliases". Failed/partial scans are not cached.
    static func listing(
        of directory: URL, includeLeaves: Bool = false
    ) -> (listing: Listing, enumeratedEntries: Int)? {
        guard !Task.isCancelled, let before = SandboxPathResolver.metadata(of: directory) else { return nil }
        guard before.kind != .link else { return nil }
        if before.kind != .directory {
            return (Listing(metadata: before, children: []), 0)
        }
        let key = Key(path: directory.path, includeLeaves: includeLeaves)
        if let saved = cache.wrappedValue[key], saved.metadata == before {
            return (saved, 0)
        }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in failed = true; return false }
        ) else { return nil }
        var children: [Child] = []
        var count = 0
        for case let child as URL in enumerator {
            guard !Task.isCancelled, let metadata = SandboxPathResolver.metadata(of: child),
                  metadata.kind != .missing else { return nil }
            count += 1
            if includeLeaves || metadata.kind == .directory || metadata.kind == .link {
                children.append(Child(name: child.lastPathComponent, kind: metadata.kind))
            }
        }
        guard !failed, SandboxPathResolver.metadata(of: directory) == before else { return nil }
        let result = Listing(metadata: before, children: children)
        cache.mutate {
            // Eviction only costs a rescan; it must NEVER relax protection or make
            // cache capacity an access-denial threshold.
            if $0.count >= 512 { $0.removeAll(keepingCapacity: true) }
            $0[key] = result
        }
        return (result, count)
    }
}
