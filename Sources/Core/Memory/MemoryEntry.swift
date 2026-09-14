//
//  MemoryEntry.swift
//  AppAgent
//

import Foundation

/// A single memory entry stored in the agent's long-term memory.
public struct MemoryEntry: Sendable, Codable {
    public let id: String
    public let content: String
    public let tags: [String]
    public let createdAt: Date
    public let source: MemorySource

    public enum MemorySource: String, Codable, Sendable {
        /// Explicitly saved by user or host app.
        case user
        /// Auto-extracted from conversation by the agent.
        case aiAgent
        /// Injected by system (e.g., user preferences).
        case system
    }

    public init(
        id: String = UUID().uuidString,
        content: String,
        tags: [String] = [],
        createdAt: Date = Date(),
        source: MemorySource = .user
    ) {
        self.id = id
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.source = source
    }
}
