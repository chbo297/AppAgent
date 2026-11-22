//
//  AppAgentDecisionPresenter.swift
//  AppAgent
//
//  把 Core 的 `DecisionResponder`（async，返回结果）接到 UIKit 的「弹卡片 + 等点击」上。
//
//  为什么单独一个类而不是让 AppAgentViewController 直接实现 DecisionResponder：
//  `DecisionResponder` 要求 Sendable，而 UIViewController 不是；用一个 @unchecked
//  Sendable 的薄壳，在内部跳回主线程，比给 VC 开 Sendable 例外干净。
//
//  **等待挂在这里，不挂在面板上**：进程里只有一份 `shared`，所有等用户拍板的请求都登记在它的
//  `entries` 里；面板（`attach` 进来的 surface）只负责把它画出来。面板被释放、换绑 agent 时，
//  请求不结束、不替用户做决定，只是回到「没人展示」的状态；下一个能展示该会话的面板 attach
//  进来（或切回那个会话）时再贴出来。会话因此可以一直挂起等用户。
//
//  等待是**可取消**的：用户按停止之后，等在这里的 Task 会被取消，
//  这时要立刻把 continuation 收掉并撤下卡片——否则那张卡片会一直挂在面板上等一个
//  已经死掉的回合，而 executor 的 Task 也永远回不来。
//

#if canImport(UIKit)
import UIKit

public final class AppAgentDecisionPresenter: DecisionResponder, @unchecked Sendable {

    /// 呈现闭包。返回 `false` 表示「这个请求不归我」（比如属于别的 agent 的会话），
    /// presenter 会问下一个 surface；都不收就先挂着，等以后有面板能展示。
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

    /// 进程内的那一份。`AppAgentViewController` 都 attach 到这里。
    public static let shared = AppAgentDecisionPresenter()

    private let lock = ReadersWriterLock()
    /// 还在等的请求，按到达顺序。
    private var entries: [Entry] = []
    /// 有面板 attach 过才接请求：纯 headless 集成没人能回答，直接交回责任链兜底。
    private var hasHadSurface = false
    @MainActor private var surfaces: [Surface] = []

    public init() {}

    // MARK: - Surfaces

    /// 一个面板开始负责展示。已经在等、还没人展示的请求会立刻交给它看要不要接。
    @MainActor
    public func attach(_ owner: AnyObject, present: @escaping Present, dismiss: @escaping Dismiss) {
        surfaces.removeAll { $0.owner == nil || $0.owner === owner }
        surfaces.append(Surface(owner: owner, present: present, dismiss: dismiss))
        let isFirst = lock.writeSync { () -> Bool in
            defer { hasHadSurface = true }
            return !hasHadSurface
        }
        if isFirst, self === Self.shared {
            DecisionResponderCentral.default.register(self)
        }
        offerUnowned()
    }

    @MainActor
    public func detach(_ owner: AnyObject) {
        surfaces.removeAll { $0.owner == nil || $0.owner === owner }
        releaseDecisions(of: owner)
    }

    /// 面板不再展示它手上的请求（比如换绑了 agent）：请求继续等，重新找能展示的面板。
    @MainActor
    public func releaseDecisions(of owner: AnyObject) {
        for entry in snapshot() where entry.owner === owner {
            entry.owner = nil
        }
        offerUnowned()
    }

    /// 把所有在等的请求结清为 `nil`（= 我答不了，交回责任链）。只给测试和整体拆除用。
    public func settlePendingDecisions() {
        let pendings = lock.writeSync { () -> [Entry] in
            defer { entries.removeAll() }
            return entries
        }
        for entry in pendings {
            entry.pending.settle(nil)
        }
    }

    /// 还在等用户的请求数。
    public var pendingCount: Int {
        lock.read { entries.count }
    }

    // MARK: - DecisionResponder

    public func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        guard lock.read({ hasHadSurface }) else {
            return nil
        }
        let entry = Entry(id: UUID(), request: request, sessionId: session.id)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DecisionOutcome?, Never>) in
                // 进来之前就被取消了：`install` 已经就地恢复，别再弹卡片。
                guard entry.pending.install(continuation) else {
                    return
                }
                lock.writeSync {
                    entries.append(entry)
                }
                Task { @MainActor in
                    guard !entry.pending.isSettled else {
                        return
                    }
                    // 没有面板接也不结束：挂着等，以后有面板 attach 或切回会话时再展示。
                    self.offer(entry)
                    if entry.pending.isSettled, entry.owner != nil {
                        // 取消正好落在上面那次检查之后：等待的人已经走了，撤掉刚贴的卡。
                        self.dismiss(entry)
                    }
                }
            }
        } onCancel: {
            // 先把等待的人放走（交回责任链兜底），再回主线程撤卡片。
            finish(entry, nil)
            Task { @MainActor in
                self.dismiss(entry)
            }
        }
    }

    // MARK: - Private

    @MainActor
    private func offerUnowned() {
        surfaces.removeAll { $0.owner == nil }
        for entry in snapshot() where entry.owner == nil && !entry.pending.isSettled {
            offer(entry)
        }
    }

    @MainActor
    private func offer(_ entry: Entry) {
        for surface in surfaces {
            guard let owner = surface.owner else {
                continue
            }
            let accepted = surface.present(entry.request, entry.sessionId, entry.id) { [weak self] outcome in
                self?.finish(entry, outcome)
            }
            if accepted {
                entry.owner = owner
                return
            }
        }
    }

    @MainActor
    private func dismiss(_ entry: Entry) {
        guard let owner = entry.owner else {
            return
        }
        entry.owner = nil
        surfaces.first { $0.owner === owner }?.dismiss(entry.id)
    }

    private func finish(_ entry: Entry, _ outcome: DecisionOutcome?) {
        entry.pending.settle(outcome)
        lock.writeSync {
            entries.removeAll { $0 === entry }
        }
    }

    private func snapshot() -> [Entry] {
        lock.read { entries }
    }

    private struct Surface {
        weak var owner: AnyObject?
        let present: Present
        let dismiss: Dismiss
    }

    /// 一个在等的请求。`owner` 只在主线程读写：哪个面板正在展示它；`nil` = 没人展示，挂着等。
    private final class Entry: @unchecked Sendable {
        let id: UUID
        let request: DecisionRequest
        let sessionId: String
        let pending = PendingContinuation()
        weak var owner: AnyObject?

        init(id: UUID, request: DecisionRequest, sessionId: String) {
            self.id = id
            self.request = request
            self.sessionId = sessionId
        }
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
