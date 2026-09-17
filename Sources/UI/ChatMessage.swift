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
    /// 本轮的「思考 / 执行过程」时间线（assistant 消息才有）。
    public var activity: AppAgentActivityTimeline?
    /// 过程区是否展开：进行中的最新一轮默认展开，结束后自动折叠成摘要。
    public var isActivityExpanded: Bool

    public init(
        role: Role,
        text: String,
        status: Status = .complete,
        toolInfo: String? = nil,
        activity: AppAgentActivityTimeline? = nil,
        isActivityExpanded: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.status = status
        self.timestamp = Date()
        self.toolInfo = toolInfo
        self.activity = activity
        self.isActivityExpanded = isActivityExpanded
    }
}
#endif
