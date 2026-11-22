//
//  ToolPermission.swift
//  AppAgent
//
//  按「权限类别」授权：宿主登记有哪些权限、哪次调用需要哪项权限；
//  SDK 负责弹卡询问、记住授权（单次 / 本会话 / 本设备始终）并在设置页展示。
//

import Foundation

/// 一类需要用户授权的能力，例如「修改 App 运行时」。由宿主定义。
public struct AppAgentPermission: Sendable, Hashable, Codable {
    /// 稳定标识，用作授权记录的键。改名会让已有授权失效。
    public let id: String
    /// 卡片和设置页上的名称。
    public let title: String
    /// 一句话说明允许后 agent 能做什么。
    public let summary: String

    public init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}

/// 一项权限在某个会话里的生效状态。
public enum AppAgentPermissionGrant: String, Sendable, Codable, CaseIterable {
    /// 每次使用前询问。
    case ask
    /// 在本会话中允许。
    case session
    /// 本设备上所有会话始终允许。
    case always
}

/// 宿主声明「哪些调用需要哪项权限」。挂在 `AIAgentProfile.toolPermissionPolicy`。
///
/// 只描述需要什么，不做拦截：拒绝仍由 `ToolExecutionGate` 负责，询问和记忆由 SDK 负责。
public protocol ToolPermissionPolicy: Sendable {
    /// 设置页展示的全部权限，顺序即展示顺序。
    var permissions: [AppAgentPermission] { get }

    /// 本次调用需要的权限；返回 nil 表示不需要权限，继续走原有的安全级别检查。
    func requiredPermission(
        for tool: any ToolProtocol,
        arguments: [String: JSONValue],
        session: AISession
    ) -> AppAgentPermission?
}

/// 「始终允许」的设备级记录，所有会话共用。
public final class AppAgentPermissionStore: @unchecked Sendable {
    public static let shared = AppAgentPermissionStore()

    /// 授权变化后发出；object 是发生变化的 store。
    public static let didChangeNotification = Notification.Name("AppAgentPermissionStoreDidChange")

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "appagent.permissions.always.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// 当前始终允许的权限 id。
    public var alwaysAllowedIDs: Set<String> {
        lock.lock()
        defer {
            lock.unlock()
        }
        return Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func isAlwaysAllowed(_ permissionID: String) -> Bool {
        alwaysAllowedIDs.contains(permissionID)
    }

    public func setAlwaysAllowed(_ allowed: Bool, for permissionID: String) {
        lock.lock()
        var ids = Set(defaults.stringArray(forKey: key) ?? [])
        let changed = allowed ? ids.insert(permissionID).inserted : ids.remove(permissionID) != nil
        if changed {
            defaults.set(ids.sorted(), forKey: key)
        }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
