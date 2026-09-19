//
//  AIAgentDelegate.swift
//  AppAgent
//

import Foundation

/// 逐次授权的结果。历史名字，语义已并入 `DecisionOutcome`；保留一个 typealias
/// 免得宿主代码里到处改名。
public typealias ToolAuthorization = DecisionOutcome

/// Delegate protocol for agent lifecycle callbacks.
public protocol AIAgentDelegate: AnyObject, Sendable {
    /// Called when a new session is created.
    func aiAgent(_ aiAgent: AIAgent, didCreateSession session: AISession)

    /// Called when a session is deleted.
    func aiAgent(_ aiAgent: AIAgent, didDeleteSession sessionId: String)

    /// Called when a session completes an agent run.
    func aiAgent(_ aiAgent: AIAgent, session: AISession, didCompleteRun result: AIAgentFinish)

    /// Called when a run is rejected before it starts (e.g. the concurrency limit is reached).
    /// No run lifecycle callbacks follow a rejection.
    func aiAgent(_ aiAgent: AIAgent, session: AISession, didRejectRun error: Error)

    /// Called when a session encounters an error.
    func aiAgent(_ aiAgent: AIAgent, session: AISession, didEncounterError error: Error)

    /// 宿主**策略**钩子：在问用户之前，宿主有没有意见。
    ///
    /// 这是一个非交互的判断，不要在这里弹 UI —— 呈现由 AppAgent 自己的面板负责
    /// （`DecisionResponder`）。用它来表达与用户意愿无关的硬性规则，例如企业策略
    /// 「内网一律禁止，连问都不要问」。
    ///
    /// 返回 `nil`（默认）= 没有意见，交给用户决定。
    func aiAgent(_ aiAgent: AIAgent, session: AISession,
                 policyFor request: DecisionRequest) async -> DecisionOutcome?
}

// Default no-op implementations.
extension AIAgentDelegate {
    public func aiAgent(_ aiAgent: AIAgent, didCreateSession session: AISession) {}
    public func aiAgent(_ aiAgent: AIAgent, didDeleteSession sessionId: String) {}
    public func aiAgent(_ aiAgent: AIAgent, session: AISession, didCompleteRun result: AIAgentFinish) {}
    public func aiAgent(_ aiAgent: AIAgent, session: AISession, didRejectRun error: Error) {}
    public func aiAgent(_ aiAgent: AIAgent, session: AISession, didEncounterError error: Error) {}

    /// 默认：没有意见。注意这里**不是**「默认放行」——没有意见意味着继续往下问用户，
    /// 而没人能问时 `AISession.requestDecision` 兜底拒绝。
    public func aiAgent(_ aiAgent: AIAgent, session: AISession,
                        policyFor request: DecisionRequest) async -> DecisionOutcome? {
        nil
    }
}
