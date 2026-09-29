//
//  AIAgentExecutionPolicy.swift
//  AppAgent
//

import Foundation

/// Execution and safety settings captured by a session at creation time.
///
/// `AIAgentProfile` remains mutable so hosts can change defaults for future
/// sessions. A session receives a value copy of this policy and keeps using it
/// for its entire lifetime.
public struct AIAgentExecutionPolicy: Sendable, Codable {
    public static let defaultMaxIterations = 70
    public static let defaultToolTimeout: TimeInterval = 60
    public static let defaultStreamIdleTimeout: TimeInterval = 25
    public static let defaultToolOutputMaxBytes = 8192
    public static let defaultAutoPersist = true
    public static let defaultToolMutationPolicy: Tool.MutationPolicy = .allowed

    public static let `default` = AIAgentExecutionPolicy()

    /// Shared budget for model requests, tool follow-ups, retries, and fallbacks.
    public var maxIterations: Int

    /// Maximum duration of one tool execution.
    public var toolTimeout: TimeInterval

    /// 流式响应里相邻两个事件之间允许的最大间隔（秒）。超过就判这条流卡死、按可重试错误处理。
    ///
    /// 这是「切后台回来界面不动」的兜底闸门：进程被冻结期间连接基本已经死了，而 URLSession
    /// 既不吐数据也不报错，只靠 `requestTimeout`（默认 300s）兜底的话用户要干等 5 分钟。
    /// 判据用墙钟，挂起时长计入空闲，所以回前台后一个 tick 内就会判出来（见 `StreamIdleGuard`）。
    /// `<= 0` 关闭看门狗。默认 25s：比首 token 的正常等待（含网关排队）留足余量，又远小于 300s。
    public var streamIdleTimeout: TimeInterval

    /// Agent-wide UTF-8 byte cap for one tool result.
    public var toolOutputMaxBytes: Int

    /// Whether completed runs are automatically persisted.
    public var autoPersist: Bool

    /// Runtime mutation boundary enforced before a tool executes.
    public var toolMutationPolicy: Tool.MutationPolicy

    public init(
        maxIterations: Int = AIAgentExecutionPolicy.defaultMaxIterations,
        toolTimeout: TimeInterval = AIAgentExecutionPolicy.defaultToolTimeout,
        streamIdleTimeout: TimeInterval = AIAgentExecutionPolicy.defaultStreamIdleTimeout,
        toolOutputMaxBytes: Int = AIAgentExecutionPolicy.defaultToolOutputMaxBytes,
        autoPersist: Bool = AIAgentExecutionPolicy.defaultAutoPersist,
        toolMutationPolicy: Tool.MutationPolicy = AIAgentExecutionPolicy.defaultToolMutationPolicy
    ) {
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.streamIdleTimeout = streamIdleTimeout
        self.toolOutputMaxBytes = toolOutputMaxBytes
        self.autoPersist = autoPersist
        self.toolMutationPolicy = toolMutationPolicy
    }

    /// 逐字段 `decodeIfPresent`：会话快照是历史数据，加字段不能让整份策略解码失败
    /// （`SessionSnapshot` 用的是 `try?`，一失败就整块丢成 nil，连旧字段一起没了）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        maxIterations = try value(.maxIterations, Self.defaultMaxIterations)
        toolTimeout = try value(.toolTimeout, Self.defaultToolTimeout)
        streamIdleTimeout = try value(.streamIdleTimeout, Self.defaultStreamIdleTimeout)
        toolOutputMaxBytes = try value(.toolOutputMaxBytes, Self.defaultToolOutputMaxBytes)
        autoPersist = try value(.autoPersist, Self.defaultAutoPersist)
        toolMutationPolicy = try value(.toolMutationPolicy, Self.defaultToolMutationPolicy)
    }
}
