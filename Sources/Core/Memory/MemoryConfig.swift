//
//  MemoryConfig.swift
//  AppAgent
//

import Foundation

/// Configuration for the agent's memory system.
public struct MemoryConfig: Sendable {
    /// Whether long-term memory is enabled.
    public var longTermEnabled: Bool

    /// Maximum number of long-term memory entries to inject into context.
    public var longTermMaxEntries: Int

    /// Whether hot memory is enabled.
    public var hotMemoryEnabled: Bool

    /// Maximum character length for a single memory entry. Default: 2000.
    public var maxEntryLength: Int

    /// Directory for long-term memory persistence.
    /// nil = default Documents/AppAgent/memory/.
    public var storageDirectory: URL?

    public init(
        longTermEnabled: Bool = true,
        longTermMaxEntries: Int = 20,
        hotMemoryEnabled: Bool = true,
        maxEntryLength: Int = 2000,
        storageDirectory: URL? = nil
    ) {
        self.longTermEnabled = longTermEnabled
        self.longTermMaxEntries = longTermMaxEntries
        self.hotMemoryEnabled = hotMemoryEnabled
        self.maxEntryLength = maxEntryLength
        self.storageDirectory = storageDirectory
    }
}
