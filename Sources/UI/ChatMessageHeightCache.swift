//
//  ChatMessageHeightCache.swift
//  AppAgentUI
//
//  自算行高 + 缓存：把「这条消息多高」从系统的估算机制手里拿回来。
//
//  为什么不用 `estimatedRowHeight` + `automaticDimension`：那套机制下 `contentSize` 一开始是
//  `行数 × 估算值`，cell 真正出现在屏上才会被测准，`contentSize` 随之变大。于是「滚到底部」这件事
//  永远滚的是一个还在变的目标 —— 首屏打开时最明显（实测会停在离底一截的位置）。
//
//  这里用「模板 cell + Auto Layout 测量」而不是自己复刻一遍 cell 的布局常量：布局代码只有一份，
//  改了 `ChatMessageCell` 的内边距/字体不用同步改测量逻辑，不会出现「算出来的高度和画出来的对不上」。
//
//  **缓存身份与失效各管一件事，别混**：身份用 `ChatRowIdentity`（跨重建稳定），失效用 `Input`
//  判等（计算式判脏，不设 dirty flag —— 命令式标记漏一处就是行高偏小 + `clipsToBounds` 裁内容）。
//

#if canImport(UIKit)
import UIKit

/// 一行的稳定身份：跨重建、跨重启都不变。
///
/// 与 `ChatMessage.id` 是**两个概念**：后者每次组装都是新 UUID，只用于本次列表的 diff 与
/// 原位定位；缓存身份必须活过重建，所以挂在 Core 分配、随快照落盘的 `turnID` 上。
enum ChatRowIdentity: Hashable {
    /// 权威身份。一轮 = 1 个用户气泡 + 1 个 agent 回复，所以 `turnID + role` 唯一。
    /// 组装器对旧快照也会合成 turn key，历史行同样走这一支。
    case turn(turnID: Int, role: ChatMessage.Role)

    /// 乐观占位行（还不知道 Core 会发几号）与调试固定回复。只在本次列表内有效，
    /// 下一次重建会被权威行替换 —— 这一支的行为与按 UUID 缓存的旧实现一致。
    case transient(UUID)

    init(_ message: ChatMessage) {
        if let turnID = message.turnID {
            self = .turn(turnID: turnID, role: message.role)
        } else {
            self = .transient(message.id)
        }
    }
}

@MainActor
final class ChatMessageHeightCache {

    /// 宽度以外、影响高度的全部输入；任一项变了就要重测。
    private struct Input: Equatable {
        let role: ChatMessage.Role
        let status: ChatMessage.Status
        let text: String
        let isActivityExpanded: Bool
        /// 决定整个过程区显隐（高度差可达上百 pt），必须进判等。
        let suppressResolvedActivity: Bool
        let activity: AppAgentActivityTimeline?

        init(_ message: ChatMessage) {
            role = message.role
            status = message.status
            text = message.text
            isActivityExpanded = message.isActivityExpanded
            suppressResolvedActivity = message.suppressResolvedActivity
            activity = message.activity
        }
    }

    /// 宽度非法时给出的兜底行高，只在 tableView 还没有尺寸时用到。
    static let fallbackHeight: CGFloat = 44

    /// 同时保留几个宽度的测量结果：旋转 / 分屏来回切时两个方向都能命中。
    ///
    /// iPad / Mac Catalyst 拖窗口时宽度是**连续变化**的，所以既要取整（`bucket(for:)`）
    /// 也要设上限，否则每个像素宽都留一份，缓存就变成内存泄漏。
    private static let maximumWidthBuckets = 3

    /// 身份 → 宽度桶 → （测量输入, 高度）。
    private var entries: [ChatRowIdentity: [CGFloat: (input: Input, height: CGFloat)]] = [:]

    /// 宽度桶的使用顺序，末尾最新；超过上限淘汰最老的那个宽度。
    private var widthBuckets: [CGFloat] = []

    private let measurementCell = ChatMessageCell(style: .default, reuseIdentifier: nil)

    /// 命中缓存就直接返回；否则用模板 cell 测一次并记下来。
    /// 这里只缓存实际内容高度；最新回复的占位和单调增长由列表单独持有。
    func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        guard width > 0 else { return Self.fallbackHeight }

        let bucket = Self.bucket(for: width)
        let identity = ChatRowIdentity(message)
        let input = Input(message)
        if let cached = entries[identity]?[bucket], cached.input == input {
            touch(bucket)
            return cached.height
        }

        // 按桶宽（向下取整）测量：桶宽 ≤ 真实宽度，算出来的高度只会偏大不会偏小，
        // 避免同桶内的零点几 pt 差异让文字少留一行、被 `clipsToBounds` 裁掉。
        let height = measure(message, width: bucket)
        entries[identity, default: [:]][bucket] = (input, height)
        touch(bucket)
        return height
    }

    /// 丢掉已经不在列表里的行，避免换会话 / 清历史后越攒越多。
    func retain(_ identities: Set<ChatRowIdentity>) {
        entries = entries.filter { identities.contains($0.key) }
    }

    private static func bucket(for width: CGFloat) -> CGFloat {
        width.rounded(.down)
    }

    /// 记一次宽度桶的使用；超出上限时把最老的宽度从所有行里摘掉。
    private func touch(_ bucket: CGFloat) {
        if let index = widthBuckets.firstIndex(of: bucket) {
            guard index != widthBuckets.count - 1 else { return }
            widthBuckets.remove(at: index)
        }
        widthBuckets.append(bucket)

        while widthBuckets.count > Self.maximumWidthBuckets {
            let evicted = widthBuckets.removeFirst()
            for identity in entries.keys {
                entries[identity]?.removeValue(forKey: evicted)
                if entries[identity]?.isEmpty == true { entries.removeValue(forKey: identity) }
            }
        }
    }

    private func measure(_ message: ChatMessage, width: CGFloat) -> CGFloat {
        measurementCell.bounds = CGRect(x: 0, y: 0, width: width, height: Self.fallbackHeight)
        measurementCell.configure(with: message)
        // 只求解一次：`systemLayoutSizeFitting` 自己会跑约束引擎，前面再 layoutIfNeeded 是白跑一遍。
        let fittingSize = measurementCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return max(Self.fallbackHeight, ceil(fittingSize.height))
    }
}

#endif
