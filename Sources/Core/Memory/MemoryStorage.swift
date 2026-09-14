//
//  MemoryStorage.swift
//  AppAgent
//

import Foundation

/// Protocol abstraction for long-term memory persistence.
/// Default implementation: FileMemoryStorage (JSON file).
/// Swap in SQLite, CoreData, or any other backend by conforming to this protocol.
public protocol MemoryStorage: Sendable {
    /// Load all memory entries from storage.
    func loadAll() async throws -> [MemoryEntry]

    /// Replace all entries with the given array.
    func save(_ entries: [MemoryEntry]) async throws

    /// Append a single entry to storage.
    func append(_ entry: MemoryEntry) async throws

    /// Remove an entry by ID.
    func remove(id: String) async throws
}

/// In-memory storage for testing.
public actor InMemoryMemoryStorage: MemoryStorage {
    private var entries: [MemoryEntry] = []

    public init() {}

    public func loadAll() async throws -> [MemoryEntry] {
        entries
    }

    public func save(_ entries: [MemoryEntry]) async throws {
        self.entries = entries
    }

    public func append(_ entry: MemoryEntry) async throws {
        entries.append(entry)
    }

    public func remove(id: String) async throws {
        entries.removeAll { $0.id == id }
    }
}
