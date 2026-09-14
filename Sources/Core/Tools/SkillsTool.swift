//
//  SkillsTool.swift
//  AppAgent
//

import Foundation

// MARK: - SkillsListTool

/// Lists available skills (name + description only, for token efficiency).
///
/// Reference: hermes-agent `skills_list` tool (progressive disclosure Tier 1).
public struct SkillsListTool: ToolProtocol {
    public let name = "skills_list"
    public let description = """
        List available skills (name + description). \
        Use skill_view(name) to load a skill's full content.
        """
    public let parameters = Tool.Schema(
        properties: [
            "category": .string(description: "Optional category filter to narrow results.")
        ],
        required: []
    )
    public let group: String = "skills"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let manager: SkillsManager

    public init(manager: SkillsManager) {
        self.manager = manager
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let category = arguments["category"]?.stringValue
        let skills = await manager.listSkills(category: category)

        if skills.isEmpty {
            return .json(.object([
                "skills": .array([]),
                "message": .string(category != nil
                    ? "No skills found in category '\(category!)'."
                    : "No skills available.")
            ]))
        }

        let items: [JSONValue] = skills.map { skill in
            var obj: [String: JSONValue] = [
                "name": .string(skill.name),
                "description": .string(skill.description)
            ]
            if let cat = skill.category {
                obj["category"] = .string(cat)
            }
            return .object(obj)
        }

        return .json(.object([
            "skills": .array(items),
            "count": .number(Double(items.count))
        ]))
    }
}

// MARK: - SkillViewTool

/// Loads a skill's full SKILL.md content or a linked file.
///
/// Reference: hermes-agent `skill_view` tool (progressive disclosure Tier 2-3).
public struct SkillViewTool: ToolProtocol {
    public let name = "skill_view"
    public let description = """
        Load a skill's full content or access its linked files (references, templates, scripts). \
        First call returns SKILL.md content plus a list of linked files. \
        To access linked files, call again with file_path.
        """
    public let parameters = Tool.Schema(
        properties: [
            "name": .string(description: "The skill name."),
            "file_path": .string(
                description: "Optional: path to a linked file (e.g., 'references/api.md'). Omit to get the main SKILL.md."
            )
        ],
        required: ["name"]
    )
    public let group: String = "skills"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let manager: SkillsManager

    public init(manager: SkillsManager) {
        self.manager = manager
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let skillName = arguments["name"]?.stringValue, !skillName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        guard let skill = await manager.skill(named: skillName) else {
            return .error("Skill '\(skillName)' not found. Use skills_list to see available skills.")
        }

        // If file_path is provided, return that linked file
        if let filePath = arguments["file_path"]?.stringValue, !filePath.isEmpty {
            if let fileContent = skill.linkedFiles[filePath] {
                return .json(.object([
                    "skill": .string(skillName),
                    "file_path": .string(filePath),
                    "content": .string(fileContent)
                ]))
            } else {
                let available = skill.linkedFiles.keys.sorted()
                return .error("File '\(filePath)' not found in skill '\(skillName)'. Available: \(available.joined(separator: ", "))")
            }
        }

        // Return full skill content + linked file list
        var result: [String: JSONValue] = [
            "name": .string(skill.name),
            "description": .string(skill.description),
            "content": .string(skill.content)
        ]
        if let cat = skill.category {
            result["category"] = .string(cat)
        }
        if !skill.linkedFiles.isEmpty {
            result["linked_files"] = .array(skill.linkedFiles.keys.sorted().map { .string($0) })
        }

        return .json(.object(result))
    }
}

// MARK: - SkillManageTool

/// Manages skills — create, edit, delete.
///
/// Reference: hermes-agent `skill_manage` tool.
public struct SkillManageTool: ToolProtocol {
    public let name = "skill_manage"
    public let description = """
        Manage skills (create, delete). Skills are reusable instruction documents for recurring task types. \
        Create when: complex task succeeded, non-trivial workflow discovered, or user asks to remember a procedure. \
        Confirm with user before creating or deleting.
        """
    public let parameters = Tool.Schema(
        properties: [
            "action": .string(
                description: "The action to perform.",
                enumValues: ["create", "delete"]
            ),
            "name": .string(
                description: "Skill name (lowercase, hyphens allowed, max 64 chars)."
            ),
            "content": .string(
                description: "Full SKILL.md content (YAML frontmatter + markdown body). Required for 'create'."
            ),
            "category": .string(
                description: "Optional category for organizing (e.g., 'devops', 'data-science'). Only for 'create'."
            )
        ],
        required: ["action", "name"]
    )
    public let group: String = "skills"
    public let safetyLevel: Tool.SafetyLevel = .sensitive

    private let manager: SkillsManager

    public init(manager: SkillsManager) {
        self.manager = manager
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let action = arguments["action"]?.stringValue else {
            return .error("Missing required parameter: action")
        }
        guard let skillName = arguments["name"]?.stringValue, !skillName.isEmpty else {
            return .error("Missing required parameter: name")
        }

        switch action {
        case "create":
            guard let content = arguments["content"]?.stringValue, !content.isEmpty else {
                return .error("Missing required parameter: content (for action 'create')")
            }
            let category = arguments["category"]?.stringValue
            try await manager.createSkill(name: skillName, content: content, category: category)
            return .json(.object([
                "success": .bool(true),
                "message": .string("Skill '\(skillName)' created successfully.")
            ]))

        case "delete":
            try await manager.deleteSkill(name: skillName)
            return .json(.object([
                "success": .bool(true),
                "message": .string("Skill '\(skillName)' deleted.")
            ]))

        default:
            return .error("Unknown action: '\(action)'. Use 'create' or 'delete'.")
        }
    }
}
