//
//  SessionWorkspace.swift
//  AppAgent
//
//  会话自己的界面数据：对话面板停在哪一档、工作区页面是什么样子。跟会话一起落盘、
//  一起进出废纸篓。这里只是数据，不碰 UIKit：后台会话也能改自己的这份，界面只在
//  它成为当前会话时按数据刷新（见 `AppAgentWorkspace`）。
//

import Foundation

/// 对话面板在输入框展开时停的档位。输入框收成小球时面板看不见，但档位保留，展开后恢复。
public enum SessionChatPanel: String, Codable, Sendable, CaseIterable {
    /// 只剩输入框和上面那条拖拽手柄。
    case collapsed
    case half
    case full
}

/// 一个会话的工作区：上层 H5、下层宿主插槽视图，各层各自可显示或隐藏。
///
/// 里面全是文本：文件内容、页面状态、插槽状态 SDK 都不解析，格式由写的人和读的人自己约定。
public struct SessionWorkspace: Codable, Sendable, Equatable {

    /// H5 层：模型写的页面文件，和页面自己存的状态。
    public struct H5: Codable, Sendable, Equatable {
        public var isShown: Bool

        /// 路径 → 文本。入口是 `index.html`；其余 css / js / json / svg 按相对路径引用。
        public var files: [String: String]

        /// 页面状态。页面经 `appAgent.workspace.setState(key, value)` 写，模型经 `set_state` 写。
        public var state: [String: String]

        public init(isShown: Bool = true, files: [String: String] = [:], state: [String: String] = [:]) {
            self.isShown = isShown
            self.files = files
            self.state = state
        }
    }

    /// 一个插槽：宿主放进来的视图（百度地图是子图区）自己的状态。
    public struct Slot: Codable, Sendable, Equatable {
        public var isShown: Bool
        public var state: [String: String]

        public init(isShown: Bool = false, state: [String: String] = [:]) {
            self.isShown = isShown
            self.state = state
        }
    }

    /// 整体是否显示。关掉时各层的设置都保留，再打开恢复原样。
    public var isShown: Bool
    public var title: String
    public var h5: H5

    /// 插槽名 → 插槽。名字由宿主声明（见 `AppAgentWorkspaceSlot`）。
    public var slots: [String: Slot]

    public init(isShown: Bool = false, title: String = "", h5: H5 = H5(), slots: [String: Slot] = [:]) {
        self.isShown = isShown
        self.title = title
        self.h5 = h5
        self.slots = slots
    }

    /// 正在显示的插槽。插槽铺满 H5 下方，同一时间最多显示一个。
    public var shownSlot: String? {
        slots.keys.sorted().first { name in
            slots[name]?.isShown == true
        }
    }

    /// 有没有可显示的东西：H5 层显示且有入口文件，或有显示中的插槽。都没有时顶栏不出工作区开关，
    /// 页面也不挂出来（否则只剩一张空白底板盖住 App）。
    public var hasContent: Bool {
        (h5.isShown && h5.files["index.html"] != nil) || shownSlot != nil
    }
}

// MARK: - 校验（工具、页面回写与落盘恢复共用）

public enum SessionWorkspaceLimits {
    public static let maximumFileBytes = 524_288
    public static let maximumIndexBytes = 1_048_576
    public static let maximumTotalFileBytes = 4_194_304
    public static let maximumFiles = 128
    public static let maximumStateBytes = 131_072

    /// 插槽状态由宿主编码（例如地图图形），比页面状态大。
    public static let maximumSlotStateBytes = 2_097_152
    public static let maximumTitleBytes = 500

    /// 保守的 ASCII 相对路径：拒绝百分号编码、URL 和所有点段；扩展名只允许 html / css / js / json / svg。
    public static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 240, !path.contains(".."),
              path.unicodeScalars.allSatisfy({ scalar in
                  allowedPathCharacters.contains(scalar)
              }) else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".."
        }) else {
            return false
        }
        return ["html", "css", "js", "json", "svg"].contains((path as NSString).pathExtension.lowercased())
    }

    private static let allowedPathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./"
    )

    /// 整份工作区是否在上限内；不通过时返回给模型看的原因。
    public static func violation(in workspace: SessionWorkspace) -> String? {
        if workspace.title.utf8.count > maximumTitleBytes {
            return "title must be at most 500 bytes"
        }
        let files = workspace.h5.files
        if files.count > maximumFiles {
            return "at most 128 files"
        }
        var total = 0
        for (path, text) in files {
            guard isValidPath(path) else {
                return "invalid file path '\(path)': relative ASCII path ending in .html, .css, .js, .json or .svg"
            }
            let limit = path == "index.html" ? maximumIndexBytes : maximumFileBytes
            if text.utf8.count > limit {
                return "\(path) exceeds \(limit / 1024) KiB"
            }
            total += text.utf8.count
        }
        if total > maximumTotalFileBytes {
            return "files exceed 4 MiB in total"
        }
        if stateBytes(workspace.h5.state) > maximumStateBytes {
            return "page state exceeds 128 KiB"
        }
        for (name, slot) in workspace.slots {
            guard isValidSlotName(name) else {
                return "invalid slot name '\(name)'"
            }
            if stateBytes(slot.state) > maximumSlotStateBytes {
                return "slot \(name) state exceeds 2 MiB"
            }
        }
        if workspace.slots.values.filter(\.isShown).count > 1 {
            return "only one slot can be shown at a time"
        }
        return nil
    }

    /// 插槽名：1-32 个小写字母、数字或下划线，由宿主声明。
    public static func isValidSlotName(_ name: String) -> Bool {
        (1...32).contains(name.utf8.count) && name.unicodeScalars.allSatisfy { scalar in
            slotNameCharacters.contains(scalar)
        }
    }

    private static let slotNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    public static func stateBytes(_ state: [String: String]) -> Int {
        state.reduce(0) { total, entry in
            total + entry.key.utf8.count + entry.value.utf8.count
        }
    }
}
