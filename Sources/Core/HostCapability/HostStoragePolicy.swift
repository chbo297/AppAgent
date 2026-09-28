import Foundation

/// Storage ownership, independent of authorization. Evaluate only after obtaining the
/// immutable per-call HostInspectionContext. No directory contents or defaults values
/// should be collected for output until this policy has accepted their names.
struct HostStoragePolicy: Sendable {
    enum Operation: String {
        case list, read, write, delete
        var isMutation: Bool { self == .write || self == .delete }
    }

    static let deniedMessage = "Storage target is not available in this scope."
    static let preferencesMessage =
        "Shared preferences require approved scope 'all'; use app_user_defaults for scoped key access."

    static let unverifiedMessage = "Storage scope could not be verified; access denied."

    let root: URL
    private let namespaces: [Namespace]
    private let namespaceLinks: Set<URL>
    private let names: PathNames
    private let indexComplete: Bool
    // Internal diagnostics for tests; never include these counts in tool output.
    let scannedEntryCount: Int
    let enumeratedEntryCount: Int

    /// One verified metadata topology snapshot per invocation, reused by every
    /// list entry. Ordinary files are enumerated for discovery but do not consume
    /// the topology budget.
    init(root: URL, scanBudget: Int = 4096) {
        self.root = root.standardizedFileURL
        self.names = PathNames(root: self.root)
        var index = AliasIndex(root: self.root, budget: max(0, scanBudget))
        index.build()
        self.namespaces = index.namespaces
        self.namespaceLinks = index.links
        self.indexComplete = index.complete
        self.scannedEntryCount = index.visitedEntries
        self.enumeratedEntryCount = index.enumeratedEntries
    }

    // Settings, input-bar layout and the host message-capture contract all live here.
    // Reserve the namespaces, not just today's keys, so a newly introduced key is safe.
    static func isAppAgentDefaultsKey(_ key: String) -> Bool {
        ["com.appagent", "appagent"].contains {
            key == $0 || key.hasPrefix($0 + ".")
        }
    }

    static func allows(defaultsKey: String, scope: HostInspectionScope) -> Bool {
        scope.includes(appAgentOwned: isAppAgentDefaultsKey(defaultsKey))
    }

    /// Called with a sandbox-contained logical URL AND its canonical target.
    /// Fail closed when an alias crosses ownership, even if one name is allowed.
    func denial(
        logical: URL, resolved: URL, scope: HostInspectionScope, operation: Operation
    ) -> String? {
        let resolver = SandboxPathResolver(sandboxRoot: root)
        guard let logicalName = resolver.relativePath(of: logical),
              let resolvedName = resolver.relativePath(of: resolved) else {
            return Self.deniedMessage
        }
        guard indexComplete else { return Self.unverifiedMessage }
        guard let resolution = SandboxPathResolver.resolution(of: logical) else {
            return Self.unverifiedMessage
        }
        let targetAliases = resolution.aliases + [resolved.standardizedFileURL]
        var pathNames = [logicalName, resolvedName]
        for target in targetAliases {
            if let name = resolver.relativePath(of: target) { pathNames.append(name) }
            for namespace in namespaces where SandboxPathResolver.contains(target, in: namespace.resolved) {
                let suffix = target.pathComponents.dropFirst(namespace.resolved.pathComponents.count)
                pathNames.append(([namespace.name] + suffix).joined(separator: "/"))
            }
        }
        // Broad shared ancestors are navigation-only, even with scope=all.
        if operation.isMutation {
            let containsNamespace = namespaces.contains { namespace in
                targetAliases.contains {
                    !SandboxPathResolver.samePath(namespace.resolved, $0)
                        && SandboxPathResolver.contains(namespace.resolved, in: $0)
                }
            }
            let containsLink = namespaceLinks.contains { link in
                targetAliases.contains {
                    !SandboxPathResolver.samePath(link, $0)
                        && SandboxPathResolver.contains(link, in: $0)
                }
            }
            if pathNames.contains(where: names.isSharedAncestor) || containsNamespace || containsLink {
                return Self.deniedMessage
            }
        }
        if scope != .all, pathNames.contains(where: { names.isWithin($0, "Library/Preferences") }) {
            return Self.preferencesMessage
        }
        for name in pathNames {
            if scope == .all { continue }
            if operation == .list, names.isNavigationAncestor(name, scope: scope) {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory),
                      directory.boolValue else { return Self.deniedMessage }
                continue
            }
            guard scope.includes(appAgentOwned: names.isAppAgentPath(name)) else {
                return Self.deniedMessage
            }
            // AppAgent itself is a mixed container: never treat it as an SDK file.
            if names.equals(name, "Documents/AppAgent") { return Self.deniedMessage }
        }
        if operation.isMutation {
            return SessionRepositoryProtection.mutationDenial(
                logical: logical, resolved: resolved, sandboxRoot: root
            )
        }
        return nil
    }

    private struct Namespace: Sendable {
        let name: String
        let resolved: URL
    }

    /// Logical ownership must respect the filesystem too. Unconditional lowercasing
    /// would reserve unrelated `documents/appagent` paths on a case-sensitive disk.
    private struct PathNames: Sendable {
        let root: URL

        func isWithin(_ path: String, _ directory: String) -> Bool {
            let components = path.split(separator: "/").map(String.init)
            let prefix = directory.split(separator: "/").map(String.init)
            guard components.count >= prefix.count else { return false }
            var parent = root
            for (actual, expected) in zip(components, prefix) {
                guard SandboxPathResolver.namesEqual(actual, expected, in: parent) else { return false }
                parent.appendPathComponent(actual)
            }
            return true
        }

        func equals(_ path: String, _ other: String) -> Bool {
            path.split(separator: "/").count == other.split(separator: "/").count && isWithin(path, other)
        }

        func isAppAgentPath(_ path: String) -> Bool {
            if isWithin(path, "Documents/AppAgent") {
                return !isWithin(path, "Documents/AppAgent/files")
            }
            if isWithin(path, "Library/Caches/AppAgentMsgCapture")
                || isWithin(path, "Caches/AppAgentMsgCapture") { return true }
            for temporary in ["tmp", "temp"] where isWithin(path, temporary) {
                let parts = path.split(separator: "/")
                guard parts.count > 1 else { continue }
                let parent = root.appendingPathComponent(String(parts[0]))
                let child = String(parts[1])
                if isDiagnostic(child, in: parent) { return true }
                if ["appagent-debug.log", "appagent-debug.json", "AppAgentMsgCapture", "AppAgent"]
                    .contains(where: { SandboxPathResolver.namesEqual(child, $0, in: parent) }) { return true }
            }
            return false
        }

        func isDiagnostic(_ child: String, in parent: URL) -> Bool {
            let prefix = "appagent-diagnostics-"
            guard child.count >= prefix.count else { return false }
            return SandboxPathResolver.namesEqual(String(child.prefix(prefix.count)), prefix, in: parent)
        }

        func isSharedAncestor(_ path: String) -> Bool {
            ["", "Documents", "Documents/AppAgent", "Library", "Library/Caches",
             "Library/Preferences", "Caches", "tmp", "temp"].contains { equals(path, $0) }
        }

        func isNavigationAncestor(_ path: String, scope: HostInspectionScope) -> Bool {
            if scope == .host { return equals(path, "Documents/AppAgent") }
            return scope == .appagent && isSharedAncestor(path) && !equals(path, "Library/Preferences")
        }
    }

    /// A metadata-only traversal, never a whole-sandbox content scan. The shared
    /// directory cache only retains directory/link topology. Plain snapshots and
    /// tombstones are inspected for existence but do not consume the topology
    /// budget, so a repository with 4097 ordinary files remains usable.
    private struct AliasIndex {
        let root: URL
        let budget: Int
        var namespaces: [Namespace] = []
        var links: Set<URL> = []
        var complete = true
        var visitedEntries = 0
        var enumeratedEntries = 0
        private var visitedDirectories: Set<DirectoryKey> = []
        private var pending: [(name: String, mode: Mode)] = []

        private enum Mode: Hashable { case sdk, preferences, appAgentTree }
        private struct DirectoryKey: Hashable {
            let identity: SandboxPathResolver.FileIdentity
            let mode: Mode
        }

        init(root: URL, budget: Int) {
            self.root = root
            self.budget = budget
        }

        mutating func build() {
            guard budget > 0, !Task.isCancelled else {
                complete = false
                return
            }
            let fixed = [
                "Documents", "Documents/AppAgent", "Documents/AppAgent/sessions",
                "Documents/AppAgent/memory", "Documents/AppAgent/logs", "Documents/AppAgent/skills",
                "Library", "Library/Preferences", "Library/Caches", "Library/Caches/AppAgentMsgCapture",
                "Caches", "Caches/AppAgentMsgCapture", "tmp", "temp",
                "tmp/AppAgent", "tmp/AppAgentMsgCapture", "temp/AppAgent", "temp/AppAgentMsgCapture",
                "tmp/appagent-debug.log", "tmp/appagent-debug.json",
                "temp/appagent-debug.log", "temp/appagent-debug.json"
            ]
            for name in fixed { addNamespace(name) }
            pending = [
                ("Documents/AppAgent", .appAgentTree), ("Library/Preferences", .preferences),
                ("Library/Caches/AppAgentMsgCapture", .sdk), ("Caches/AppAgentMsgCapture", .sdk),
                ("tmp/AppAgent", .sdk), ("tmp/AppAgentMsgCapture", .sdk),
                ("temp/AppAgent", .sdk), ("temp/AppAgentMsgCapture", .sdk)
            ]
            // Dynamic diagnostic file and staging-directory names are not fixed roots.
            for temporary in ["tmp", "temp"] {
                let parent = root.appendingPathComponent(temporary)
                guard let canonical = SandboxPathResolver.canonicalURL(parent),
                      let listing = MetadataAliasDirectoryCache.listing(of: canonical, includeLeaves: true)
                else { complete = false; break }
                enumeratedEntries += listing.enumeratedEntries
                for child in listing.listing.children {
                    guard PathNames(root: root).isDiagnostic(child.name, in: parent) else { continue }
                    addNamespace(temporary + "/" + child.name)
                    if child.kind == .link, !consumeTopology() { break }
                    pending.append((temporary + "/" + child.name, .sdk))
                }
            }
            while complete, let item = pending.popLast() {
                guard !Task.isCancelled,
                      let resolution = SandboxPathResolver.resolution(
                        of: root.appendingPathComponent(item.name)
                      ) else {
                    complete = false
                    break
                }
                let resolved = resolution.canonical
                guard let metadata = SandboxPathResolver.metadata(of: resolved) else {
                    complete = false
                    break
                }
                guard metadata.kind != .link else { complete = false; break }
                guard metadata.kind == .directory else {
                    // Known absent destinations remain indexed as future paths.
                    // Regular file links do not require a directory traversal.
                    continue
                }
                guard let identity = metadata.identity else { complete = false; break }
                let key = DirectoryKey(identity: identity, mode: item.mode)
                guard visitedDirectories.insert(key).inserted else { continue }
                guard consumeTopology() else { break }
                guard let listing = MetadataAliasDirectoryCache.listing(of: resolved) else {
                    complete = false
                    break
                }
                enumeratedEntries += listing.enumeratedEntries
                for child in listing.listing.children {
                    let name = item.name + "/" + child.name
                    if item.mode == .appAgentTree,
                       PathNames(root: root).isWithin(name, "Documents/AppAgent/files") { continue }
                    if child.kind == .link {
                        guard consumeTopology() else { break }
                        addNamespace(name)
                    }
                    pending.append((name, item.mode))
                }
            }
        }

        private mutating func addNamespace(_ name: String) {
            guard let resolution = SandboxPathResolver.resolution(of: root.appendingPathComponent(name)) else {
                complete = false
                return
            }
            namespaces.append(contentsOf: resolution.aliases.map {
                Namespace(name: name, resolved: $0)
            })
            links.formUnion(resolution.links)
        }

        private mutating func consumeTopology() -> Bool {
            guard visitedEntries < budget, !Task.isCancelled else {
                complete = false
                return false
            }
            visitedEntries += 1
            return true
        }

    }
}
