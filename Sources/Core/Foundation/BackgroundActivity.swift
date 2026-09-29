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
    /// 不做线程切换：`beginBackgroundTask` 在非主线程调用是安全的（Apple 文档明确写了），
    /// 而执行循环跑在协作线程池上 —— 为它专门 hop 一次主线程，等于给每一轮的开头加上
    /// 「主线程当前有多忙」这个不确定因素。
    public static func begin(_ reason: String) -> @Sendable () -> Void {
        (installed.wrappedValue ?? defaultBegin)(reason)
    }

    #if canImport(UIKit)
    private static let defaultBegin: Begin = { reason in
        // 过期回调里也要 end：系统给的时间用完还不结束，进程会被直接杀掉。
        // 所以 token 放在一个盒子里做「只结束一次」，两条路径（正常结束 / 过期）共用。
        let token = Locked<Int>(wrappedValue: UIBackgroundTaskIdentifier.invalid.rawValue)
        token.wrappedValue = UIApplication.shared.beginBackgroundTask(withName: reason) {
            Logger.warning("BackgroundActivity", "后台执行时间用尽：\(reason)")
            endOnce(token)
        }.rawValue
        return { endOnce(token) }
    }

    private static func endOnce(_ token: Locked<Int>) {
        let raw = token.mutate { value -> Int in
            let current = value
            value = UIBackgroundTaskIdentifier.invalid.rawValue
            return current
        }
        guard raw != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
    }
    #else
    /// 原生 macOS 不会挂起前台进程，没有可申请的东西。
    private static let defaultBegin: Begin = { _ in {} }
    #endif
}
