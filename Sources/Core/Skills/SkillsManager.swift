//
//  SkillsManager.swift
//  AppAgent
//

import Foundation

/// Manages skill discovery, loading, and lifecycle.
///
/// Skills are stored as directories containing a SKILL.md file, either:
/// - Bundled in the app's Bundle (read-only, built-in)
/// - In App Documents/AppAgent/skills/ (user-created/managed)
///
/// The SKILL.md file uses YAML frontmatter for metadata:
/// ```
/// ---
/// name: my-skill
/// description: What this skill does
/// category: devops
/// ---
/// # Skill Content (markdown)
/// ...
/// ```
public actor SkillsManager {

    private let bundledSkillsURL: URL?
    private let userSkillsURL: URL
    private var cachedMetadata: [String: SkillMetadata]?

    /// Initialize with optional custom paths.
    public init(bundledSkillsURL: URL? = nil, userSkillsURL: URL? = nil) {
        self.bundledSkillsURL = bundledSkillsURL ?? Bundle.main.url(forResource: "Skills", withExtension: nil)
        if let userURL = userSkillsURL {
            self.userSkillsURL = userURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.userSkillsURL = docs.appendingPathComponent("AppAgent/skills")
        }
    }

    /// List metadata only. Bodies and linked resources are never loaded here.
    public func listSkills(category: String? = nil) -> [SkillMetadata] {
        let all = loadMetadata()
        if let category {
            // `catalog` groups skills without a category under "uncategorized"; that name must list them.
            let includesUncategorized = category == "uncategorized"
            return StableSort.byName(all.values.filter {
                $0.category == category || (includesUncategorized && $0.category == nil)
            }) { $0.name }
        }
        return StableSort.byName(Array(all.values)) { $0.name }
    }

    /// Load a skill's full content by name.
    public func skill(named name: String) -> Skill? {
        guard let metadata = loadMetadata()[name] else {
            return nil
        }
        return loadSkill(named: name, metadata: metadata)
    }

    /// Get a linked file's content within a skill.
    public func linkedFile(skillName: String, filePath: String) -> String? {
        guard let metadata = loadMetadata()[skillName],
              metadata.linkedFiles.contains(filePath),
              let url = skillURL(named: skillName, metadata: metadata)?
                .appendingPathComponent(filePath) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Invalidate the metadata cache after a skill changes.
    public func invalidateCache() {
        cachedMetadata = nil
    }

    // MARK: - Skill Management

    /// Create a new user skill.
    public func createSkill(name: String, content: String, category: String? = nil) throws {
        try validateComponent(name)
        if let category { try validateComponent(category) }
        let skillDir: URL
        if let category {
            skillDir = userSkillsURL.appendingPathComponent(category).appendingPathComponent(name)
        } else {
            skillDir = userSkillsURL.appendingPathComponent(name)
        }

        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        _ = try validatedMutationTarget(skillFile)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let destination = try validatedMutationTarget(skillFile)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        cachedMetadata = nil
    }

    /// Delete a user skill.
    public func deleteSkill(name: String) throws {
        try validateComponent(name)
        // Only allow deleting from user skills directory
        let fm = FileManager.default
        let possiblePaths = try? fm.contentsOfDirectory(at: userSkillsURL, includingPropertiesForKeys: nil)
            .flatMap { url -> [URL] in
                if url.lastPathComponent == name {
                    return [url]
                }
                // Check inside category subdirectories
                let sub = url.appendingPathComponent(name)
                if fm.fileExists(atPath: sub.path) {
                    return [sub]
                }
                return []
            }

        guard let skillDir = possiblePaths?.first else {
            throw AIAgentError.toolExecutionFailed(toolName: "skill", underlying:
                NSError(domain: "SkillsManager", code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Skill '\(name)' not found in user skills"]))
        }
        _ = try validatedMutationTarget(skillDir)
        // A category or a redirected directory is not a deletable skill.
        guard fm.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path) else {
            throw mutationError("Target is not a user skill.")
        }
        try fm.removeItem(at: skillDir)
        cachedMetadata = nil
    }

    // MARK: - Private

    private func validateComponent(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"), !value.contains("\0") else {
            throw mutationError("Skill names and categories must be single path components.")
        }
    }

    private func validatedMutationTarget(_ logical: URL) throws -> URL {
        let resolver = SandboxPathResolver(sandboxRoot: userSkillsURL)
        guard let resolved = resolver.validatedURL(logical),
              !SandboxPathResolver.samePath(resolved, userSkillsURL) else {
            throw mutationError("Skill path escapes the user skills directory.")
        }
        if let denial = SessionRepositoryProtection.mutationDenial(logical: logical, resolved: resolved) {
            throw mutationError(denial)
        }
        return resolved
    }

    private func mutationError(_ message: String) -> NSError {
        NSError(domain: "SkillsManager", code: 403, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func loadMetadata() -> [String: SkillMetadata] {
        if let cached = cachedMetadata {
            return cached
        }

        var skills: [String: SkillMetadata] = [:]

        // Load bundled skills
        if let bundled = bundledSkillsURL {
            loadMetadataFrom(directory: bundled, into: &skills)
        }

        // Load user skills (override bundled with same name)
        loadMetadataFrom(directory: userSkillsURL, into: &skills)

        cachedMetadata = skills
        return skills
    }

    private func loadMetadataFrom(directory: URL, into skills: inout [String: SkillMetadata]) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let skillFile = item.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillFile.path) {
                // Direct skill directory
                if let skill = parseMetadata(
                    at: skillFile,
                    dirName: item.lastPathComponent,
                    category: nil
                ) {
                    skills[skill.name] = skill
                }
            } else {
                // Category subdirectory — scan inside
                if let subContents = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for subItem in subContents {
                        let subIsDir = (try? subItem.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        guard subIsDir else { continue }
                        let subSkillFile = subItem.appendingPathComponent("SKILL.md")
                        if fm.fileExists(atPath: subSkillFile.path) {
                            if let skill = parseMetadata(
                                at: subSkillFile,
                                dirName: subItem.lastPathComponent,
                                category: item.lastPathComponent
                            ) {
                                skills[skill.name] = skill
                            }
                        }
                    }
                }
            }
        }
    }

    private func parseMetadata(
        at url: URL,
        dirName: String,
        category: String?
    ) -> SkillMetadata? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var name = dirName
        var description = ""
        var skillCategory = category

        let lines = raw.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let closing = lines.indices.dropFirst().first(where: {
               lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
           }) {
            let frontmatter = lines[1..<closing]
            for line in frontmatter {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("name:") {
                    name = Self.metadataValue(trimmed.dropFirst(5))
                } else if trimmed.hasPrefix("description:") {
                    description = Self.metadataValue(trimmed.dropFirst(12))
                } else if trimmed.hasPrefix("category:") {
                    skillCategory = Self.metadataValue(trimmed.dropFirst(9))
                }
            }
        }

        return SkillMetadata(
            name: name,
            description: description,
            category: skillCategory,
            linkedFiles: linkedFilePaths(in: url.deletingLastPathComponent())
        )
    }

    private func loadSkill(named name: String, metadata: SkillMetadata) -> Skill? {
        guard let url = skillURL(named: name, metadata: metadata),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let lines = raw.components(separatedBy: "\n")
        let body: String
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let closing = lines.indices.dropFirst().first(where: {
               lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
           }) {
            body = lines.dropFirst(closing + 1)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = raw
        }
        var linkedFiles: [String: String] = [:]
        for path in metadata.linkedFiles {
            if let content = try? String(
                contentsOf: url.deletingLastPathComponent().appendingPathComponent(path),
                encoding: .utf8
            ) {
                linkedFiles[path] = content
            }
        }
        return Skill(
            name: metadata.name,
            description: metadata.description,
            category: metadata.category,
            content: body,
            linkedFiles: linkedFiles
        )
    }

    private func skillURL(named name: String, metadata: SkillMetadata) -> URL? {
        let roots = [userSkillsURL, bundledSkillsURL].compactMap { $0 }
        for root in roots {
            let direct = root.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            if let categories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for category in categories {
                    let candidate = category
                        .appendingPathComponent(name)
                        .appendingPathComponent("SKILL.md")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private func linkedFilePaths(in skillDirectory: URL) -> [String] {
        let fileManager = FileManager.default
        var result: [String] = []
        for directory in ["references", "templates", "scripts", "assets"] {
            let root = skillDirectory.appendingPathComponent(directory)
            guard let files = try? fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let file as URL in files {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let relative = relativePath(of: file, from: skillDirectory) else {
                    continue
                }
                result.append(relative)
            }
        }
        return result.sorted()
    }

    private func relativePath(of file: URL, from root: URL) -> String? {
        guard SandboxPathResolver.contains(file, in: root) else {
            return nil
        }
        return file.pathComponents
            .dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private static func metadataValue(_ raw: Substring) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.first == "\"", value.last == "\"" {
            return (try? JSONDecoder().decode(String.self, from: Data(value.utf8)))
                ?? String(value.dropFirst().dropLast())
        }
        if value.first == "'", value.last == "'" {
            return value.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
