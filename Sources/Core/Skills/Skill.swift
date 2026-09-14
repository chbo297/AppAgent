//
//  Skill.swift
//  AppAgent
//

import Foundation

/// A skill definition loaded from a SKILL.md file.
///
/// Skills are markdown-based instruction documents that teach the agent
/// how to handle specific task types. Reference: hermes-agent skills system.
public struct Skill: Sendable {
    /// Unique skill name (directory name).
    public let name: String
    /// Short description from frontmatter.
    public let description: String
    /// Optional category for grouping.
    public let category: String?
    /// Full SKILL.md content (markdown body).
    public let content: String
    /// Linked files: references/, templates/, scripts/, assets/.
    public let linkedFiles: [String: String]

    public init(name: String, description: String, category: String? = nil,
                content: String, linkedFiles: [String: String] = [:]) {
        self.name = name
        self.description = description
        self.category = category
        self.content = content
        self.linkedFiles = linkedFiles
    }
}
