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
/// - **Convenience**: use the default assistant identity or override it; extras follow `promptBuilders[0]`.
public struct AIAgentProfile: Sendable {

    // MARK: - Core

    /// Prompt builders — the core output of this profile.
    /// Evaluated during system prompt assembly. Each builder provides either
    /// static text or a dynamic closure. Results are appended in order.
    public var promptBuilders: [PromptBuilder]

    // MARK: - Identity (convenience access)

    /// Resolved identity text from the convenience init (default or explicit override).
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

    /// Execution and safety settings copied into each newly created session.
    public var executionPolicy: AIAgentExecutionPolicy

    /// Publicly discoverable default loop budget.
    public static let defaultMaxIterations = AIAgentExecutionPolicy.defaultMaxIterations

    // 下面这些都是 `executionPolicy` 的单字段转发，为的是宿主可以只改一项而不必重建整份策略。
    // 策略字段是 `var`，所以每个 setter 只写自己那一格 —— 加字段时这里一行都不用动。
    // （早先它们各自重建整个 `AIAgentExecutionPolicy`，于是加一个字段要改五处。）

    /// Maximum LLMExecutor loop iterations per user turn. Default: 70.
    /// Includes model requests after tool execution, retries, and model fallbacks.
    public var maxIterations: Int {
        get { executionPolicy.maxIterations }
        set { executionPolicy.maxIterations = newValue }
    }

    /// Single tool execution timeout in seconds. Default: 60s.
    public var toolTimeout: TimeInterval {
        get { executionPolicy.toolTimeout }
        set { executionPolicy.toolTimeout = newValue }
    }

    /// 流式响应的空闲上界，秒。默认 25s，`<= 0` 关闭。见 `AIAgentExecutionPolicy.streamIdleTimeout`。
    public var streamIdleTimeout: TimeInterval {
        get { executionPolicy.streamIdleTimeout }
        set { executionPolicy.streamIdleTimeout = newValue }
    }

    /// Agent-wide cap on how many UTF-8 bytes one tool result may hand the model.
    /// Oversized results are truncated with a hint to narrow the query, so a single
    /// chatty call (a deep `ui_hierarchy`, an unfiltered `class_list`) cannot eat the
    /// context window. A tool raises its own ceiling via `ToolProtocol.outputMaxBytes`.
    /// Default: 8 KB.
    public var toolOutputMaxBytes: Int {
        get { executionPolicy.toolOutputMaxBytes }
        set { executionPolicy.toolOutputMaxBytes = newValue }
    }

    /// Whether the agent may change runtime state at all. `.readOnly` refuses every
    /// call whose per-call safety level is above `.safe` before it executes — the
    /// iOS stand-in for Codex's `sandbox_mode`. Ship read-only and open it up for
    /// debug builds or an explicit user opt-in. Default: `.allowed`.
    public var toolMutationPolicy: Tool.MutationPolicy {
        get { executionPolicy.toolMutationPolicy }
        set { executionPolicy.toolMutationPolicy = newValue }
    }

    // MARK: - Persistence

    /// Whether to auto-persist sessions after each completed agent run. Default: true.
    public var autoPersist: Bool {
        get { executionPolicy.autoPersist }
        set { executionPolicy.autoPersist = newValue }
    }

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
            Read text in the agent workspace (default Documents/AppAgent/files). Use offset and limit for large files.
            Do NOT use for binary files — only text content.
            """,
        "file_write": """
            Write text in the agent workspace (default Documents/AppAgent/files). Overwrites the entire file.
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
            Search AppAgent conversation history only when needed for the current request.
            Do not preload other sessions' histories.
            """,
        "session_manage": """
            Manage AppAgent conversations: list/read/create/merge/archive/restore, as available in the current tool schema.
            'delete' means archive. No permanent deletion via tools; only the user can purge in the UI.
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

    /// Create a profile with explicit prompt builders. No default identity or environment is added.
    public init(
        promptBuilders: [PromptBuilder],
        toolPrompts: [String: String] = [:],
        messageContextProviders: [any MessageContextProvider] = [],
        maxIterations: Int = AIAgentExecutionPolicy.defaultMaxIterations,
        toolTimeout: TimeInterval = AIAgentExecutionPolicy.defaultToolTimeout,
        autoPersist: Bool = AIAgentExecutionPolicy.defaultAutoPersist,
        toolOutputMaxBytes: Int = AIAgentExecutionPolicy.defaultToolOutputMaxBytes,
        toolMutationPolicy: Tool.MutationPolicy = AIAgentExecutionPolicy.defaultToolMutationPolicy,
        memoryConfig: MemoryConfig = MemoryConfig(),
        registerBuiltInTools: Bool = true,
        disabledBuiltInTools: Set<String> = [],
        sandboxRoot: URL? = nil
    ) {
        self.promptBuilders = promptBuilders
        self.identity = ""
        self.toolPrompts = toolPrompts
        self.messageContextProviders = messageContextProviders
        self.executionPolicy = AIAgentExecutionPolicy(
            maxIterations: maxIterations,
            toolTimeout: toolTimeout,
            toolOutputMaxBytes: toolOutputMaxBytes,
            autoPersist: autoPersist,
            toolMutationPolicy: toolMutationPolicy
        )
        self.memoryConfig = memoryConfig
        self.registerBuiltInTools = registerBuiltInTools
        self.disabledBuiltInTools = disabledBuiltInTools
        self.sandboxRoot = sandboxRoot
    }

    // MARK: - Convenience Init

    /// Create a profile with a default assistant identity or a complete identity override.
    ///
    /// A nonempty `identity` is used verbatim and replaces the entire default identity,
    /// including its environment context. Otherwise, a short static identity is resolved
    /// once at initialization and wrapped as `promptBuilders[0]`, even when extras exist.
    /// This does not add per-message context or grant SDK runtime inspection access.
    ///
    /// - Parameters:
    ///   - assistantName: Default identity's name. Blank names fall back to "小蓝".
    ///   - hostAppName: Default identity's host name override. Blank/nil uses
    ///     Bundle.main's CFBundleDisplayName, then CFBundleName, then "宿主应用".
    ///   - additionalPromptBuilders: Appended after the resolved identity, in order.
    public init(
        identity: String = "",
        assistantName: String = "小蓝",
        hostAppName: String? = nil,
        additionalPromptBuilders: [PromptBuilder] = [],
        toolPrompts: [String: String] = [:],
        messageContextProviders: [any MessageContextProvider] = [],
        maxIterations: Int = AIAgentExecutionPolicy.defaultMaxIterations,
        toolTimeout: TimeInterval = AIAgentExecutionPolicy.defaultToolTimeout,
        autoPersist: Bool = AIAgentExecutionPolicy.defaultAutoPersist,
        toolOutputMaxBytes: Int = AIAgentExecutionPolicy.defaultToolOutputMaxBytes,
        toolMutationPolicy: Tool.MutationPolicy = AIAgentExecutionPolicy.defaultToolMutationPolicy,
        memoryConfig: MemoryConfig = MemoryConfig(),
        registerBuiltInTools: Bool = true,
        disabledBuiltInTools: Set<String> = [],
        sandboxRoot: URL? = nil
    ) {
        let resolvedIdentity = identity.isEmpty
            ? Self.defaultIdentity(assistantName: assistantName, hostAppName: hostAppName)
            : identity
        var builders = [PromptBuilder("identity", prompt: resolvedIdentity)]
        builders.append(contentsOf: additionalPromptBuilders)

        self.init(
            promptBuilders: builders,
            toolPrompts: toolPrompts,
            messageContextProviders: messageContextProviders,
            maxIterations: maxIterations,
            toolTimeout: toolTimeout,
            autoPersist: autoPersist,
            toolOutputMaxBytes: toolOutputMaxBytes,
            toolMutationPolicy: toolMutationPolicy,
            memoryConfig: memoryConfig,
            registerBuiltInTools: registerBuiltInTools,
            disabledBuiltInTools: disabledBuiltInTools,
            sandboxRoot: sandboxRoot
        )
        self.identity = resolvedIdentity
    }

    // MARK: - Default Identity

    private static func defaultIdentity(assistantName: String, hostAppName: String?) -> String {
        let name = nonBlankName(assistantName) ?? "小蓝"
        let host = resolveHostAppName(hostAppName)
        return """
            你是\(name)，由 AppAgent 运行在宿主应用「\(host)」内的 AI 助手。
            通过当前实际可用的工具调用宿主提供的功能，不假定未提供的能力。
            AppAgent 可有多个对话会话；仅在相应会话工具可用时按需检索和管理，不预载其他会话历史。
            会话管理不扩大 SDK 运行时访问范围，仍须遵守工具范围与授权。
            """
    }

    /// Metadata is injectable so fallback behavior can be tested without changing Bundle.main.
    static func resolveHostAppName(
        _ hostAppName: String?,
        bundleDisplayName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
        bundleName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    ) -> String {
        nonBlankName(hostAppName)
            ?? nonBlankName(bundleDisplayName)
            ?? nonBlankName(bundleName)
            ?? "宿主应用"
    }

    private static func nonBlankName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
