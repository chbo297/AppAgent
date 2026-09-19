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
    /// 这条气泡属于哪一轮提问（`AIAgentMessage.turnID`）。
    ///
    /// `id` 每次组装都是新的 UUID，所以「用户手动展开了哪一轮的过程区」这类跨重建的
    /// 状态只能挂在 turnID 上。乐观插入的气泡还不知道 Core 会发几号，先留 nil，
    /// 本轮结束后由 `ChatMessageAssembler` 补上。
    public let turnID: Int?
    /// 本轮的「思考 / 执行过程」时间线（assistant 消息才有）。
    public var activity: AppAgentActivityTimeline?
    /// 过程区是否展开：进行中的最新一轮默认展开，结束后自动折叠成摘要。
    public var isActivityExpanded: Bool

    public init(
        role: Role,
        text: String,
        status: Status = .complete,
        turnID: Int? = nil,
        activity: AppAgentActivityTimeline? = nil,
        isActivityExpanded: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.status = status
        self.timestamp = Date()
        self.turnID = turnID
        self.activity = activity
        self.isActivityExpanded = isActivityExpanded
    }
}
#endif
