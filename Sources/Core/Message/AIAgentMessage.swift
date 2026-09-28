//
//  AIAgentMessage.swift
//  AppAgent
//

import Foundation

// MARK: - Message Role

public enum AIAgentMessageRole: String, Sendable, Codable {
    case user
    case assistant
}

public enum AIAgentMessageType: String, Sendable, Codable {
    case user
    case assistant
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case hostStateSnapshot = "host_state_snapshot"
    case hostStateDelta = "host_state_delta"
    case hostEvent = "host_event"
}

public enum AIAgentMessageSource: String, Sendable, Codable {
    case user
    case agent
    case tool
    case host
    case app
}

public enum AIAgentMessageDisplayPolicy: String, Sendable, Codable {
    case normal
    case collapsed
    case hidden
}

// MARK: - Message

/// A provider-agnostic conversation message.
public struct AIAgentMessage: Sendable, Codable {
    public let id: String
    public let role: AIAgentMessageRole
    public let content: [Content]
    public let createdAt: Date
    public let messageType: AIAgentMessageType
    public let source: AIAgentMessageSource
    public let displayPolicy: AIAgentMessageDisplayPolicy
    public let trigger: String?
    public let eventId: String?
    public let stateCursor: StateCursor?
    public let causedByToolCallId: String?

    /// 这条消息属于哪一轮「用户提问 → agent 答复」。
    ///
    /// 与 LLM 的来回（assistant 的工具调用、user 角色的工具结果）都属于**同一轮**：
    /// 它们是一次提问内部的过程，不是用户又说了话。UI 依赖这个归属把过程收进
    /// agent 自己的过程区，而不是把工具结果渲染成用户气泡。
    ///
    /// `nil` = 本字段引入之前持久化的旧快照；UI 侧按顺序回退推导，不影响解码。
    public let turnID: Int?

    public init(
        id: String = UUID().uuidString,
        role: AIAgentMessageRole,
        content: [Content],
        createdAt: Date = Date(),
        turnID: Int? = nil,
        messageType: AIAgentMessageType? = nil,
        source: AIAgentMessageSource? = nil,
        displayPolicy: AIAgentMessageDisplayPolicy? = nil,
        trigger: String? = nil,
        eventId: String? = nil,
        stateCursor: StateCursor? = nil,
        causedByToolCallId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.turnID = turnID
        let inferredType = messageType ?? Self.inferMessageType(
            role: role,
            content: content
        )
        self.messageType = inferredType
        self.source = source ?? Self.inferSource(for: inferredType)
        self.displayPolicy = displayPolicy ?? Self.inferDisplayPolicy(for: inferredType)
        self.trigger = trigger
        self.eventId = eventId
        self.stateCursor = stateCursor ?? Self.inferCursor(from: content)
        self.causedByToolCallId = causedByToolCallId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt
        case turnID
        case messageType
        case source
        case displayPolicy
        case trigger
        case eventId
        case stateCursor
        case causedByToolCallId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(AIAgentMessageRole.self, forKey: .role)
        let content = try container.decode([Content].self, forKey: .content)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            role: role,
            content: content,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            turnID: try container.decodeIfPresent(Int.self, forKey: .turnID),
            messageType: try container.decodeIfPresent(
                AIAgentMessageType.self,
                forKey: .messageType
            ),
            source: try container.decodeIfPresent(
                AIAgentMessageSource.self,
                forKey: .source
            ),
            displayPolicy: try container.decodeIfPresent(
                AIAgentMessageDisplayPolicy.self,
                forKey: .displayPolicy
            ),
            trigger: try container.decodeIfPresent(String.self, forKey: .trigger),
            eventId: try container.decodeIfPresent(String.self, forKey: .eventId),
            stateCursor: try container.decodeIfPresent(
                StateCursor.self,
                forKey: .stateCursor
            ),
            causedByToolCallId: try container.decodeIfPresent(
                String.self,
                forKey: .causedByToolCallId
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(messageType, forKey: .messageType)
        try container.encode(source, forKey: .source)
        try container.encode(displayPolicy, forKey: .displayPolicy)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(eventId, forKey: .eventId)
        try container.encodeIfPresent(stateCursor, forKey: .stateCursor)
        try container.encodeIfPresent(causedByToolCallId, forKey: .causedByToolCallId)
    }

    // MARK: - Convenience initializers

    /// Create a simple text message.
    public static func user(
        _ text: String,
        turnID: Int? = nil
    ) -> AIAgentMessage {
        AIAgentMessage(
            role: .user,
            content: [.text(text)],
            turnID: turnID,
            messageType: .user,
            source: .user,
            displayPolicy: .normal
        )
    }

    public static func assistant(
        _ text: String,
        turnID: Int? = nil
    ) -> AIAgentMessage {
        AIAgentMessage(
            role: .assistant,
            content: [.text(text)],
            turnID: turnID,
            messageType: .assistant,
            source: .agent,
            displayPolicy: .normal
        )
    }

    public static func hostContext(
        _ payload: HostContextPayload,
        turnID: Int? = nil,
        displayPolicy: AIAgentMessageDisplayPolicy? = nil
    ) -> AIAgentMessage {
        hostContext(
            [payload],
            turnID: turnID,
            displayPolicy: displayPolicy
        )
    }

    public static func hostContext(
        _ payloads: [HostContextPayload],
        turnID: Int? = nil,
        displayPolicy: AIAgentMessageDisplayPolicy? = nil
    ) -> AIAgentMessage {
        precondition(!payloads.isEmpty)
        let payload = payloads[0]
        let type: AIAgentMessageType
        let source: AIAgentMessageSource
        let trigger: String?
        let eventId: String?
        let cursor: StateCursor?
        let resolvedPolicy: AIAgentMessageDisplayPolicy

        switch payload {
        case .snapshot(let snapshot):
            type = .hostStateSnapshot
            source = .host
            trigger = nil
            eventId = nil
            cursor = snapshot.cursor
            resolvedPolicy = displayPolicy ?? .hidden
        case .delta(let delta):
            type = .hostStateDelta
            source = .host
            trigger = nil
            eventId = nil
            cursor = delta.cursor
            resolvedPolicy = displayPolicy ?? .hidden
        case .event(let event):
            type = .hostEvent
            source = .app
            trigger = event.trigger
            eventId = event.eventId
            cursor = event.cursor
            resolvedPolicy = displayPolicy ?? event.displayPolicy
        }

        let content = payloads.map { payload in
            Content.hostContext(payload)
        }
        return AIAgentMessage(
            role: .user,
            content: content,
            turnID: turnID,
            messageType: type,
            source: source,
            displayPolicy: resolvedPolicy,
            trigger: trigger,
            eventId: eventId,
            stateCursor: cursor
        )
    }

    /// 这条消息是不是「用户真的说了话」。
    ///
    /// 工具结果在 wire 上同样走 `.user` 角色，所以不能只看 role。
    public var isGenuineUserInput: Bool {
        messageType == .user
            && source == .user
            && displayPolicy == .normal
    }

    /// Extract the concatenated text from all `.text` parts.
    public var text: String {
        content.compactMap { part in
            if case .text(let value) = part {
                return value
            }
            return nil
        }.joined()
    }

    /// Extract all tool calls from this message.
    public var toolCalls: [ToolCall] {
        content.compactMap { part in
            if case .toolUse(let call) = part {
                return call
            }
            return nil
        }
    }

    public var hostContextPayloads: [HostContextPayload] {
        content.compactMap { part in
            if case .hostContext(let payload) = part {
                return payload
            }
            return nil
        }
    }

    public var isHostContext: Bool {
        messageType == .hostStateSnapshot
            || messageType == .hostStateDelta
            || messageType == .hostEvent
    }

    private static func inferMessageType(
        role: AIAgentMessageRole,
        content: [Content]
    ) -> AIAgentMessageType {
        if let payload = content.compactMap({ part -> HostContextPayload? in
            if case .hostContext(let value) = part {
                return value
            }
            return nil
        }).first {
            switch payload {
            case .snapshot:
                return .hostStateSnapshot
            case .delta:
                return .hostStateDelta
            case .event:
                return .hostEvent
            }
        }

        if role == .assistant {
            let containsToolUse = content.contains { part in
                if case .toolUse = part {
                    return true
                }
                return false
            }
            return containsToolUse ? .toolCall : .assistant
        }

        let containsToolResult = content.contains { part in
            if case .toolResult = part {
                return true
            }
            return false
        }
        return containsToolResult ? .toolResult : .user
    }

    private static func inferSource(
        for messageType: AIAgentMessageType
    ) -> AIAgentMessageSource {
        switch messageType {
        case .user:
            return .user
        case .assistant, .toolCall:
            return .agent
        case .toolResult:
            return .tool
        case .hostStateSnapshot, .hostStateDelta:
            return .host
        case .hostEvent:
            return .app
        }
    }

    private static func inferDisplayPolicy(
        for messageType: AIAgentMessageType
    ) -> AIAgentMessageDisplayPolicy {
        switch messageType {
        case .user, .assistant:
            return .normal
        case .hostEvent:
            return .collapsed
        case .toolCall, .toolResult, .hostStateSnapshot, .hostStateDelta:
            return .hidden
        }
    }

    private static func inferCursor(
        from content: [Content]
    ) -> StateCursor? {
        for part in content {
            guard case .hostContext(let payload) = part else {
                continue
            }
            switch payload {
            case .snapshot(let snapshot):
                return snapshot.cursor
            case .delta(let delta):
                return delta.cursor
            case .event(let event):
                return event.cursor
            }
        }
        return nil
    }
}

// MARK: - Nested Types

extension AIAgentMessage {

    /// A single part of a message's content.
    public enum Content: Sendable, Codable {
        /// Plain text content.
        case text(String)
        /// A tool invocation requested by the assistant.
        case toolUse(ToolCall)
        /// The result of a tool invocation, sent back to the model.
        case toolResult(ToolCallResult)
        /// Structured host state or event content.
        case hostContext(HostContextPayload)

        // MARK: - Codable

        private enum ContentType: String, Codable {
            case text
            case toolUse
            case toolResult
            case hostContext
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case toolCall
            case toolResult
            case hostContext
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(ContentType.self, forKey: .type)
            switch type {
            case .text:
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case .toolUse:
                let call = try container.decode(ToolCall.self, forKey: .toolCall)
                self = .toolUse(call)
            case .toolResult:
                let result = try container.decode(ToolCallResult.self, forKey: .toolResult)
                self = .toolResult(result)
            case .hostContext:
                let payload = try container.decode(
                    HostContextPayload.self,
                    forKey: .hostContext
                )
                self = .hostContext(payload)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(ContentType.text, forKey: .type)
                try container.encode(text, forKey: .text)
            case .toolUse(let call):
                try container.encode(ContentType.toolUse, forKey: .type)
                try container.encode(call, forKey: .toolCall)
            case .toolResult(let result):
                try container.encode(ContentType.toolResult, forKey: .type)
                try container.encode(result, forKey: .toolResult)
            case .hostContext(let payload):
                try container.encode(ContentType.hostContext, forKey: .type)
                try container.encode(payload, forKey: .hostContext)
            }
        }
    }

    /// Represents a tool invocation from the assistant.
    public struct ToolCall: Sendable, Codable {
        public let id: String
        public let name: String
        public let arguments: [String: JSONValue]

        public init(id: String, name: String, arguments: [String: JSONValue]) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    /// Represents the result sent back after executing a tool.
    public struct ToolCallResult: Sendable, Codable {
        public let toolCallId: String
        public let content: String
        /// 工具随结果附带的图片（截图等）。走 provider 的多模态通道，不占文本预算。
        public let images: [ImageAttachment]
        /// 这一步是不是失败了。展示层据此把过程区里的步骤标红。
        public let isError: Bool

        public init(
            toolCallId: String,
            content: String,
            images: [ImageAttachment] = [],
            isError: Bool = false
        ) {
            self.toolCallId = toolCallId
            self.content = content
            self.images = images
            self.isError = isError
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
            self.content = try container.decode(String.self, forKey: .content)
            self.images = try container.decodeIfPresent(
                [ImageAttachment].self,
                forKey: .images
            ) ?? []
            let decodedContent = self.content
            self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
                ?? Self.looksLikeError(decodedContent)
        }

        /// 旧快照兜底判定，仅在缺 `isError` 键时使用。
        public static func looksLikeError(_ content: String) -> Bool {
            content.hasPrefix("Error:")
                || content.hasPrefix("Error：")
        }
    }

    /// 一张随 tool result 回传的图片。存 base64 以便随 session 快照一起持久化。
    public struct ImageAttachment: Sendable, Codable, Equatable {
        public let base64: String
        public let mediaType: String

        public init(base64: String, mediaType: String) {
            self.base64 = base64
            self.mediaType = mediaType
        }

        public init(data: Data, mediaType: String) {
            self.base64 = data.base64EncodedString()
            self.mediaType = mediaType
        }
    }
}
