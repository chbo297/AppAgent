//
//  AIAgentCentral.swift
//  AppAgent
//

import Foundation

/// AIAgent 总站 — 所有 AIAgent 实例的唯一工厂和注册中心。
///
/// AIAgent.init 是 internal，外部只能通过 AIAgentCentral 创建 agent。
/// A default "main" agent is lazily created with default AIAgentProfile
/// when first accessed.
///
/// Usage:
///   let agent = await AIAgentCentral.default.create(name: "main", profile: myProfile)
///   let found = await AIAgentCentral.default.agent(named: "main")
///   let main  = await AIAgentCentral.default.main
public actor AIAgentCentral {

    /// The default instance, used by most apps.
    public static let `default` = AIAgentCentral()

    /// Well-known name for the main agent.
    public static let mainName = "main"

    private var agents: [String: AIAgent] = [:]

    public init() {}

    // MARK: - Factory

    /// Create and register an agent. This is the only way to create an AIAgent.
    ///
    /// If an agent with the same name already exists, it is replaced.
    /// The `name` parameter becomes the agent's `id`.
    ///
    /// - Parameters:
    ///   - name: Unique name for this agent (becomes `agent.id`).
    ///   - profile: AIAgent profile (prompts, identity, memory, tool settings).
    ///   - toolCentral: Tool registry. Default: `.default`.
    ///   - providerCentral: Provider registry. Default: `.default`.
    ///   - modelPolicy: Model selection policy (primary + fallbacks). Default: nil.
    ///   - toolPolicy: Tool filtering policy. Default: nil.
    ///   - memoryStorage: Storage backend for long-term memory. Default: FileMemoryStorage.
    ///   - sessionStorage: Storage backend for session persistence. Default: FileSessionStorage.
    ///   - skillsManager: Skills manager. Default: auto-configured.
    /// - Returns: The newly created and registered AIAgent.
    @discardableResult
    public func create(
        name: String,
        profile: AIAgentProfile = AIAgentProfile(),
        toolCentral: ToolCentral = .`default`,
        providerCentral: ModelProviderCentral = .`default`,
        modelPolicy: ModelPolicy? = nil,
        toolPolicy: ToolCentral.ToolPolicy? = nil,
        memoryStorage: any MemoryStorage = FileMemoryStorage(),
        sessionStorage: any SessionStorage = FileSessionStorage(),
        skillsManager: SkillsManager = SkillsManager()
    ) -> AIAgent {
        let agent = AIAgent(
            id: name,
            profile: profile,
            toolCentral: toolCentral,
            providerCentral: providerCentral,
            modelPolicy: modelPolicy,
            toolPolicy: toolPolicy,
            memoryStorage: memoryStorage,
            sessionStorage: sessionStorage,
            skillsManager: skillsManager
        )
        agents[name] = agent
        Logger.info("AIAgentCentral", "created: name=\(name)")
        return agent
    }

    // MARK: - Removal

    /// Remove an agent by name.
    /// Returns the removed agent, or nil if not found.
    @discardableResult
    public func remove(name: String) -> AIAgent? {
        let removed = agents.removeValue(forKey: name)
        if removed != nil {
            Logger.info("AIAgentCentral", "removed: name=\(name)")
        }
        return removed
    }

    // MARK: - Retrieval

    /// Get an agent by name.
    public func agent(named name: String) -> AIAgent? {
        agents[name]
    }

    /// The "main" agent. Lazily created with default AIAgentProfile if not explicitly created.
    public var main: AIAgent {
        if let existing = agents[AIAgentCentral.mainName] {
            return existing
        }
        return create(name: AIAgentCentral.mainName)
    }

    /// All registered agent names (stably sorted).
    public var registeredNames: [String] {
        StableSort.byName(Array(agents.keys))
    }

    /// All registered agents as (name, agent) pairs, sorted by name.
    public var allAgents: [(name: String, agent: AIAgent)] {
        StableSort.byName(agents.map { (name: $0.key, agent: $0.value) }, key: \.name)
    }
}
