//
//  LijiPanelDataSource.swift
//  AppAgent — Liji 集成层
//
//  「需求列表 / 分享给我的」面板的纯展示模型与构建逻辑（不依赖 UIKit，可在 swift test 覆盖）。
//  真正的 UIKit 视图见 Sources/UI/Liji/。
//

import Foundation

/// 单条需求在列表中的展示行。
public struct LijiRequirementRow: Sendable, Equatable, Identifiable {
    public enum StatusKind: String, Sendable {
        case pending, inProgress, patchGenerated, applied, disabled, failed, cancelled, unknown

        /// 面向用户的中文状态文案。
        public var displayText: String {
            switch self {
            case .pending: return "排队中"
            case .inProgress: return "生成中"
            case .patchGenerated: return "已生成补丁"
            case .applied: return "已应用"
            case .disabled: return "已停用"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            case .unknown: return "未知"
            }
        }

        init(rawStatus: String) {
            switch rawStatus {
            case "pending": self = .pending
            case "in_progress": self = .inProgress
            case "patch_generated": self = .patchGenerated
            case "applied": self = .applied
            case "disabled": self = .disabled
            case "failed": self = .failed
            case "cancelled": self = .cancelled
            default: self = .unknown
            }
        }
    }

    public let id: String
    public let taskTitle: String
    public let prompt: String
    public let summary: String
    public let error: String
    public let status: StatusKind
    public let patchId: String?
    public let applyMode: String?

    /// 是否可点「应用」（已生成补丁、尚未应用）。
    public var canApply: Bool { status == .patchGenerated && patchId != nil }
    /// 是否可点「分享」（有可分享的补丁）。
    public var canShare: Bool { patchId != nil && status != .failed && status != .cancelled }
    /// 是否可点「取消」（还没到终态）。
    public var canCancel: Bool { status == .pending || status == .inProgress }
    /// 是否可点「重新生成」（失败后允许重试）。
    public var canRegenerate: Bool { status == .failed }

    public init(id: String, taskTitle: String, prompt: String, summary: String, error: String,
                status: StatusKind, patchId: String?, applyMode: String?) {
        self.id = id
        self.taskTitle = taskTitle
        self.prompt = prompt
        self.summary = summary
        self.error = error
        self.status = status
        self.patchId = patchId
        self.applyMode = applyMode
    }
}

/// 单条「分享给我的」展示行。
public struct LijiGrantRow: Sendable, Equatable, Identifiable {
    public let id: String  // = token
    public let token: String
    public let title: String
    public let note: String
    public let owner: String
    public let enabled: Bool
    public let patchId: String?

    public init(token: String, title: String, note: String, owner: String, enabled: Bool, patchId: String?) {
        self.id = token
        self.token = token
        self.title = title
        self.note = note
        self.owner = owner
        self.enabled = enabled
        self.patchId = patchId
    }
}

public enum LijiPanelDataSource {

    /// 由「我的任务」DTO 列表展平出需求行，按更新时间新→旧。
    public static func requirementRows(from tasks: [LijiTaskDTO]) -> [LijiRequirementRow] {
        tasks.flatMap { task in
            task.requirements.map { req in
                LijiRequirementRow(
                    id: req.id,
                    taskTitle: task.title,
                    prompt: req.prompt,
                    summary: req.summary,
                    error: req.error,
                    status: .init(rawStatus: req.status),
                    patchId: req.patch?.id,
                    applyMode: req.patch?.applyMode
                )
            }
        }
    }

    /// 由「分享给我的」DTO 列表构建展示行。
    public static func grantRows(from grants: [LijiGrantDTO]) -> [LijiGrantRow] {
        grants.map {
            LijiGrantRow(token: $0.token, title: $0.title, note: $0.note,
                        owner: $0.owner, enabled: $0.enabled, patchId: $0.patch?.id)
        }
    }
}
