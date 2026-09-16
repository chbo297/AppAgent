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

    public init() {}

    // MARK: - Registration

    /// Register a shared tool instance (used by all sessions).
    public func register(_ tool: any ToolProtocol) {
        sharedTools[tool.name] = tool
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
