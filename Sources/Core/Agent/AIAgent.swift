//
//  AIAgent.swift
//  AppAgent
//

import Foundation

/// Top-level facade for the agent system.
///
/// Owns session lifecycle, memory, and skills. Each AIAgent holds references to
/// a `ToolCentral` and a `ModelProviderCentral` — defaulting to `.default`
/// but injectable for testing or multi-registry scenarios.
///
/// The host app creates one or more AIAgent instances, each with its own profile
/// and model selection.
public final class AIAgent: @unchecked Sendable {

    // MARK: - Identity

    /// Unique identifier for this agent (the name registered in AIAgentCentral).
    public let id: String

    // MARK: - Configuration (the "what")

    /// AIAgent profile: prompts, identity, memory, tool settings.
    @Locked
    public var profile: AIAgentProfile

    /// Tool filtering policy applied to all sessions created by this agent.
    /// Combined with session-level toolPolicy when resolving available tools.
    @Locked
    public var toolPolicy: ToolCentral.ToolPolicy?

    /// Tool central for this agent. Defaults to `.default` if not overridden at init.
    @Locked
    public var toolCentral: ToolCentral

    /// Model selection policy for this agent (e.g., primary + fallbacks in "providerName/modelId" format).
    /// If nil, falls back to providerCentral.resolveDefault().
    @Locked
    public var modelPolicy: ModelPolicy?

    /// 宿主 UI 注入的「切换到某个会话」钩子。核心没有 current session 概念（那是 UI 概念），
    /// 由 `AppAgentViewController` 安装；未安装时 `session_manage` 的 `switch` 会明确报未支持。
    @Locked
    public var activateSessionHandler: (@Sendable (String) -> Bool)?

    /// Provider central for this agent. Defaults to `.default` if not overridden at init.
    @Locked
    public var providerCentral: ModelProviderCentral

    // MARK: - Infrastructure (the "how")

    /// AISession lifecycle manager.
    public let sessionManager: AISessionManager

    /// Memory store coordinating long-term and hot memory.
    public let memoryStore: MemoryStore

    /// Skills manager for skill discovery and lifecycle.
    public let skillsManager: SkillsManager

    /// Delegate for lifecycle callbacks.
    @WeakLocked
    public var delegate: AIAgentDelegate?

    /// Readiness signal — gates session creation until built-in tools are registered.
    private let readySignal = ReadySignal()

    /// Wait until built-in tool registration is complete. Called automatically by `createSession`.
    public func ensureReady() async {
        await readySignal.wait()
    }

    /// Build a fresh AIAgentMask snapshot from the agent's current configuration.
    /// Each call creates a new mask; existing sessions keep their own masks unchanged.
    public func buildMask() -> AIAgentMask {
        AIAgentMask(
            profile: self.profile,
            toolPolicy: self.toolPolicy,
            toolCentral: self.toolCentral,
            agent: self
        )
    }

    /// Create a new AIAgent.
    ///
    /// - Important: Use `AIAgentCentral.create(name:...)` instead. This initializer is internal
    ///   to ensure all agents are created and managed through AIAgentCentral.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (the name in AIAgentCentral).
    ///   - profile: AIAgent profile (prompts, identity, memory, tool settings).
    ///   - toolCentral: Tool registry for this agent. Default: `.default`.
    ///   - providerCentral: Provider registry for this agent. Default: `.default`.
    ///   - modelPolicy: Model selection policy (primary + fallbacks). Default: nil.
    ///   - memoryStorage: Storage backend for long-term memory. Default: FileMemoryStorage.
    ///   - sessionStorage: Storage backend for session persistence. Default: FileSessionStorage.
    ///   - skillsManager: Skills manager. Default: auto-configured.
    init(
        id: String,
        profile: AIAgentProfile = AIAgentProfile(),
        toolCentral: ToolCentral = .`default`,
        providerCentral: ModelProviderCentral = .`default`,
        modelPolicy: ModelPolicy? = nil,
        toolPolicy: ToolCentral.ToolPolicy? = nil,
        memoryStorage: any MemoryStorage = FileMemoryStorage(),
        sessionStorage: any SessionStorage = FileSessionStorage(),
        skillsManager: SkillsManager = SkillsManager()
    ) {
        self.id = id
        self._profile = Locked(wrappedValue: profile)
        self._toolCentral = Locked(wrappedValue: toolCentral)
        self._providerCentral = Locked(wrappedValue: providerCentral)
        self._modelPolicy = Locked(wrappedValue: modelPolicy)
        self._activateSessionHandler = Locked(wrappedValue: nil)
        self._toolPolicy = Locked(wrappedValue: toolPolicy)
        self._delegate = WeakLocked(wrappedValue: nil)
        self.memoryStore = MemoryStore(config: profile.memoryConfig, storage: memoryStorage)
        self.sessionManager = AISessionManager(storage: sessionStorage)
        self.skillsManager = skillsManager

        // Wire back-references
        self.sessionManager.agent = self

        Logger.info("AIAgent", "init: id=\(id), modelPolicy=\(modelPolicy.map { "\($0.primary) +\($0.fallbacks.count) fallbacks" } ?? "nil"), promptBuilders=\(profile.promptBuilders.count), identity=\(profile.identity.isEmpty ? "(none)" : "\(profile.identity.count) chars"), maxIterations=\(profile.maxIterations), autoPersist=\(profile.autoPersist), memory=(longTerm=\(profile.memoryConfig.longTermEnabled), hot=\(profile.memoryConfig.hotMemoryEnabled), maxEntries=\(profile.memoryConfig.longTermMaxEntries))")

        // Auto-register built-in tools
        if profile.registerBuiltInTools {
            Task { [weak self] in
                await self?.registerBuiltInTools()
                await self?.readySignal.signal()
            }
        } else {
            Task { [weak self] in
                await self?.readySignal.signal()
            }
        }
    }

    // MARK: - Provider Resolution

    /// Resolve the model provider and model ID to use for requests.
    ///
    /// Resolution order:
    /// 1. `modelPolicy.primary` against `providerCentral`
    /// 2. `providerCentral.resolveDefault()` as fallback
    public func resolveProvider() async -> (provider: any ModelProvider, modelId: String)? {
        if let ref = modelPolicy?.primary,
           let result = await providerCentral.resolve(modelReference: ref) {
            return result
        }
        return await providerCentral.resolveDefault()
    }

    // MARK: - Built-in Tool Registration

    /// Register all SDK built-in tools into the tool central.
    /// Called automatically on init when `profile.registerBuiltInTools` is true.
    public func registerBuiltInTools() async {
        let disabled = profile.disabledBuiltInTools

        // Phase 1: Core tools
        if !disabled.contains("clarify") {
            await toolCentral.register(ClarifyTool())
        }
        if !disabled.contains("memory") {
            await toolCentral.register(MemoryTool())
        }
        if !disabled.contains("todo") {
            await toolCentral.register(TodoTool())
        }

        // Phase 2: File tools
        let sandboxRoot = profile.sandboxRoot
        if !disabled.contains("file_read") {
            await toolCentral.register(FileReadTool(sandboxRoot: sandboxRoot))
        }
        if !disabled.contains("file_write") {
            await toolCentral.register(FileWriteTool(sandboxRoot: sandboxRoot))
        }
        if !disabled.contains("file_search") {
            await toolCentral.register(FileSearchTool(sandboxRoot: sandboxRoot))
        }

        // Phase 2: Skills tools
        if !disabled.contains("skills_list") {
            await toolCentral.register(SkillsListTool(manager: skillsManager))
        }
        if !disabled.contains("skill_view") {
            await toolCentral.register(SkillViewTool(manager: skillsManager))
        }
        if !disabled.contains("skill_manage") {
            await toolCentral.register(SkillManageTool(manager: skillsManager))
        }

        // Phase 3: Media tools
        if !disabled.contains("text_to_speech") {
            await toolCentral.register(TextToSpeechTool())
        }

        // Phase 4: Advanced tools
        if !disabled.contains("delegate_task") {
            await toolCentral.register(DelegateTaskTool())
        }
        if !disabled.contains("session_search") {
            await toolCentral.register(SessionSearchTool())
        }
        if !disabled.contains("session_manage") {
            await toolCentral.register(SessionManageTool())
        }

        // System tools
        if !disabled.contains("clipboard") {
            await toolCentral.register(ClipboardTool())
        }
        if !disabled.contains("haptic") {
            await toolCentral.register(HapticTool())
        }

        // Network read access (group "web"). No host provider needed — unlike
        // web_search this one just fetches a URL the model already has.
        if !disabled.contains("web_fetch") {
            await toolCentral.register(WebFetchTool())
        }

        // Phase 5: Host-introspection storage tools (group "host-storage")
        if !disabled.contains("app_user_defaults") {
            await toolCentral.register(AppUserDefaultsTool())
        }
        if !disabled.contains("app_sandbox_file") {
            await toolCentral.register(AppSandboxFileTool())
        }
        if !disabled.contains("app_device_info") {
            await toolCentral.register(AppDeviceInfoTool())
        }

        // Host runtime introspection (group "host-runtime"). Requires UIKit for the
        // default provider; hosts on other platforms can register their own.
        #if canImport(UIKit)
        if !disabled.contains("app_runtime_inspect") {
            await toolCentral.register(RuntimeInspectTool(provider: DefaultRuntimeInspectProvider()))
        }
        if !disabled.contains("screenshot") {
            await toolCentral.register(ScreenshotTool())
        }
        #endif

        Logger.info("AIAgent", "registerBuiltInTools: registered built-in tools (disabled: \(disabled))")
    }

    // MARK: - AISession Convenience

    /// Create a new session.
    @discardableResult
    public func createSession(
        title: String = "New Chat",
        modelReference: String? = nil,
        toolPolicy: ToolCentral.ToolPolicy? = nil
    ) async -> AISession {
        // Wait for built-in tool registration to complete
        await ensureReady()

        // Resolve provider + model: prefer explicit modelReference, then agent's modelPolicy.primary
        let ref = modelReference ?? modelPolicy?.primary
        var resolvedProvider: (any ModelProvider)?
        var resolvedModelId: String?
        if let ref, let result = await providerCentral.resolve(modelReference: ref) {
            resolvedProvider = result.provider
            resolvedModelId = result.modelId
        } else if let result = await providerCentral.resolveDefault() {
            resolvedProvider = result.provider
            resolvedModelId = result.modelId
        }

        let session = await sessionManager.createSession(
            title: title,
            toolPolicy: toolPolicy,
            provider: resolvedProvider,
            modelId: resolvedModelId
        )
        delegate?.aiAgent(self, didCreateSession: session)
        return session
    }

    /// Restore all sessions from storage.
    public func restoreAll() async throws {
        // 恢复会话时会从 toolCentral 解析工具表。内置工具的注册是 init 里丢出去的
        // 异步 Task，若不等就绪就解析，拿到的是「注册到一半」的残缺工具集（注册顺序
        // 靠后的 web_fetch / screenshot 会缺），而模型看到的清单是实时全集，于是
        // 出现「清单里有、执行时 Tool not found」。所以必须先等就绪。
        await ensureReady()
        try await sessionManager.restoreAll()
    }

    /// Delete a session by ID.
    public func deleteSession(_ id: String) async throws {
        try await sessionManager.deleteSession(id)
        delegate?.aiAgent(self, didDeleteSession: id)
    }

    /// Find a session by ID.
    public func session(id: String) -> AISession? {
        sessionManager.session(id: id)
    }

    /// All sessions sorted by updatedAt descending.
    public var allSessions: [AISession] {
        sessionManager.allSessions
    }

    // MARK: - Memory Convenience

    /// Add an entry to long-term memory.
    public func addMemory(_ entry: MemoryEntry) async throws {
        try await memoryStore.addLongTerm(entry)
    }

    /// Search long-term memory.
    public func searchMemory(query: String, limit: Int = 10) async -> [MemoryEntry] {
        await memoryStore.searchLongTerm(query: query, limit: limit)
    }

    /// Set a hot memory value.
    public func setHotMemory(key: String, value: String) async {
        await memoryStore.setHot(key: key, value: value)
    }

    // MARK: - Internal Callbacks

    /// Called by AISession when a run is rejected before starting (e.g. concurrency limit).
    /// Forwarded to the delegate; no run lifecycle callbacks follow.
    func sessionDidRejectRun(_ session: AISession, error: Error) {
        Logger.info("AIAgent", "sessionDidRejectRun: sessionId=\(session.id), error=\(error)")
        delegate?.aiAgent(self, session: session, didRejectRun: error)
    }

    /// Called by AISession after a successful agent run. Handles auto-save and delegate notification.
    func sessionDidCompleteRun(_ session: AISession, result: AIAgentFinish) {
        Logger.info("AIAgent", "sessionDidCompleteRun: sessionId=\(session.id), textLength=\(result.text.count), autoPersist=\(profile.autoPersist)")
        delegate?.aiAgent(self, session: session, didCompleteRun: result)
        if profile.autoPersist && session.isDirty {
            Task { [weak self] in
                do {
                    try await self?.sessionManager.saveSession(session)
                    session.clearDirty()
                } catch {
                    Logger.error("AIAgent", "autoPersist failed: sessionId=\(session.id), error=\(error)")
                    if let self = self {
                        self.delegate?.aiAgent(self, session: session, didEncounterError: error)
                    }
                }
            }
        }
    }

    /// Called by AISession when an error occurs.
    func sessionDidEncounterError(_ session: AISession, error: Error) {
        Logger.error("AIAgent", "sessionDidEncounterError: sessionId=\(session.id), error=\(error)")
        delegate?.aiAgent(self, session: session, didEncounterError: error)
    }
}
