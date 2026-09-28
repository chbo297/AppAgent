import Foundation

/// Model-facing file writers must not bypass recoverable session management.
/// This is a pathname policy, not an isolation boundary against trusted native
/// host code or concurrent filesystem replacement. SessionStorage itself does
/// not use this guard: only its manual-UI purge API may permanently remove data.
enum SessionRepositoryProtection {
    static let deniedMessage =
        "Session repositories are read-only to file tools. Use session_manage to archive or restore; permanent deletion requires the user's Trash UI."
    static let unverifiedMessage = "Session repository protection could not be verified; write denied."

    // Keep the original registration forever. In addition, retain paths observed
    // at registration time: a replaced symlink must not make its old backing path
    // writable, while the original root is re-resolved on every check.
    private struct Registration {
        var roots: Set<URL> = []
        var paths: Set<URL> = []
        var links: Set<URL> = []
    }
    private static let registration = Locked<Registration>(wrappedValue: Registration())

    static func register(directory: URL) {
        let root = directory.standardizedFileURL
        let resolution = SandboxPathResolver.resolution(of: root)
        registration.mutate {
            $0.roots.insert(root)
            $0.paths.insert(root)
            if let resolution {
                $0.paths.formUnion(resolution.aliases)
                $0.paths.insert(resolution.canonical)
                $0.links.formUnion(resolution.links)
            }
        }
    }

    static func mutationDenial(
        logical: URL, resolved: URL, sandboxRoot: URL? = nil, scanBudget: Int = 4096
    ) -> String? {
        // Zero is intentionally an explicit fail-closed mode used by callers
        // that cannot permit any metadata traversal.
        guard scanBudget > 0, !Task.isCancelled else { return unverifiedMessage }

        let saved = registration.wrappedValue
        var roots = saved.roots.union(saved.paths)
        var protected = saved.paths
        var protectedLinks = saved.links
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.insert(documents.appendingPathComponent("AppAgent/sessions", isDirectory: true))
        }
        if let sandboxRoot {
            roots.insert(sandboxRoot.appendingPathComponent("Documents/AppAgent/sessions", isDirectory: true))
        }

        guard let logicalResolution = SandboxPathResolver.resolution(of: logical),
              let resolvedResolution = SandboxPathResolver.resolution(of: resolved) else {
            return unverifiedMessage
        }
        let targets = logicalResolution.aliases + resolvedResolution.aliases

        func overlapsTarget(_ protectedPath: URL) -> Bool {
            targets.contains {
                SandboxPathResolver.contains($0, in: protectedPath)
                    || SandboxPathResolver.contains(protectedPath, in: $0)
            }
        }

        func isProtectedTarget() -> Bool {
            protected.contains(where: overlapsTarget)
        }

        // Re-resolve registered roots so dynamic replacement is noticed. Keep
        // historical paths too: the old bytes remain repository-owned.
        var pending: [URL] = []
        for root in roots {
            guard let resolution = SandboxPathResolver.resolution(of: root) else {
                return unverifiedMessage
            }
            protected.formUnion(resolution.aliases)
            protected.insert(resolution.canonical)
            protectedLinks.formUnion(resolution.links)
            pending.append(resolution.canonical)
        }
        if isProtectedTarget() { return deniedMessage }

        var visitedDirectories: Set<SandboxPathResolver.FileIdentity> = []
        var topologyEntries = 0
        while let directory = pending.popLast() {
            guard !Task.isCancelled,
                  let metadata = SandboxPathResolver.metadata(of: directory) else {
                return unverifiedMessage
            }
            guard metadata.kind == .directory else {
                if metadata.kind == .link { return unverifiedMessage }
                continue
            }
            guard let identity = metadata.identity else { return unverifiedMessage }
            guard visitedDirectories.insert(identity).inserted else { continue }
            guard topologyEntries < scanBudget else { return unverifiedMessage }
            topologyEntries += 1
            guard let listing = MetadataAliasDirectoryCache.listing(of: directory) else {
                return unverifiedMessage
            }

            // Ordinary snapshots and tombstones are deliberately not resolved
            // one by one. Only directory/link topology is retained and budgeted.
            for child in listing.listing.children {
                guard !Task.isCancelled else { return unverifiedMessage }
                let childURL = directory.appendingPathComponent(child.name)
                if child.kind == .link {
                    guard topologyEntries < scanBudget else { return unverifiedMessage }
                    topologyEntries += 1
                }
                guard let childResolution = SandboxPathResolver.resolution(of: childURL) else {
                    // Any unreadable topology is unknown, not just a bad link.
                    return unverifiedMessage
                }
                protected.formUnion(childResolution.aliases)
                protected.insert(childResolution.canonical)
                protectedLinks.formUnion(childResolution.links)
                if isProtectedTarget() { return deniedMessage }

                guard let canonicalMetadata = SandboxPathResolver.metadata(of: childResolution.canonical),
                      canonicalMetadata.kind != .link else {
                    return unverifiedMessage
                }
                if canonicalMetadata.kind == .directory {
                    pending.append(childResolution.canonical)
                }
            }
        }

        // Keep the historical link set live in the check. This catches deletion
        // of an intermediate alias even when its directory was just replaced.
        if protectedLinks.contains(where: { link in
            targets.contains { SandboxPathResolver.contains(link, in: $0) }
        }) {
            return deniedMessage
        }
        return nil
    }
}
