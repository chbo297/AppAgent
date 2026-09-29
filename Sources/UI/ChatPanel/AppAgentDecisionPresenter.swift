//
//  AppAgentDecisionPresenter.swift
//  AppAgent
//
//  把 Core 的 `DecisionResponder`（async，返回结果）接到 UIKit 的「弹卡片 + 等点击」上。
//
//  为什么单独一个类而不是让 AppAgentViewController 直接实现 DecisionResponder：
//  `DecisionResponder` 要求 Sendable，而 UIViewController 不是；用一个 @unchecked
//  Sendable 的薄壳持弱引用，并在内部跳回主线程，比给 VC 开 Sendable 例外干净。
//
//  等待是**可取消**的：用户按停止 / 切走 run 之后，等在这里的 Task 会被取消，
//  这时要立刻把 continuation 收掉并撤下卡片——否则那张卡片会一直挂在面板上等一个
//  已经死掉的回合，而 executor 的 Task 也永远回不来。
//
//  continuation 的**归属在这里**：`respond` 挂起后，唯一还认识这个 continuation 的
//  对象就是本类的 `inFlight` 表。呈现方（`AppAgentViewController`）只拿到 `complete`
//  闭包——它先死掉时，那些闭包随之消失，没人再能恢复等待。所以面板销毁时**必须**调
//  `settlePendingDecisions()` 把在飞的等待结清；结清的实现放在这里（它持有 continuation），
//  触发的时机由面板给（只有它知道自己没了）。
//

#if canImport(UIKit)
import UIKit

public final class AppAgentDecisionPresenter: DecisionResponder, @unchecked Sendable {

    /// 呈现闭包。返回 `false` 表示当前呈现不了（面板没挂载/已销毁），
    /// 决策中心会顺着责任链往下走，最终兜底拒绝。
    ///
    /// 带上发起请求的 session id 与本次请求的 id：卡片是面板全局的一张，但请求属于
    /// 某个会话。呈现方据此决定「现在贴出来」还是「记下来，等用户切回那个会话再贴」，
    /// 并能在请求被取消时按 id 找回那一条。
    public typealias Present = @MainActor (
        _ request: DecisionRequest,
        _ sessionId: String,
        _ requestId: UUID,
        _ complete: @escaping (DecisionOutcome) -> Void
    ) -> Bool

    /// 撤销闭包：请求方不再等待（run 被取消）时调用，呈现方据此撤下卡片。
    public typealias Dismiss = @MainActor (_ requestId: UUID) -> Void

    private let present: Present
    private let dismiss: Dismiss

    /// 在飞的等待：requestId → continuation 状态机。
    ///
    /// 只有这张表能在「面板已经销毁、`respond` 仍挂起」时找回 continuation，
    /// 由 `settlePendingDecisions()` 统一结清，见文件头。
    private let inFlightLock = ReadersWriterLock()
    private var inFlight: [UUID: PendingContinuation] = [:]

    public init(present: @escaping Present, dismiss: @escaping Dismiss) {
        self.present = present
        self.dismiss = dismiss
    }

    /// 面板要消失了：把所有在飞的等待结清（`nil` = 我答不了，交回责任链）。
    ///
    /// **`nonisolated`，只碰自己这张锁保护的表**，所以能从 `AppAgentViewController.deinit`
    /// 这种非隔离上下文里直接调用，不需要 `MainActor.assumeIsolated`。
    ///
    /// 为什么非得由面板显式通知，不能指望本类的 `deinit`：`AISession.requestDecision`
    /// 在 `for responder in responders` 里 await，那个 `responders` 是**强引用数组**，
    /// 等待期间 presenter 一直被这个挂起的 executor 帧持有——正在等的时候它不可能析构。
    public func settlePendingDecisions() {
        let pendings = inFlightLock.writeSync { () -> [PendingContinuation] in
            let all = Array(inFlight.values)
            inFlight.removeAll()
            return all
        }
        // 给 `nil` 而不是自己造一个 outcome：责任链会继续问下一个 responder，
        // 最后落到 Core 统一的兜底语义上。兜底策略只能有一份，不在 UI 层复制。
        for pending in pendings { pending.settle(nil) }
    }

    public func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        let sessionId = session.id
        let requestId = UUID()
        let pending = PendingContinuation()
        let present = self.present
        let dismiss = self.dismiss

        // 结清 + 从在飞表里摘掉。两步都幂等，所以四个出口都能安全调用。
        // `weak self`：这个闭包会作为 `complete` 交给呈现方存进队列，可能比本次请求活得更久，
        // 弱引用免得它反过来把 presenter 吊住。
        let finish: @Sendable (DecisionOutcome?) -> Void = { [weak self] outcome in
            pending.settle(outcome)
            self?.unregister(requestId)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DecisionOutcome?, Never>) in
                // 进来之前就被取消了：`install` 已经就地恢复，别再弹卡片。
                guard pending.install(continuation) else { return }
                register(pending, id: requestId)
                Task { @MainActor in
                    guard !pending.isSettled else { return }
                    let shown = present(request, sessionId, requestId) { outcome in
                        finish(outcome)
                    }
                    if !shown {
                        finish(nil)
                    } else if pending.isSettled {
                        // 取消正好落在上面那次 isSettled 检查之后、present 之前：
                        // 等待的人已经走了，卡片却已经贴出去，这里补一刀撤掉，
                        // 否则面板上会留一张点了没用的「僵尸卡」。
                        dismiss(requestId)
                    }
                }
            }
        } onCancel: {
            // 先把等待的人放走（交回责任链兜底），再回主线程撤卡片。
            finish(nil)
            Task { @MainActor in dismiss(requestId) }
        }
    }

    private func register(_ pending: PendingContinuation, id: UUID) {
        inFlightLock.writeSync { inFlight[id] = pending }
    }

    private func unregister(_ id: UUID) {
        inFlightLock.writeSync { inFlight.removeValue(forKey: id) }
    }
}

/// 一次等待的 continuation 状态机：只允许恢复一次，且允许「取消先于安装」。
private final class PendingContinuation: AppAgentRuntimeOwned, @unchecked Sendable {
    private let lock = ReadersWriterLock()
    private var continuation: CheckedContinuation<DecisionOutcome?, Never>?
    private var isDone = false

    var isSettled: Bool { lock.read { isDone } }

    /// 安装 continuation；若在安装前就已结束（取消跑在前面），就地恢复并返回 false。
    func install(_ continuation: CheckedContinuation<DecisionOutcome?, Never>) -> Bool {
        let alreadyDone = lock.writeSync { () -> Bool in
            guard !isDone else { return true }
            self.continuation = continuation
            return false
        }
        if alreadyDone {
            continuation.resume(returning: nil)
            return false
        }
        return true
    }

    /// 恢复等待。重复调用（用户连点两下 / 取消与点击撞车）只有第一次生效。
    func settle(_ outcome: DecisionOutcome?) {
        let taken = lock.writeSync { () -> CheckedContinuation<DecisionOutcome?, Never>? in
            guard !isDone else { return nil }
            isDone = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        taken?.resume(returning: outcome)
    }
}
#endif
