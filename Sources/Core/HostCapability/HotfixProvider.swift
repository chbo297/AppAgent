//
//  HotfixProvider.swift
//  AppAgent — 宿主能力层
//
//  宿主 app 实现后，向 app agent 暴露命名 JS 补丁槽的应用、开关和列举能力。
//  默认关闭，需宿主显式打开（HostToolset 的 hotfixEnabled）。
//

import Foundation

/// 单个补丁槽信息。
public struct HotfixPatchInfo: Sendable, Codable {
    public var name: String
    public var enabled: Bool
    public var summary: String
    /// "instant"（立即 eval 生效）| "restart"（需重启生效）。
    public var applyMode: String

    public init(name: String, enabled: Bool, summary: String, applyMode: String) {
        self.name = name
        self.enabled = enabled
        self.summary = summary
        self.applyMode = applyMode
    }
}

/// 应用补丁的结果。
public struct HotfixApplyResult: Sendable, Codable {
    public var success: Bool
    public var applyMode: String
    public var message: String
    /// 是否需要重启 app 才能完全生效。
    public var needsRestart: Bool

    public init(success: Bool, applyMode: String, message: String, needsRestart: Bool) {
        self.success = success
        self.applyMode = applyMode
        self.message = message
        self.needsRestart = needsRestart
    }
}

public protocol HotfixProvider: Sendable {
    // Providers must enforce context for slot metadata AND execution. Re-enabling a patch
    // cannot broaden its original scope or reuse an earlier turn's tool approval.
    /// 应用一段 JS 补丁到命名槽；applyMode 由服务端建议（instant/restart）。
    func apply(name: String, javascript: String, applyMode: String, summary: String, context: HostInspectionContext) async -> HotfixApplyResult
    /// 开/关某命名补丁槽（重启生效被视为可接受）。
    func setEnabled(name: String, enabled: Bool, context: HostInspectionContext) async -> Bool
    /// 列出已安装的补丁槽。
    func list(context: HostInspectionContext) async -> [HotfixPatchInfo]
    /// 移除某命名补丁槽。
    func remove(name: String, context: HostInspectionContext) async -> Bool
}
