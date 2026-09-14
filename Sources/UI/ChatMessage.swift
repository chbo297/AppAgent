//
//  ChatMessage.swift
//  AppAgentUI
//

#if canImport(UIKit)
import Foundation

public struct ChatMessage {
    public enum Role {
        case user
        case assistant
    }

    public enum Status {
        case complete
        case streaming
        case error
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var status: Status
    public let timestamp: Date
    /// Optional tool call summary for displaying in conversation history.
    public var toolInfo: String?

    public init(role: Role, text: String, status: Status = .complete, toolInfo: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.status = status
        self.timestamp = Date()
        self.toolInfo = toolInfo
    }
}
#endif
