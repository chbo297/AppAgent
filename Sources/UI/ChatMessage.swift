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
    /// 是否隐藏「成功完成轮」的过程入口（小三角 + 「处理过程」标题）。
    ///
    /// 由「总是显示思考过程」设置关闭时、组装器对 `.answered` 成功轮置位。报错 / 异常回合
    /// 不受影响（此值恒为 false），仍保留过程入口。cell 渲染时与 `shouldDisplayActivity`
    /// 取与：只有「结构上有内容可展示」且「未被本开关抑制」才显示过程区。
    public var suppressResolvedActivity: Bool

    public init(
        role: Role,
        text: String,
        status: Status = .complete,
        turnID: Int? = nil,
        activity: AppAgentActivityTimeline? = nil,
        isActivityExpanded: Bool = false,
        suppressResolvedActivity: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.status = status
        self.timestamp = Date()
        self.turnID = turnID
        self.activity = activity
        self.isActivityExpanded = isActivityExpanded
        self.suppressResolvedActivity = suppressResolvedActivity
    }

    /// 两条气泡的**展示内容**是否等价（忽略每次组装都会变的 `id` 与 `timestamp`）。
    ///
    /// 用于「重新展示同一份内容」（收起后再展开、冗余刷新）时判断能否跳过整表重建：
    /// 内容一致就保留旧 `id` 与行高缓存命中，不做全量重测。
    func hasEquivalentContent(to other: ChatMessage) -> Bool {
        role == other.role
            && status == other.status
            && text == other.text
            && turnID == other.turnID
            && isActivityExpanded == other.isActivityExpanded
            && suppressResolvedActivity == other.suppressResolvedActivity
            && activity == other.activity
    }
}
#endif
