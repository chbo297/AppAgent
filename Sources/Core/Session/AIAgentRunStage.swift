//
//  AIAgentRunStage.swift
//  AppAgent
//
//  一轮对话（一次提问到本轮结束）在执行流水线上的位置。
//
//  为什么要显式建模：卡住时「停在哪一步」是唯一有用的信息。以前 UI 只能看到
//  `isStreaming == true`，于是「请求还没发出去」「发出去了没首字」「工具在跑」
//  三种完全不同的卡法在界面上长得一模一样（都是一个 "…"）。
//
//  阶段是**单调前进**的（`order` 只增不减），一轮里工具往返多次时会在
//  `.streaming` ↔ `.tooling` 之间来回，所以 UI 的指示条按 order 判「已过」，
//  不按「到过一次就点亮」。
//

import Foundation

public enum AIAgentRunStage: String, Sendable, Equatable, CaseIterable, Codable {

    /// 组装 system prompt / 工具清单 / 消息上下文，还没发请求。
    case preparing

    /// 请求已发出，等模型的第一个内容（首字 / 首个工具调用）。
    case requesting

    /// 模型正在流式吐内容。
    case streaming

    /// 本轮里在执行工具（可能在等用户授权）。
    case tooling

    /// 本轮结束。
    case finished

    /// 流水线次序，UI 按它判断某一步是否已经走过。
    public var order: Int {
        switch self {
        case .preparing:  return 0
        case .requesting: return 1
        case .streaming:  return 2
        case .tooling:    return 3
        case .finished:   return 4
        }
    }

    /// 日志与诊断包里用的稳定短名。
    public var logLabel: String { rawValue }
}
