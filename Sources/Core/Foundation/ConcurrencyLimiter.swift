//
//  ConcurrencyLimiter.swift
//  AppAgent
//

import Foundation

/// Actor-based concurrency limiter with FIFO queuing.
/// Used by LLM providers to limit the number of concurrent API requests.
///
/// 只暴露 `withPermit`，不暴露 acquire/release：额度的取与放必须成对，而「成对」曾经是靠
/// 调用方自觉 —— provider 里 `wait()` 在前、`signal()` 在函数尾，中间任何提前 return 都会
/// 永久漏掉一个额度；额度漏满（默认 5 个）之后整个 agent 再也发不出请求，且表现为「卡住不动」
/// 而不是报错。把配对关进一个函数里，这类泄漏就没有落脚点了。
actor ConcurrencyLimiter {
    private let limit: Int
    private var current: Int = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0, "ConcurrencyLimiter limit must be positive")
        self.limit = limit
    }

    /// 正在排队等额度的请求数。只读，不参与调度 —— 给测试用来等「真的排上队了」再取消，
    /// 否则取消会被 `acquire` 开头的 `checkCancellation` 提前吃掉，测不到排队路径。
    var pendingWaiters: Int { waiters.count }

    /// 取一个额度执行 `body`，无论正常返回还是抛错都归还。
    ///
    /// `nonisolated`：`body` 不能在 limiter 的 executor 上跑，否则所有请求会被串行化成一条。
    /// 排队期间被取消会抛 `CancellationError` 且**不占**额度 —— 取消钩子装在这里而不是
    /// `acquire` 里面，是因为 `withTaskCancellationHandler` 的 operation 要求 `@Sendable`，
    /// 放在 actor 隔离的方法里会和隔离推断打架。
    nonisolated func withPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let ticket = UUID()
        try await withTaskCancellationHandler {
            try await self.acquire(ticket)
        } onCancel: {
            Task { await self.cancelWaiter(ticket) }
        }
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    // MARK: - Private

    /// 拿到额度才返回。
    private func acquire(_ ticket: UUID) async throws {
        try Task.checkCancellation()
        if current < limit {
            current += 1
            return
        }
        // 显式标注 continuation 类型：`Void` 结果让类型推断走不出来，编译器会报
        // 「failed to produce diagnostic」这种无信息量的错。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 进队之前再看一眼：取消可能发生在钩子装上之后、这里之前，那时 cancelWaiter
            // 已经跑过（队列里还没有我，它什么也没做），没人会再来唤醒。
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append(Waiter(id: ticket, continuation: continuation))
        }
    }

    /// 归还额度并唤醒下一个等待者。
    ///
    /// 有等待者时**先**把 `current` 加回去再唤醒：actor 重入允许别的 `acquire()` 插在
    /// 「减完」和「被唤醒者真正开始用」之间，不先占住就会超发。
    private func release() {
        current -= 1
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        current += 1
        next.continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        // 没给它占过额度，所以只摘不减；它醒来后会从 acquire 抛出，不会走到 release。
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
}
