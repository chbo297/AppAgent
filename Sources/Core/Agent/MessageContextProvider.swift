//
//  MessageContextProvider.swift
//  AppAgent
//

import Foundation

/// Protocol for providing per-message context entries at execution time.
///
/// Implementations are called each time a user message is about to be sent to the LLM.
/// The returned entries are volatile — they may change with every call.
///
/// Examples: current date/time, GPS location, visible map region, app state.
public protocol MessageContextProvider: Sendable {
    /// Return the current context entries.
    /// Called on every user message send. Return an empty array to inject nothing.
    func messageContext() async -> [MessageContextEntry]
}

/// Convenience implementation wrapping a Sendable async closure.
public struct ClosureMessageContextProvider: MessageContextProvider, Sendable {
    private let closure: @Sendable () async -> [MessageContextEntry]

    public init(_ closure: @Sendable @escaping () async -> [MessageContextEntry]) {
        self.closure = closure
    }

    public func messageContext() async -> [MessageContextEntry] {
        await closure()
    }
}
