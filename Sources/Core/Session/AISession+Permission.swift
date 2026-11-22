//
//  AISession+Permission.swift
//  AppAgent
//
//  会话的权限状态：读、改、以及执行前的「需要时弹卡询问」。
//

import Foundation

extension AISession {
    /// 权限状态变化时 `uiState` 发出的 key，设置页据此刷新。
    public static let permissionsChangedKey = "permissionGrants"

    /// 宿主登记的全部权限（设置页按这个顺序展示）。没有登记时为空。
    public var registeredPermissions: [AppAgentPermission] {
        agentMask?.profile.toolPermissionPolicy?.permissions ?? []
    }

    /// 一项权限在本会话里的生效状态。始终允许优先；委派任务继承父会话的本会话授权。
    public func permissionGrant(for permission: AppAgentPermission) -> AppAgentPermissionGrant {
        if permissionStore.isAlwaysAllowed(permission.id) {
            return .always
        }
        var current: AISession? = self
        var depth = 0
        while let session = current, depth < 32 {
            if session.permissionGrants.contains(permission.id) {
                return .session
            }
            current = session.decisionParent
            depth += 1
        }
        return .ask
    }

    /// 修改一项权限。`.always` 写入设备级记录，`.ask` 同时撤销本会话和始终允许。
    public func setPermissionGrant(_ grant: AppAgentPermissionGrant, for permission: AppAgentPermission) {
        let id = permission.id
        switch grant {
        case .ask:
            $permissionGrants.mutate { grants in
                grants.remove(id)
            }
            permissionStore.setAlwaysAllowed(false, for: id)
        case .session:
            $permissionGrants.mutate { grants in
                grants.insert(id)
            }
            permissionStore.setAlwaysAllowed(false, for: id)
        case .always:
            $permissionGrants.mutate { grants in
                grants.remove(id)
            }
            permissionStore.setAlwaysAllowed(true, for: id)
        }
        uiState.set(Self.permissionsChangedKey, value: permissionGrants.sorted())
    }

    /// 本次调用需要的权限；宿主没有登记策略时为 nil。
    func requiredPermission(for tool: any ToolProtocol, arguments: [String: JSONValue]) -> AppAgentPermission? {
        agentMask?.profile.toolPermissionPolicy?.requiredPermission(
            for: tool, arguments: arguments, session: self
        )
    }

    /// 已授权直接放行；否则弹权限卡。返回 nil 表示可以执行，否则是给模型的拒绝原因。
    func authorizePermission(
        _ permission: AppAgentPermission, tool: String, detail: String?
    ) async -> String? {
        if permissionGrant(for: permission) != .ask {
            return nil
        }
        // 委派任务只能用父会话已有的授权，不能借子任务的目标再申请新权限。
        if decisionParent != nil {
            return "委派任务不能申请新的「\(permission.title)」权限。请回到主会话，由用户授权后再执行。"
        }
        let outcome = await requestDecision(.permission(permission, tool: tool, detail: detail))
        switch outcome {
        case .allowOnce:
            Logger.info("AISession", "permissionAllowedOnce: \(permission.id), tool=\(tool)")
            return nil
        case .allowForSession:
            setPermissionGrant(.session, for: permission)
            Logger.info("AISession", "permissionAllowedForSession: \(permission.id)")
            return nil
        case .allowAlways:
            setPermissionGrant(.always, for: permission)
            Logger.info("AISession", "permissionAllowedAlways: \(permission.id)")
            return nil
        case .deny, .answer:
            Logger.info("AISession", "permissionDenied: \(permission.id), tool=\(tool)")
            return "用户没有授予「\(permission.title)」权限，\(tool) 未执行。不要换别的工具绕过；"
                + "如确有需要，向用户说明原因后再请求。"
        }
    }

    private var permissionStore: AppAgentPermissionStore {
        agentMask?.profile.permissionStore ?? .shared
    }
}
