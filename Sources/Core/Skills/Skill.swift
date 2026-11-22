//
//  Skill.swift
//  AppAgent
//

import Foundation

/// Metadata discovered without loading the skill body or linked resources.
public struct SkillMetadata: Sendable {
    public let name: String
    public let description: String
    public let category: String?
    public let linkedFiles: [String]

    public init(
        name: String,
        description: String,
        category: String? = nil,
        linkedFiles: [String] = []
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.linkedFiles = linkedFiles
    }
}

/// A fully loaded skill definition.
///
/// `SkillsManager.listSkills` returns `SkillMetadata`, so this type is only
/// created after the runtime explicitly selects one skill to load.
public struct Skill: Sendable {
    public let name: String
    public let description: String
    public let category: String?
    public let content: String
    public let linkedFiles: [String: String]

    public init(
        name: String,
        description: String,
        category: String? = nil,
        content: String,
        linkedFiles: [String: String] = [:]
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.content = content
        self.linkedFiles = linkedFiles
    }
}
