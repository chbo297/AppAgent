//
//  ToolGroups.swift
//  AppAgent
//
//  Canonical tool-group identifiers and agent-level convenience for enabling or
//  disabling whole groups of tools. Groups let the host toggle broad capability
//  areas (e.g. all host-introspection tools) without listing individual names.
//

import Foundation

/// Well-known tool group identifiers used by the SDK's built-in tools.
///
/// A tool's `group` is a free-form string, so hosts may define their own; these
/// are the groups the built-in and Liji-integration tools ship with.
public enum ToolGroups {
    /// Core assistant tools (clarify, memory, todo).
    public static let core = "core"
    /// Sandboxed working-directory file tools (file_read/file_write/file_search).
    public static let file = "file"
    /// Skills discovery and management.
    public static let skills = "skills"
    /// Media tools (text-to-speech, etc.).
    public static let media = "media"
    /// Web access tools.
    public static let web = "web"
    /// System tools (clipboard, haptic).
    public static let system = "system"
    /// Session self-inspection (session_manage, session_search).
    public static let session = "session"
    /// Host runtime introspection: UI hierarchy, classes, KVC read/write, invoke.
    public static let hostRuntime = "host-runtime"
    /// Host storage introspection: UserDefaults and sandbox files.
    public static let hostStorage = "host-storage"
    /// Uncategorized custom tools.
    public static let custom = "custom"

    /// The host-introspection groups — everything that lets the agent read or
    /// modify the host app's live state. Useful to toggle as a unit.
    public static let hostIntrospection: Set<String> = [hostRuntime, hostStorage]
}

extension AIAgent {

    /// Restrict this agent to only the given tool groups. Passing `nil` clears the
    /// group restriction (all groups allowed, subject to other policy rules).
    ///
    /// This updates the agent-level `toolPolicy.allowedGroups`. Existing sessions
    /// should call `reinstallTools()` (or be recreated) to pick up the change.
    public func restrictToolGroups(_ groups: Set<String>?) {
        var policy = toolPolicy ?? ToolCentral.ToolPolicy()
        policy.allowedGroups = groups
        toolPolicy = policy
    }

    /// Exclude the given tool groups from this agent. Merges with any groups that
    /// are already excluded.
    public func disableToolGroups(_ groups: Set<String>) {
        var policy = toolPolicy ?? ToolCentral.ToolPolicy()
        policy.excludedGroups = (policy.excludedGroups ?? []).union(groups)
        toolPolicy = policy
    }

    /// Re-enable groups previously disabled via `disableToolGroups`.
    public func enableToolGroups(_ groups: Set<String>) {
        guard var policy = toolPolicy, let excluded = policy.excludedGroups else { return }
        policy.excludedGroups = excluded.subtracting(groups)
        if policy.excludedGroups?.isEmpty == true { policy.excludedGroups = nil }
        toolPolicy = policy
    }

    /// All tool groups currently present in this agent's tool central,
    /// mapped to the tool names in each group.
    public func toolGroupsSnapshot() async -> [String: [String]] {
        let map = await toolCentral.groupMap()
        var byGroup: [String: [String]] = [:]
        for (name, group) in map {
            byGroup[group, default: []].append(name)
        }
        for key in byGroup.keys { byGroup[key]?.sort() }
        return byGroup
    }
}
