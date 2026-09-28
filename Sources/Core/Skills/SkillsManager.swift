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
    private var cachedSkills: [String: Skill]?

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

    /// List all available skills (name + description only, for token efficiency).
    public func listSkills(category: String? = nil) -> [Skill] {
        let all = loadAllSkills()
        if let category {
            return StableSort.byName(all.values.filter { $0.category == category }) { $0.name }
        }
        return StableSort.byName(Array(all.values)) { $0.name }
    }

    /// Load a skill's full content by name.
    public func skill(named name: String) -> Skill? {
        loadAllSkills()[name]
    }

    /// Get a linked file's content within a skill.
    public func linkedFile(skillName: String, filePath: String) -> String? {
        guard let skill = loadAllSkills()[skillName] else { return nil }
        return skill.linkedFiles[filePath]
    }

    /// Invalidate the cache (e.g., after skill_manage creates/edits a skill).
    public func invalidateCache() {
        cachedSkills = nil
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
        cachedSkills = nil
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
            throw AIAgentError.toolExecutionFailed(toolName: "skill_manage", underlying:
                NSError(domain: "SkillsManager", code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Skill '\(name)' not found in user skills"]))
        }
        _ = try validatedMutationTarget(skillDir)
        // A category or a redirected directory is not a deletable skill.
        guard fm.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path) else {
            throw mutationError("Target is not a user skill.")
        }
        try fm.removeItem(at: skillDir)
        cachedSkills = nil
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

    private func loadAllSkills() -> [String: Skill] {
        if let cached = cachedSkills { return cached }

        var skills: [String: Skill] = [:]

        // Load bundled skills
        if let bundled = bundledSkillsURL {
            loadSkillsFrom(directory: bundled, into: &skills)
        }

        // Load user skills (override bundled with same name)
        loadSkillsFrom(directory: userSkillsURL, into: &skills)

        cachedSkills = skills
        return skills
    }

    private func loadSkillsFrom(directory: URL, into skills: inout [String: Skill]) {
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
                if let skill = parseSkillFile(at: skillFile, dirName: item.lastPathComponent, category: nil) {
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
                            if let skill = parseSkillFile(at: subSkillFile, dirName: subItem.lastPathComponent,
                                                          category: item.lastPathComponent) {
                                skills[skill.name] = skill
                            }
                        }
                    }
                }
            }
        }
    }

    private func parseSkillFile(at url: URL, dirName: String, category: String?) -> Skill? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // Parse YAML frontmatter
        var name = dirName
        var description = ""
        var skillCategory = category
        var body = raw

        if raw.hasPrefix("---") {
            let parts = raw.components(separatedBy: "---")
            if parts.count >= 3 {
                let frontmatter = parts[1]
                body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

                for line in frontmatter.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name:") {
                        name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("description:") {
                        description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("category:") {
                        skillCategory = trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // Load linked files (references/, templates/, scripts/, assets/)
        var linkedFiles: [String: String] = [:]
        let skillDir = url.deletingLastPathComponent()
        let fm = FileManager.default
        for subdir in ["references", "templates", "scripts", "assets"] {
            let subdirURL = skillDir.appendingPathComponent(subdir)
            if let files = try? fm.contentsOfDirectory(at: subdirURL, includingPropertiesForKeys: nil) {
                for file in files {
                    if let content = try? String(contentsOf: file, encoding: .utf8) {
                        let relativePath = "\(subdir)/\(file.lastPathComponent)"
                        linkedFiles[relativePath] = content
                    }
                }
            }
        }

        return Skill(name: name, description: description, category: skillCategory,
                      content: body, linkedFiles: linkedFiles)
    }
}
