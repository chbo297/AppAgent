//
//  SessionStorage.swift
//  AppAgent
//

import Foundation

// MARK: - AISession Storage Protocol

/// Abstraction for session persistence.
public protocol SessionStorage: Sendable {
    func save(session: SessionSnapshot) async throws
    func load(id: String) async throws -> SessionSnapshot?
    func loadAll() async throws -> [SessionSnapshot]
    func delete(id: String) async throws
}

/// A serializable snapshot of a session for persistence.
/// Uses AIAgentMessage directly (which is Codable) for full-fidelity round-trip persistence
/// including tool calls and tool results.
public struct SessionSnapshot: Sendable, Codable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messages: [AIAgentMessage]
    public let metadata: [String: String]?

    public init(id: String, title: String, createdAt: Date, updatedAt: Date,
                messages: [AIAgentMessage], metadata: [String: String]? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.metadata = metadata
    }
}

// MARK: - In-Memory Storage (for testing)

/// Simple in-memory storage implementation.
public actor InMemorySessionStorage: SessionStorage {
    private var sessions: [String: SessionSnapshot] = [:]

    public init() {}

    public func save(session: SessionSnapshot) async throws {
        sessions[session.id] = session
    }

    public func load(id: String) async throws -> SessionSnapshot? {
        sessions[id]
    }

    public func loadAll() async throws -> [SessionSnapshot] {
        Array(sessions.values)
    }

    public func delete(id: String) async throws {
        sessions.removeValue(forKey: id)
    }
}

// MARK: - File-Based Storage

/// File-based session storage using JSON files.
/// Degrades gracefully: corrupted files are skipped during loadAll.
public actor FileSessionStorage: SessionStorage {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.directory = docs.appendingPathComponent("AppAgent/sessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func save(session: SessionSnapshot) async throws {
        let url = directory.appendingPathComponent("\(session.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
    }

    public func load(id: String) async throws -> SessionSnapshot? {
        let url = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionSnapshot.self, from: data)
    }

    public func loadAll() async throws -> [SessionSnapshot] {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files.compactMap { url -> SessionSnapshot? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SessionSnapshot.self, from: data)
        }
    }

    public func delete(id: String) async throws {
        let url = directory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
