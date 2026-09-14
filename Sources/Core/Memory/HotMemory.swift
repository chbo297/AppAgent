//
//  HotMemory.swift
//  AppAgent
//

import Foundation

/// In-process ephemeral key-value memory.
/// Not persisted — lost on app termination.
/// Use for runtime context like current location, active document, etc.
public actor HotMemory {
    private var store: [String: String] = [:]

    public init() {}

    /// Set a hot memory value.
    public func set(key: String, value: String) {
        store[key] = value
    }

    /// Get a hot memory value.
    public func get(key: String) -> String? {
        store[key]
    }

    /// Remove a hot memory value.
    public func remove(key: String) {
        store.removeValue(forKey: key)
    }

    /// Remove all hot memory values.
    public func clear() {
        store.removeAll()
    }

    /// Get all entries.
    public func allEntries() -> [String: String] {
        store
    }

    /// Format all hot memory as a summary string for prompt injection.
    /// Returns nil if empty.
    public func summary() -> String? {
        guard !store.isEmpty else { return nil }
        let lines = StableSort.byName(Array(store)) { $0.key }.map { "- \($0.key): \($0.value)" }
        return "# Current Context\n" + lines.joined(separator: "\n")
    }
}
