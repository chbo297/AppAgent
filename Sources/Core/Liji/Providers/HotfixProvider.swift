//
//  HotfixProvider.swift
//  OpenAPP — Liji 集成层
//
//  宿主 app（百度地图·增强版 BMBandage）实现，向 app agent 暴露「热修复」能力：
//  应用/开关/列举命名 JS 补丁槽。默认关闭，需 LijiConfig.hotfixEnabled 打开。
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
    /// 应用一段 JS 补丁到命名槽；applyMode 由服务端建议（instant/restart）。
    func apply(name: String, javascript: String, applyMode: String, summary: String) async -> HotfixApplyResult
    /// 开/关某命名补丁槽（重启生效被视为可接受）。
    func setEnabled(name: String, enabled: Bool) async -> Bool
    /// 列出已安装的补丁槽。
    func list() async -> [HotfixPatchInfo]
    /// 移除某命名补丁槽。
    func remove(name: String) async -> Bool
}
