//
//  AppAgentSessionSidebarItem.swift
//  AppAgentUI
//

#if canImport(UIKit)
import Foundation

/// Session 侧栏使用的轻量展示模型；`sessionID == nil` 表示仅用于当前 UI 阶段的演示数据。
struct AppAgentSessionSidebarItem: Equatable {
    let sessionID: String?
    let title: String
    let detail: String
    let isSelected: Bool
}

#endif
