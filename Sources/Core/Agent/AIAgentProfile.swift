//
//  AIAgentProfile.swift
//  AppAgent
//

import Foundation

/// Profile for an AIAgent instance.
///
/// `promptBuilders` is the core output — all other properties (identity, toolPrompts, etc.)
/// feed into the system prompt assembly pipeline.
///
/// Two init paths:
/// - **Primary**: pass `promptBuilders` directly for full control.
/// - **Convenience**: pass `identity` + optional extras; identity is wrapped as `promptBuilders[0]`.
public struct AIAgentProfile: Sendable {

    // MARK: - Core

    /// Prompt builders — the core output of this profile.
    /// Evaluated during system prompt assembly. Each builder provides either
    /// static text or a dynamic closure. Results are appended in order.
    public var promptBuilders: [PromptBuilder]

    // MARK: - Identity (convenience access)

    /// Identity text extracted from the convenience init.
    /// Stored for logging/debugging; the actual prompt content lives in promptBuilders.
    public private(set) var identity: String

    // MARK: - Tool Prompts

    /// Per-tool usage instructions keyed by tool name.
    /// When a tool is available, its matching entry is automatically included
    /// in a "# Using your tools" section of the system prompt.
    public var toolPrompts: [String: String]

    // MARK: - Message Context

    /// Per-message context providers called at execution time for each user message.
    /// Entries from all providers are combined with framework built-in context entries
    /// (e.g., current time) and injected into the user message before sending to the LLM.
    /// Default: empty (only built-in context is injected).
    public var messageContextProviders: [any MessageContextProvider]

    // MARK: - Execution

    /// Maximum agent loop iterations (forwarded to AIAgentExecutor). Default: 10.
    public var maxIterations: Int

    /// Single tool execution timeout in seconds. Default: 60s.
    public var toolTimeout: TimeInterval

    // MARK: - Persistence

    /// Whether to auto-persist sessions after each completed agent run. Default: true.
    public var autoPersist: Bool

    // MARK: - Memory

    /// Memory system configuration.
    public var memoryConfig: MemoryConfig

    // MARK: - Built-in Tools

    /// Whether to register SDK built-in tools automatically (default: true).
    /// Set to false to fully customize the tool set.
    public var registerBuiltInTools: Bool

    /// Names of built-in tools to disable (e.g., ["clipboard", "haptic"]).
    public var disabledBuiltInTools: Set<String>

    /// Root directory for file tools (sandbox). Default: Documents/AppAgent/files/.
    public var sandboxRoot: URL?

    // MARK: - Built-in Tool Prompt Defaults

    /// SDK default tool usage prompts for built-in tools.
    /// Host-app `toolPrompts` with the same key will override these.
    public static let defaultBuiltInToolPrompts: [String: String] = [
        "memory": """
            Save durable information to persistent memory that survives across sessions.
            WHEN TO SAVE: user corrects you, shares preferences, you discover environment facts.
            PRIORITY: User preferences > environment facts > procedural knowledge.
            Do NOT save task progress or temporary state.
            """,
        "todo": """
            Manage your task list for the current session. Use for complex tasks with 3+ steps.
            Only ONE item in_progress at a time. Mark items completed immediately when done.
            """,
        "clarify": """
            Ask the user a question when you need clarification or feedback before proceeding.
            Do NOT use for simple yes/no — prefer making a reasonable default choice.
            """,
        "file_read": """
            Read files within the app sandbox. Use offset and limit for large files.
            Do NOT use for binary files — only text content.
            """,
        "file_write": """
            Write content to files within the app sandbox. Overwrites the entire file.
            Use with care — creates parent directories automatically.
            """,
        "skills_list": """
            List available skills (name + description only). Use skill_view(name) to load full content.
            Scan skills before replying — if one matches your task, load and follow it.
            """,
        "delegate_task": """
            Spawn a sub-agent for reasoning-heavy subtasks or tasks that would flood your context.
            Pass ALL relevant info via context — the sub-agent knows nothing about your conversation.
            """,
        "session_search": """
            Search past conversation sessions. Use proactively when the user says \
            'we did this before', 'remember when', or references past work.
            """,
        "session_manage": """
            Inspect and manage your own conversations. 'list' shows every session you own \
            (title, message count, status, which is current); 'read' pulls another session's \
            full history so you can recall what was discussed there; 'rename' gives a session \
            a clearer title; 'delete' removes one (never the current session). Use 'list'/'read' \
            when the user refers to another conversation, and 'rename' once a topic is clear.
            """,
        "app_navigate": """
            Navigate to pages within the app. Call with no arguments to list available routes first.
            """,
        "app_action": """
            Execute business actions within the app. Call with no arguments to list available actions first. \
            Always confirm with the user before executing sensitive actions.
            """
    ]

    // MARK: - Primary Init

    /// Create a profile with explicit prompt builders.
    public init(
        promptBuilders: [PromptBuilder],
        toolPrompts: [String: String] = [:],
        messageContextProviders: [any MessageContextProvider] = [],
        maxIterations: Int = 10,
        toolTimeout: TimeInterval = 60,
        autoPersist: Bool = true,
        memoryConfig: MemoryConfig = MemoryConfig(),
        registerBuiltInTools: Bool = true,
        disabledBuiltInTools: Set<String> = [],
        sandboxRoot: URL? = nil
    ) {
        self.promptBuilders = promptBuilders
        self.identity = ""
        self.toolPrompts = toolPrompts
        self.messageContextProviders = messageContextProviders
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.autoPersist = autoPersist
        self.memoryConfig = memoryConfig
        self.registerBuiltInTools = registerBuiltInTools
        self.disabledBuiltInTools = disabledBuiltInTools
        self.sandboxRoot = sandboxRoot
    }

    // MARK: - Convenience Init

    /// Create a profile from an identity string.
    ///
    /// Identity is wrapped as `promptBuilders[0]`; additional builders follow.
    /// If identity is empty and no additional builders are provided, a default assistant prompt is used.
    public init(
        identity: String = "",
        additionalPromptBuilders: [PromptBuilder] = [],
        toolPrompts: [String: String] = [:],
        messageContextProviders: [any MessageContextProvider] = [],
        maxIterations: Int = 10,
        toolTimeout: TimeInterval = 60,
        autoPersist: Bool = true,
        memoryConfig: MemoryConfig = MemoryConfig(),
        registerBuiltInTools: Bool = true,
        disabledBuiltInTools: Set<String> = [],
        sandboxRoot: URL? = nil
    ) {
        var builders: [PromptBuilder] = []
        if !identity.isEmpty {
            builders.append(PromptBuilder("identity", prompt: identity))
        }
        builders.append(contentsOf: additionalPromptBuilders)
        if builders.isEmpty {
            builders.append(PromptBuilder(
                "You are an AI assistant embedded in a mobile application. "
                + "Help the user by leveraging the tools available to you."
            ))
        }

        self.init(
            promptBuilders: builders,
            toolPrompts: toolPrompts,
            messageContextProviders: messageContextProviders,
            maxIterations: maxIterations,
            toolTimeout: toolTimeout,
            autoPersist: autoPersist,
            memoryConfig: memoryConfig,
            registerBuiltInTools: registerBuiltInTools,
            disabledBuiltInTools: disabledBuiltInTools,
            sandboxRoot: sandboxRoot
        )
        self.identity = identity
    }
}
