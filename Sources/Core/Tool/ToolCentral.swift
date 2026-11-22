//
//  ToolCentral.swift
//  AppAgent
//

import Foundation

/// 工具总站 — 所有 Tool 的注册中心。
///
/// Stores shared tool instances and tool factories.
/// AISession-level tool instances are created via `resolveTools()`.
///
/// Usage:
///   await ToolCentral.default.register(myTool)
///   let tools = await ToolCentral.default.resolveTools()
public actor ToolCentral {

    // MARK: - Nested Types

    /// A policy that filters which tools are available.
    ///
    /// When applied to a set of tool names:
    /// 1. If `allowedNames` is non-nil, only tools whose name is in this set survive.
    /// 2. If `excludedNames` is non-nil, tools whose name is in this set are removed.
    /// 3. If `allowedGroups` is non-nil, only tools whose group is in this set survive.
    /// 4. If `excludedGroups` is non-nil, tools whose group is in this set are removed.
    ///
    /// Name rules take effect wherever the policy is applied. Group rules only take
    /// effect when the caller can resolve each tool's group (via the `groupOf`
    /// overload of `apply`), which the tool-resolution paths do.
    ///
    /// Multiple policies are applied in sequence — each narrows the surviving set further.
    public struct ToolPolicy: Sendable {
        public var allowedNames: Set<String>?
        public var excludedNames: Set<String>?
        public var allowedGroups: Set<String>?
        public var excludedGroups: Set<String>?

        public init(allowedNames: Set<String>? = nil, excludedNames: Set<String>? = nil,
                    allowedGroups: Set<String>? = nil, excludedGroups: Set<String>? = nil) {
            self.allowedNames = allowedNames
            self.excludedNames = excludedNames
            self.allowedGroups = allowedGroups
            self.excludedGroups = excludedGroups
        }

        /// Apply a sequence of policies to a set of tool names, returning the surviving names.
        /// Only name-based rules are evaluated; group rules are skipped entirely (use the
        /// `groupOf:` overload where tool groups can be resolved).
        public static func apply(_ policies: [ToolPolicy], to names: Set<String>) -> Set<String> {
            var remaining = names
            for policy in policies {
                if let allowed = policy.allowedNames {
                    remaining = remaining.intersection(allowed)
                }
                if let excluded = policy.excludedNames {
                    remaining = remaining.subtracting(excluded)
                }
            }
            return remaining
        }

        /// Apply a sequence of policies, evaluating both name and group rules.
        /// - Parameter groupOf: resolves a tool name to its group (nil if unknown).
        public static func apply(_ policies: [ToolPolicy], to names: Set<String>,
                                 groupOf: (String) -> String?) -> Set<String> {
            var remaining = names
            for policy in policies {
                if let allowed = policy.allowedNames {
                    remaining = remaining.intersection(allowed)
                }
                if let excluded = policy.excludedNames {
                    remaining = remaining.subtracting(excluded)
                }
                if let allowedGroups = policy.allowedGroups {
                    remaining = remaining.filter { name in
                        guard let group = groupOf(name) else { return false }
                        return allowedGroups.contains(group)
                    }
                }
                if let excludedGroups = policy.excludedGroups {
                    remaining = remaining.filter { name in
                        guard let group = groupOf(name) else { return true }
                        return !excludedGroups.contains(group)
                    }
                }
            }
            return remaining
        }
    }

    /// A factory that produces per-session tool instances.
    /// Conforms to ToolProtocol so ToolCentral can read name/description/parameters for descriptors.
    public protocol ToolFactory: ToolProtocol {
        func createInstance() -> any ToolProtocol
    }

    /// Convenience factory using a closure to create tool instances.
    public struct ClosureToolFactory: ToolFactory {
        public let name: String
        public let description: String
        public let parameters: Tool.Schema
        private let _create: @Sendable () -> any ToolProtocol

        public init(name: String, description: String, parameters: Tool.Schema,
             create: @escaping @Sendable () -> any ToolProtocol) {
            self.name = name
            self.description = description
            self.parameters = parameters
            self._create = create
        }

        public func createInstance() -> any ToolProtocol {
            _create()
        }
    }

    // MARK: - Singleton

    /// The default instance, used by most apps.
    public static let `default` = ToolCentral()

    private var sharedTools: [String: any ToolProtocol] = [:]
    private var toolFactories: [String: any ToolFactory] = [:]
    /// 已注册的宿主工具集，按 namespace 索引；同一 namespace 再次注册即整组替换。
    private var hostSets: [String: HostToolSet] = [:]
    /// 按需加载组：组名 → 一句话用途。SDK 的 debug 组预置，宿主工具不必等内置工具注册完才能加入。
    private var deferredGroups: [String: String] = [ToolGroups.debug: ToolGroups.debugSummary]

    public init() {}

    // MARK: - Registration

    /// Register an SDK-defined tool instance (used by all sessions). The name is exposed as-is.
    /// Host business tools go through `registerHost(_:)` so they get a namespace prefix.
    public func register(_ tool: any ToolProtocol) {
        sharedTools[tool.name] = tool
    }

    /// 注册宿主工具集：工具以 `<namespace>_<name>` 暴露给模型，与已注册工具重名时整组失败、不做任何改动。
    /// 同一 namespace 再次注册会先移除上一组，便于宿主在配置变化后重建。
    public func registerHost(_ set: HostToolSet) throws {
        guard ToolNaming.isValidNamespace(set.namespace) else {
            throw ToolRegistrationError.invalidNamespace(set.namespace)
        }
        let previous = hostSets[set.namespace]
        let previousNames = Set((previous?.tools ?? []).map { tool in
            HostTool(base: tool, namespace: set.namespace).name
        })
        let builtInNames = Set(sharedTools.keys).union(toolFactories.keys).subtracting(previousNames).filter { name in
            !(sharedTools[name] is HostTool)
        }
        guard !ToolNaming.reservedNamespaces(builtInNames: builtInNames).contains(set.namespace) else {
            throw ToolRegistrationError.reservedNamespace(set.namespace)
        }
        var wrapped: [HostTool] = []
        var seen: Set<String> = []
        for tool in set.tools {
            let hostTool = HostTool(base: tool, namespace: set.namespace)
            guard ToolNaming.isValidToolName(tool.name), ToolNaming.isValidToolName(hostTool.name) else {
                throw ToolRegistrationError.invalidToolName(hostTool.name)
            }
            let taken = (sharedTools[hostTool.name] != nil || toolFactories[hostTool.name] != nil)
                && !previousNames.contains(hostTool.name)
            guard !taken, seen.insert(hostTool.name).inserted else {
                throw ToolRegistrationError.duplicateToolName(hostTool.name)
            }
            if let group = tool.deferredGroup, deferredGroups[group] == nil, set.deferredGroups[group] == nil {
                throw ToolRegistrationError.unknownDeferredGroup(tool: hostTool.name, group: group)
            }
            wrapped.append(hostTool)
        }
        for name in previousNames {
            sharedTools.removeValue(forKey: name)
        }
        for tool in wrapped {
            sharedTools[tool.name] = tool
        }
        for (group, summary) in set.deferredGroups {
            deferredGroups[group] = summary
        }
        hostSets[set.namespace] = set
    }

    /// 已注册的宿主工具集（按 namespace 排序）。
    public func hostToolSets() -> [HostToolSet] {
        hostSets.keys.sorted().compactMap { namespace in
            hostSets[namespace]
        }
    }

    /// 登记按需加载组。工具通过 `deferredGroup` 加入；同名再次登记只更新用途说明。
    public func registerDeferredGroup(_ name: String, summary: String) {
        deferredGroups[name] = summary
    }

    /// 已登记、且至少有一个工具的按需加载组：组名 → 用途。
    public func deferredGroupSummaries() -> [String: String] {
        var used: Set<String> = []
        for tool in sharedTools.values {
            if let group = tool.deferredGroup {
                used.insert(group)
            }
        }
        for factory in toolFactories.values {
            if let group = factory.deferredGroup {
                used.insert(group)
            }
        }
        return deferredGroups.filter { entry in
            used.contains(entry.key)
        }
    }

    /// 系统提示词里的工具来源与按需加载说明；没有宿主工具集、也没有按需组时返回 nil。
    /// 文字固定，不随会话是否已加载某组变化，便于提示词缓存。
    public func toolSourcesPrompt() -> String? {
        var lines: [String] = []
        let sets = hostToolSets()
        if !sets.isEmpty {
            lines.append("# Tool sources")
            for set in sets {
                lines.append("- Tools named `\(set.namespace)_*` are provided by \(set.displayName): \(set.summary)")
            }
            lines.append("- Other tools are App Agent built-ins. Just use each tool as its description says; "
                         + "the source matters only when debugging.")
        }
        let groups = deferredGroupSummaries()
        if !groups.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("# Tools loaded on demand")
            for name in groups.keys.sorted() {
                lines.append("- \(name): \(groups[name] ?? "")")
            }
            lines.append("Call `\(LoadToolsTool.toolName)` with the group name before using these; "
                         + "they stay available for the rest of this conversation.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Register a tool factory (creates per-session instances).
    public func register(factory: any ToolFactory) {
        toolFactories[factory.name] = factory
    }

    /// Register a tool factory using a closure.
    public func registerFactory(name: String, description: String, parameters: Tool.Schema,
                         create: @escaping @Sendable () -> any ToolProtocol) {
        let factory = ClosureToolFactory(name: name, description: description,
                                         parameters: parameters, create: create)
        toolFactories[name] = factory
    }

    // MARK: - AISession Tool Creation

    /// Create a set of tools for a session.
    /// - Shared tools are returned as-is (all sessions share the same instance).
    /// - Factory tools create fresh instances per call.
    /// - `policies`: applied in order to filter **both** sharedTools and toolFactories.
    ///   Empty array means no filtering (all tools returned).
    public func resolveTools(policies: [ToolPolicy] = []) -> [String: any ToolProtocol] {
        let allNames = Set(sharedTools.keys).union(Set(toolFactories.keys))
        let surviving = ToolPolicy.apply(policies, to: allNames, groupOf: { [self] name in
            groupOf(name)
        })

        var tools: [String: any ToolProtocol] = [:]
        for name in surviving {
            if let factory = toolFactories[name] {
                tools[name] = factory.createInstance()
            } else if let shared = sharedTools[name] {
                tools[name] = shared
            }
        }
        return tools
    }

    /// Resolve a registered tool's group by name (shared instance or factory descriptor).
    public func groupOf(_ name: String) -> String? {
        if let shared = sharedTools[name] { return shared.group }
        if let factory = toolFactories[name] { return factory.group }
        return nil
    }

    /// A snapshot of every registered tool's name → group, for building group-aware policies.
    public func groupMap() -> [String: String] {
        var map: [String: String] = [:]
        for (name, tool) in sharedTools { map[name] = tool.group }
        for (name, factory) in toolFactories { map[name] = factory.group }
        return map
    }
}

// MARK: - ToolFactory Default Execute

extension ToolCentral.ToolFactory {
    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        .error("ToolFactory is a template, not directly executable — use createInstance() first")
    }
}
