//
//  FileMemoryStorage.swift
//  AppAgent
//

import Foundation

/// File-based memory storage using a single JSON file.
/// Thread-safe via actor isolation.
/// Degrades gracefully: read failures return an empty array instead of throwing.
public actor FileMemoryStorage: MemoryStorage {
    private let fileURL: URL

    /// - Parameter directory: Directory for the memory.json file.
    ///   Defaults to Documents/AppAgent/memory/.
    public init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            dir = docs.appendingPathComponent("AppAgent/memory", isDirectory: true)
        }
        self.fileURL = dir.appendingPathComponent("memory.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func loadAll() async throws -> [MemoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([MemoryEntry].self, from: data)
        } catch {
            // Degrade gracefully on corrupted data
            return []
        }
    }

    public func save(_ entries: [MemoryEntry]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public func append(_ entry: MemoryEntry) async throws {
        var entries = try await loadAll()
        entries.append(entry)
        try await save(entries)
    }

    public func remove(id: String) async throws {
        var entries = try await loadAll()
        entries.removeAll { $0.id == id }
        try await save(entries)
    }
}
