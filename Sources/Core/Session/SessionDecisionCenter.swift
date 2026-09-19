//
//  SessionDecisionCenter.swift
//  AppAgent
//
//  「有个决定待用户拍板」这件事的唯一入口。
//
//  为什么要有这一层：工具（Core）不该知道谁来回答。AppAgent 自带完整 UI，
//  面板挂载时本来就能在对话列表里弹卡片，不该强迫宿主 app 去实现一套
//  continuation 异步管道；但 headless 集成（没有 AppAgent UI）又必须有兜底。
//  所以按责任链找人回答：
//
//    1. 宿主策略（AIAgentDelegate，非交互）—— 企业要「内网一律禁止，别问用户」在这里拦
//    2. AppAgent 自己的 UI（DecisionResponder）—— 默认路径，宿主零代码
//    3. 兜底 deny —— 没人能回答时不放行，安全性不因为改成「问用户」而下降
//

import Foundation

/// 待用户拍板的请求。UI 侧据此渲染卡片，三个场景共用一个控件。
public enum DecisionRequest: Sendable, Equatable {
    /// Agent 想访问私有网络地址。
    case privateNetworkAccess(host: String, url: String)
    /// 工具想执行 sensitive/dangerous 操作。
    case toolAuthorization(tool: String, safetyLevel: Tool.SafetyLevel, detail: String?)
    /// Agent 需要用户澄清或在几个方案里挑一个。
    case clarification(question: String, choices: [String])

    /// 卡片标题，UI 不必自己 switch。
    public var title: String {
        switch self {
        case .privateNetworkAccess: return "允许访问内网？"
        case .toolAuthorization(let tool, _, _): return "允许执行 \(tool)？"
        case .clarification: return "需要你确认"
        }
    }

    /// 卡片正文。
    public var message: String {
        switch self {
        case .privateNetworkAccess(let host, let url):
            return "Agent 想要访问 \(host)。这是内网/本机地址，可能暴露你当前网络里的私有服务。\n\(url)"
        case .toolAuthorization(let tool, let level, let detail):
            let why = detail.map { "\n原因：\($0)" } ?? ""
            return "\(tool)（\(level.rawValue)）会改变状态或访问敏感数据。\(why)"
        case .clarification(let question, _):
            return question
        }
    }

    /// 卡片上的按钮。顺序即展示顺序。
    public var options: [DecisionOption] {
        switch self {
        case .privateNetworkAccess, .toolAuthorization:
            return [
                DecisionOption(id: "allow_once", label: "仅本次允许", style: .primary),
                DecisionOption(id: "allow_session", label: "本次会话都允许", style: .normal),
                DecisionOption(id: "deny", label: "拒绝", style: .destructive)
            ]
        case .clarification(_, let choices):
            if choices.isEmpty {
                return [DecisionOption(id: "dismiss", label: "跳过", style: .normal)]
            }
            return choices.enumerated().map { index, choice in
                DecisionOption(id: "choice_\(index)", label: choice,
                               style: index == 0 ? .primary : .normal)
            }
        }
    }
}

/// 卡片上的一个可点选项。
public struct DecisionOption: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case primary, normal, destructive
    }
    public let id: String
    public let label: String
    public let style: Style

    public init(id: String, label: String, style: Style = .normal) {
        self.id = id
        self.label = label
        self.style = style
    }
}

/// 用户（或策略）给出的结果。
public enum DecisionOutcome: Sendable, Equatable {
    case allowOnce
    case allowForSession
    case deny
    /// 澄清类问题的回答；`nil` = 用户跳过。
    case answer(String?)
}

/// 谁能把请求呈现给用户。AppAgent 的面板实现它；宿主一般不需要。
public protocol DecisionResponder: AnyObject, Sendable {
    /// 返回 `nil` 表示「我现在没法呈现」（比如面板没挂载），交给下一环。
    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome?
}

/// 进程级的 responder 注册表。
///
/// 为什么是全局而不是挂在 session 上：responder 是 UI（一个面板服务所有 session），
/// 而请求发起方是 per-session 的工具。让 UI 挂载时注册一次，比每建一个 session
/// 就去接线要少一半出错机会。
public final class DecisionResponderCentral: @unchecked Sendable {
    public static let `default` = DecisionResponderCentral()

    private let lock = ReadersWriterLock()
    private var _responders: [WeakResponder] = []

    private struct WeakResponder {
        weak var value: (any DecisionResponder)?
    }

    public init() {}

    /// 注册一个 responder（弱引用，UI 销毁后自动失效）。后注册的先被问到——
    /// 「更靠前的界面优先」符合直觉。
    public func register(_ responder: any DecisionResponder) {
        lock.writeSync {
            _responders.removeAll { $0.value === responder || $0.value == nil }
            _responders.insert(WeakResponder(value: responder), at: 0)
        }
    }

    public func unregister(_ responder: any DecisionResponder) {
        lock.writeSync {
            _responders.removeAll { $0.value === responder || $0.value == nil }
        }
    }

    /// 当前存活的 responder，按优先级。
    public var responders: [any DecisionResponder] {
        lock.read { _responders.compactMap { $0.value } }
    }
}
