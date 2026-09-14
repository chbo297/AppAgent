//
//  TodoTool.swift
//  AppAgent
//

import Foundation

/// Tool that provides session-level task list management.
///
/// State is stored in `session.uiState` so the UI layer can observe changes.
/// Reference: hermes-agent `todo` tool.
public final class TodoTool: ToolProtocol {
    public let name = "todo"
    public let description = """
        Manage your task list for the current session. Use for complex tasks with 3+ steps \
        or when the user provides multiple tasks. \
        Call with no parameters to read the current list. \
        Provide 'todos' array to create/update items. \
        merge=false (default): replace the entire list. merge=true: update existing items by id, add new ones. \
        Each item: {id: string, content: string, status: pending|in_progress|completed|cancelled}. \
        Only ONE item in_progress at a time. Mark items completed immediately when done.
        """
    public let parameters = Tool.Schema(
        properties: [
            "todos": .array(
                description: "Task items to write. Omit to read current list.",
                items: .object(
                    properties: [
                        "id": .string(description: "Unique item identifier"),
                        "content": .string(description: "Task description"),
                        "status": .string(
                            description: "Current status",
                            enumValues: ["pending", "in_progress", "completed", "cancelled"]
                        )
                    ],
                    required: ["id", "content", "status"]
                )
            ),
            "merge": .boolean(
                description: "true: update existing items by id, add new ones. false (default): replace the entire list.",
                defaultValue: .bool(false)
            )
        ],
        required: []
    )
    public let group: String = "core"
    public let safetyLevel: Tool.SafetyLevel = .safe

    /// Internal todo storage key in SessionUIState.
    private static let stateKey = "todos"

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        // Read mode: no todos parameter
        guard let todosValue = arguments["todos"]?.arrayValue else {
            return currentListOutput(session: session)
        }

        let merge = arguments["merge"]?.boolValue ?? false
        let newItems = parseTodoItems(todosValue)

        if merge {
            // Merge: update existing by id, add new
            var current = loadTodos(session: session)
            for item in newItems {
                if let idx = current.firstIndex(where: { $0.id == item.id }) {
                    current[idx] = item
                } else {
                    current.append(item)
                }
            }
            saveTodos(current, session: session)
        } else {
            // Replace
            saveTodos(newItems, session: session)
        }

        return currentListOutput(session: session)
    }

    // MARK: - Private

    private func currentListOutput(session: AISession) -> Tool.Output {
        let todos = loadTodos(session: session)
        if todos.isEmpty {
            return .json(.object([
                "todos": .array([]),
                "message": .string("Task list is empty.")
            ]))
        }
        let items: [JSONValue] = todos.map { item in
            .object([
                "id": .string(item.id),
                "content": .string(item.content),
                "status": .string(item.status)
            ])
        }
        return .json(.object(["todos": .array(items)]))
    }

    private func loadTodos(session: AISession) -> [TodoItem] {
        (session.uiState.get(Self.stateKey) as [TodoItem]?) ?? []
    }

    private func saveTodos(_ items: [TodoItem], session: AISession) {
        session.uiState.set(Self.stateKey, value: items)
    }

    private func parseTodoItems(_ array: [JSONValue]) -> [TodoItem] {
        array.compactMap { value -> TodoItem? in
            guard let obj = value.objectValue,
                  let id = obj["id"]?.stringValue,
                  let content = obj["content"]?.stringValue,
                  let status = obj["status"]?.stringValue else {
                return nil
            }
            return TodoItem(id: id, content: content, status: status)
        }
    }
}

// MARK: - TodoItem

/// A single task item in the session's todo list.
public struct TodoItem: Sendable {
    public let id: String
    public let content: String
    public let status: String // pending, in_progress, completed, cancelled

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }
}
