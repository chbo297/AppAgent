//
//  SSEParser.swift
//  AppAgent
//

import Foundation

public struct SSEEvent: Sendable {
    public let event: String
    public let data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// Line-by-line SSE parser. Feed lines from URLSession.AsyncBytes.lines,
/// get back parsed SSEEvent when a complete event is received.
public struct SSEParser {
    private var currentEvent: String = ""
    private var currentData: String = ""

    public init() {}

    /// Feed a single line. Returns an SSEEvent if a complete event was parsed.
    public mutating func processLine(_ line: String) -> SSEEvent? {
        if line.hasPrefix("event:") {
            // A new event starting — if we already have a complete event buffered, emit it first
            let previous = emitIfReady()
            let value = line.dropFirst(6)
            currentEvent = String(value.first == " " ? value.dropFirst() : value)
            return previous
        }
        if line.hasPrefix("data:") {
            // A new `data:` line also delimits an event. Some transports
            // (notably URLSession.AsyncBytes.lines) do not surface the blank
            // separator line between SSE events, so `data:`-only streams
            // (OpenAI chat/completions chunks) would otherwise keep
            // overwriting the buffer and never emit. Flush the buffered
            // event first, then start accumulating the new one.
            let previous = emitIfReady()
            let value = line.dropFirst(5)
            currentData = String(value.first == " " ? value.dropFirst() : value)
            return previous
        }
        // Empty line = event boundary (standard SSE)
        if line.isEmpty {
            return emitIfReady()
        }
        return nil
    }

    /// Flush any remaining buffered event.
    public mutating func flush() -> SSEEvent? {
        return emitIfReady()
    }

    private mutating func emitIfReady() -> SSEEvent? {
        guard !currentData.isEmpty else { return nil }
        let event = SSEEvent(event: currentEvent, data: currentData)
        currentEvent = ""
        currentData = ""
        return event
    }
}
