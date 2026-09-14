//
//  PromptBuilder.swift
//  AppAgent
//

import Foundation

/// A builder for a single segment of the system prompt.
///
/// Each builder produces either static text or dynamic content resolved at prompt-assembly time.
/// The optional `name` is for identification only and is NOT included in the final system prompt.
public struct PromptBuilder: Sendable {

    /// Optional label for identification/debugging. Not included in the assembled prompt.
    public let name: String?

    /// The content of this prompt segment.
    public enum Content: Sendable {
        /// Static text appended as-is.
        case text(String)
        /// Dynamic closure evaluated with the current AISession. Returns nil to skip.
        case closure(@Sendable (AISession) async -> String?)
    }

    /// The content of this builder (immutable after init).
    public let content: Content

    /// Create a builder with anonymous static text.
    public init(_ text: String) {
        self.name = nil
        self.content = .text(text)
    }

    /// Create a named builder with static text.
    public init(_ name: String, prompt: String) {
        self.name = name
        self.content = .text(prompt)
    }

    /// Create a named builder with a dynamic closure.
    public init(_ name: String, resolver: @escaping @Sendable (AISession) async -> String?) {
        self.name = name
        self.content = .closure(resolver)
    }
}
