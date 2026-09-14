//
//  SystemPrompt.swift
//  AppAgent
//

import Foundation

/// Represents a single system prompt element in the final API request's system array.
public struct SystemPrompt: Sendable {
    /// The text content of this prompt element.
    public var text: String

    public init(_ text: String) {
        self.text = text
    }
}
