//
//  BackgroundActivity.swift
//  AppAgent
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 「这一段运行别现在就被冻结」——进程级的后台执行断言。
///
/// ## 为什么执行循环需要它
///
/// iOS 把 App 切到后台后几秒就挂起进程，Swift 并发的线程池随之整体停摆：正在跑的那一轮
/// agent 会停在任意一个 await 上，SSE 连接多半也在挂起期间被撕掉。申请一段后台执行时间
/// （iOS 13+ 约 30s）能让「切出去看一眼消息再回来」这种最常见的操作把当前这一轮跑完，
/// 而不是回来面对一条已经死掉的流。
///
/// 拿不到断言不是错误（额度用尽、非 UIKit 平台都可能）：那时退回兜底路径 ——
/// 被冻结、回前台后由 `StreamIdleGuard` 判死并重试，行为与没有这一层时一致。
/// 所以这里**不报错、不抛异常**，只是「能争取就争取」。
///
/// ## 为什么是一个闭包而不是协议 + Central
///
/// 它是进程级的一项环境能力，不是每个 agent 各配一份的策略，没有多实例共存的场景 ——
/// 配上协议、注册中心、默认实现三件套只会多出三个需要同步维护的地方。
/// UIKit 平台默认就装好了真实实现，宿主零配置；`install` 留给测试，以及已有自己后台任务
/// 管理器、希望共用额度的宿主。
public enum BackgroundActivity {

    /// 申请一段后台执行时间。返回值是「结束」回调，**必须**被调用（否则一直占着系统额度）。
    public typealias Begin = @Sendable (_ reason: String) -> @Sendable () -> Void

    private static let installed = Locked<Begin?>(wrappedValue: nil)

    /// 换掉默认实现。传 `nil` 恢复默认（UIKit 平台的真实断言 / 其他平台的空实现）。
    public static func install(_ begin: Begin?) {
        installed.wrappedValue = begin
    }

    /// 申请一段后台执行时间。**返回的「结束」回调必须被调用**，否则一直占着系统额度。
    ///
    /// ## token 在主线程异步申请
    ///
    /// 曾经这里是「不做线程切换」：理由是 `beginBackgroundTask` 本身在非主线程调用安全，
    /// 而执行循环跑在协作线程池上，为它 hop 一次主线程等于把「主线程当前有多忙」引入每一轮开头。
    /// 这个理由不成立了 —— 隔离约束落在 `UIApplication.shared` 这个**属性**上（主 actor 隔离），
    /// 不是落在那个方法上；非主线程读它就是数据竞争，跟方法本身线程安全无关。
    ///
    /// 所以改成：`begin(_:)` **仍然同步返回**，不阻塞执行循环；真正的 token 申请被异步派到主线程，
    /// 状态用一个带锁的状态盒承载。代价是断言真正生效比调用点晚一次主队列派发（微秒级），
    /// 这段空窗里若恰好被挂起，退回的是本来就有的兜底路径（`StreamIdleGuard` 判死 + 重试），
    /// 与「压根没拿到断言」的行为一致 —— 不是新的失败模式。
    ///
    /// 为什么不用 `nonisolated(unsafe)` / `@preconcurrency` 压掉告警：那只让编译器闭嘴，
    /// 「这个属性只许主线程读」的真实约束还在，换不来任何正确性。
    public static func begin(_ reason: String) -> @Sendable () -> Void {
        (installed.wrappedValue ?? defaultBegin)(reason)
    }

    #if canImport(UIKit)
    /// 一次断言的生命周期。申请是异步的，「结束」可能比 token 先到，所以四个状态都要有名字。
    ///
    /// token 存 `Int` rawValue 而不是 `UIBackgroundTaskIdentifier`：后者的 Sendable 状态由 SDK
    /// 标注决定、不受我们控制，而 rawValue 是纯值类型，放进 `Locked` 不留悬念。
    private enum AssertionState: Sendable {
        /// 已经把申请投给主队列，token 还没回来。
        case pending
        /// 持有 token，等着被归还。
        case active(Int)
        /// token 还没回来就被要求结束了 —— token 到手那一刻必须立刻归还。
        case endRequested
        /// 已归还 / 已作废，任何后续动作都是 no-op。
        case ended
    }

    private static let defaultBegin: Begin = { reason in
        let state = Locked<AssertionState>(wrappedValue: .pending)

        // 已经在往主队列投了，`assumeIsolated` 只是把这个事实告诉编译器，不改变行为。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let token = UIApplication.shared.beginBackgroundTask(withName: reason) {
                    // 过期回调由系统在主线程调用。时间用完还不 end，进程会被直接杀掉。
                    Logger.warning("BackgroundActivity", "后台执行时间用尽：\(reason)")
                    MainActor.assumeIsolated { endIfHeld(state) }
                }

                guard token.rawValue != UIBackgroundTaskIdentifier.invalid.rawValue else {
                    // 额度用尽时系统返回 .invalid：没有东西需要归还，直接作废。
                    state.wrappedValue = .ended
                    return
                }

                let adopted = state.mutate { current -> Bool in
                    switch current {
                    case .pending:
                        current = .active(token.rawValue)
                        return true
                    case .endRequested, .ended:
                        // 「end 先到、token 后到」：这个 token 已经没人会来认领，必须就地归还，
                        // 否则等于占着系统额度不放 —— 后续申请拿不到，进程也会被杀。
                        current = .ended
                        return false
                    case .active:
                        // 一个盒子只申请一次 token，正常到不了这里；真到了就把多出来的那个还掉。
                        return false
                    }
                }
                if !adopted {
                    UIApplication.shared.endBackgroundTask(token)
                }
            }
        }

        // 结束闭包可能在任意线程被调用（执行循环收尾的 defer），所以它只**记录结束意图**，
        // 真正的归还交给主线程。
        return { requestEnd(state) }
    }

    /// 记录「这一段跑完了」。可在任意线程调用。
    private static func requestEnd(_ state: Locked<AssertionState>) {
        let holdsToken = state.mutate { current -> Bool in
            switch current {
            case .pending:
                // token 还没回来，没什么可还的；到手那一刻由申请路径负责立刻归还。
                current = .endRequested
                return false
            case .active:
                // 状态**留在** `.active`：token 由 `endIfHeld` 在主线程原子取出，
                // 这样「正常结束」和「过期回调」抢着结束时，只有一方能取到。
                return true
            case .endRequested, .ended:
                return false
            }
        }
        guard holdsToken else { return }
        // 同上：已经在往主队列投了，`assumeIsolated` 只是把这个事实告诉编译器。
        DispatchQueue.main.async { MainActor.assumeIsolated { endIfHeld(state) } }
    }

    /// 归还 token。**只归还一次**靠「原子取出」保证：同一个 token 被 end 两次会崩，
    /// 而正常结束与过期回调是两条独立路径，随时可能并发到达。
    @MainActor
    private static func endIfHeld(_ state: Locked<AssertionState>) {
        let raw = state.mutate { current -> Int? in
            guard case .active(let raw) = current else { return nil }
            current = .ended
            return raw
        }
        guard let raw = raw else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
    }
    #else
    /// 原生 macOS 不会挂起前台进程，没有可申请的东西。
    private static let defaultBegin: Begin = { _ in {} }
    #endif
}
