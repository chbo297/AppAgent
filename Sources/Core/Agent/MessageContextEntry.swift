//
//  MessageContextEntry.swift
//  AppAgent
//

import Foundation

/// A single piece of contextual metadata to inject into a user message.
/// Each entry becomes a `--- CONTEXT ENTRY BEGIN ---` block.
///
/// Example:
/// ```
/// --- CONTEXT ENTRY BEGIN ---
/// Current time: 2026-04-11T14:30:00.000Z
/// --- CONTEXT ENTRY END ---
/// ```
public struct MessageContextEntry: Sendable {
    /// The label for this context entry (e.g., "Current time", "User location").
    public let label: String
    /// The value of this context entry (e.g., "2026-04-11T14:30:00.000Z").
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}
