//
//  AppAgentWorkspaceHost.swift
//  AppAgent — 工作区的宿主接入协议
//
//  工作区的容器、页面、状态、落盘和显隐时机全部归 AppAgent（见 `AppAgentWorkspace`）。
//  宿主只做两件事：
//   1. 实现 `AppAgentWorkspaceHost`：功能是否开启、容器挂在自己界面的哪一层、页面按钮能调哪些动作；
//   2. 想在页面 H5 下方放自己的视图时，声明插槽（`workspaceSlots`）并按名字提供 `AppAgentWorkspaceSlotView`。
//  本文件之外的工作区类型，宿主都不需要实现。
//

#if canImport(UIKit)
import UIKit

/// 宿主声明的一个插槽：名字给模型和数据用（`SessionWorkspace.slots` 的 key），说明给模型看。
public struct AppAgentWorkspaceSlot: Sendable, Equatable {
    /// 1-32 个小写字母、数字或下划线，例如 `map`。
    public let name: String

    /// 这个插槽放的是什么、内容用哪个工具操作，一两句话。
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// 插槽视图：宿主放在工作区页面 H5 下方的原生视图。插槽铺满页面，同一时间只显示一个。
///
/// 每个插槽名全局只有一个视图：SDK 第一次需要时向宿主要一次，之后哪个页面在前台就 `bind` 给哪个页面，
/// 切会话只换数据。SDK 负责把它铺满页面、决定触摸给 H5 还是给它。视图里画什么、怎么操作，是宿主自己的事。
@MainActor
public protocol AppAgentWorkspaceSlotView: AnyObject {

    /// 视图本体。SDK 直接写 frame 铺满页面，不加约束。
    var view: UIView {
        get
    }

    /// 换成某个页面的内容。
    ///
    /// - Parameters:
    ///   - pageId: 页面标识。会话页面就是会话 id。
    ///   - state: 这个页面已保存的插槽状态（`SessionWorkspace.slots[name].state`），宿主读自己之前存的键。
    ///   - persistsState: false 表示页面只读展示（由快照打开），不要回写状态。
    ///     会话页面的状态由宿主经 `AppAgentWorkspace.updateSlotState` 写回。
    /// - Throws: 恢复失败。页面随之打开失败。
    func bind(pageId: String, state: [String: String], persistsState: Bool) throws

    /// 页面离开前台（收起、切会话、退后台）：把需要恢复的状态存好。之后可能 bind 别的页面。
    func unbind()

    /// 不再使用（功能关闭、内存告警）：释放视图占用的资源。
    func dispose()
}

/// 宿主接入点。装配见 `AppAgentWorkspace.install(host:chatViewController:)`。
@MainActor
public protocol AppAgentWorkspaceHost: AnyObject {

    /// 工作区功能当前是否开启（宿主自己的开关）。
    func workspaceIsEnabled() -> Bool

    /// 把工作区容器放进宿主界面层级，返回是否成功。层级由宿主决定：
    /// 一般在宿主页面之上、AppAgent 对话面板之下。
    func mountWorkspaceContainer(_ container: UIViewController) -> Bool

    /// 把工作区容器从宿主界面层级移除，返回是否成功。
    func unmountWorkspaceContainer(_ container: UIViewController) -> Bool

    /// 宿主提供的插槽。空数组表示只有 H5 层。
    var workspaceSlots: [AppAgentWorkspaceSlot] {
        get
    }

    /// 创建某个插槽的视图。SDK 在第一次需要显示这个插槽时调用一次，dispose 之后需要时再调。
    /// - Throws: 宿主没有这个插槽，或视图创建失败。页面随之打开失败。
    func makeWorkspaceSlotView(named name: String) throws -> any AppAgentWorkspaceSlotView

    /// 页面里的按钮能否调用这个宿主动作。
    func workspaceCanPerformPageAction(_ name: String) -> Bool

    /// 执行页面按钮调用的宿主动作，结果原样回给页面。
    func workspacePerformPageAction(_ name: String, params: JSONValue) async -> Tool.Output
}

/// 只要纯 H5 页面的宿主不必实现插槽和页面动作。
public extension AppAgentWorkspaceHost {

    var workspaceSlots: [AppAgentWorkspaceSlot] {
        []
    }

    func makeWorkspaceSlotView(named name: String) throws -> any AppAgentWorkspaceSlotView {
        throw AppAgentWorkspaceH5Error.invalid("this app provides no workspace slot named \(name)")
    }

    func workspaceCanPerformPageAction(_ name: String) -> Bool {
        false
    }

    func workspacePerformPageAction(_ name: String, params: JSONValue) async -> Tool.Output {
        .error("this app provides no page actions")
    }
}

#endif
