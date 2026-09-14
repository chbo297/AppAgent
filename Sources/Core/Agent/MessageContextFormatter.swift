//
//  MessageContextFormatter.swift
//  AppAgent
//

import Foundation

/// Formats message context entries and user text into the wrapped message format.
///
/// Output format (when entries are present):
/// ```
/// --- CONTEXT ENTRY BEGIN ---
/// Current time: 2026-04-11T14:30:00.000Z
/// --- CONTEXT ENTRY END ---
///
/// --- CONTEXT ENTRY BEGIN ---
/// User location: Tokyo, Japan
/// --- CONTEXT ENTRY END ---
///
/// --- USER MESSAGE BEGIN ---
/// actual user message here
/// --- USER MESSAGE END ---
/// ```
///
/// When no entries are present, returns the raw user text unchanged (zero overhead).
enum MessageContextFormatter {

    static func format(entries: [MessageContextEntry], userText: String) -> String {
        guard !entries.isEmpty else { return userText }

        var parts: [String] = []

        for entry in entries {
            parts.append(
                "--- CONTEXT ENTRY BEGIN ---\n\(entry.label): \(entry.value)\n--- CONTEXT ENTRY END ---"
            )
        }

        parts.append(
            "--- USER MESSAGE BEGIN ---\n\(userText)\n--- USER MESSAGE END ---"
        )

        return parts.joined(separator: "\n\n")
    }
}
