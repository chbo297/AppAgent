//
//  SkillsTool.swift
//  AppAgent
//

import Foundation

// MARK: - SkillTool

/// Unified skill discovery, loading, and user-skill management tool.
///
/// The default operation is `catalog`, which only returns category summaries.
/// Models can progressively expand a category with `list`, load one skill with
/// `load`, and access linked resources with the same operation.
public struct SkillTool: ToolProtocol {
    public let name = "skill"
    public let description = """
        Discover and load AppAgent skills progressively. \
        Use op='catalog' for compact category summaries, op='list' to expand one category, \
        and op='load' to read one skill's SKILL.md or a linked resource. \
        Use op='create' or 'delete' only when managing user skills.
        """
    public let parameters = Tool.Schema(
        properties: [
            "op": .string(
                description: "Operation.",
                enumValues: ["catalog", "list", "load", "create", "delete"],
                defaultValue: .string("catalog")
            ),
            "category": .string(
                description: "Category to expand for op='list' or the category for op='create'."
            ),
            "name": .string(
                description: "Skill name for op='load', 'create', or 'delete'."
            ),
            "file_path": .string(
                description: "Optional linked resource path for op='load'."
            ),
            "content": .string(
                description: "Complete SKILL.md content for op='create'."
            )
        ],
        required: []
    )
    public let group: String = "skills"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let manager: SkillsManager

    public init(manager: SkillsManager) {
        self.manager = manager
    }

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        switch arguments["op"]?.stringValue ?? "catalog" {
        case "catalog", "list", "load":
            return .safe
        case "create", "delete":
            return .sensitive
        default:
            return .safe
        }
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let op = arguments["op"]?.stringValue ?? "catalog"

        switch op {
        case "catalog":
            return await catalog()
        case "list":
            return await list(category: arguments["category"]?.stringValue)
        case "load":
            return await load(
                name: arguments["name"]?.stringValue,
                filePath: arguments["file_path"]?.stringValue
            )
        case "create":
            return try await create(
                name: arguments["name"]?.stringValue,
                category: arguments["category"]?.stringValue,
                content: arguments["content"]?.stringValue
            )
        case "delete":
            return try await delete(name: arguments["name"]?.stringValue)
        default:
            return .error("Unknown op '\(op)'. Use catalog, list, load, create, or delete.")
        }
    }

    private func catalog() async -> Tool.Output {
        let skills = await manager.listSkills()
        var counts: [String: Int] = [:]
        for skill in skills {
            let category = skill.category ?? "uncategorized"
            counts[category, default: 0] += 1
        }

        let categories = counts.keys.sorted().map { category in
            JSONValue.object([
                "category": .string(category),
                "count": .number(Double(counts[category] ?? 0))
            ])
        }

        return .json(.object([
            "categories": .array(categories),
            "skill_count": .number(Double(skills.count)),
            "next": .string("Use op='list' with a category before loading a specific skill.")
        ]))
    }

    private func list(category: String?) async -> Tool.Output {
        let skills = await manager.listSkills(category: category)
        let items = skills.map { skill in
            var item: [String: JSONValue] = [
                "name": .string(skill.name),
                "description": .string(skill.description)
            ]
            if let category = skill.category {
                item["category"] = .string(category)
            }
            return JSONValue.object(item)
        }

        return .json(.object([
            "category": category.map(JSONValue.string) ?? .null,
            "skills": .array(items),
            "count": .number(Double(items.count))
        ]))
    }

    private func load(name: String?, filePath: String?) async -> Tool.Output {
        guard let name, !name.isEmpty else {
            return .error("Missing required parameter: name for op='load'.")
        }
        guard let skill = await manager.skill(named: name) else {
            return .error("Skill '\(name)' not found. Use op='catalog' or op='list' first.")
        }

        if let filePath, !filePath.isEmpty {
            guard let content = skill.linkedFiles[filePath] else {
                let available = skill.linkedFiles.keys.sorted().joined(separator: ", ")
                return .error("Linked file '\(filePath)' not found. Available: \(available)")
            }
            return .json(.object([
                "name": .string(skill.name),
                "file_path": .string(filePath),
                "content": .string(content)
            ]))
        }

        var result: [String: JSONValue] = [
            "name": .string(skill.name),
            "description": .string(skill.description),
            "content": .string(skill.content)
        ]
        if let category = skill.category {
            result["category"] = .string(category)
        }
        if !skill.linkedFiles.isEmpty {
            result["linked_files"] = .array(
                skill.linkedFiles.keys.sorted().map { JSONValue.string($0) }
            )
        }
        return .json(.object(result))
    }

    private func create(name: String?, category: String?, content: String?) async throws -> Tool.Output {
        guard let name, !name.isEmpty else {
            return .error("Missing required parameter: name for op='create'.")
        }
        guard let content, !content.isEmpty else {
            return .error("Missing required parameter: content for op='create'.")
        }
        try await manager.createSkill(name: name, content: content, category: category)
        return .json(.object([
            "success": .bool(true),
            "name": .string(name),
            "category": category.map(JSONValue.string) ?? .null
        ]))
    }

    private func delete(name: String?) async throws -> Tool.Output {
        guard let name, !name.isEmpty else {
            return .error("Missing required parameter: name for op='delete'.")
        }
        try await manager.deleteSkill(name: name)
        return .json(.object([
            "success": .bool(true),
            "name": .string(name)
        ]))
    }
}
