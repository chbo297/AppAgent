import Foundation

public enum SessionLifecycleError: Error, LocalizedError, Sendable {
    case unsupported
    case notFound(String)
    case inactive(String)
    case conflict(String)
    case running(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This session storage does not support recoverable archives."
        case .notFound(let id): return "No owned session found with id '\(id)'."
        case .inactive(let id): return "Session '\(id)' is archived, purged, or no longer the active instance."
        case .conflict(let id): return "Session '\(id)' already exists in the destination."
        case .running(let id): return "Session '\(id)' is running or has an unfinished turn. Stop it and wait for completion first."
        case .invalid(let message): return message
        }
    }
}

/// A task chain, not merely actor isolation: the entire operation stays serialized across storage awaits.
actor SessionLifecycleQueue: AppAgentRuntimeOwned {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
}

/// Serializes the synchronous run-start boundary with archive/merge snapshot admission.
///
/// **锁必须跨 `body()`，不许收窄。** `suspend` 的判据是「`!session.isRunning`」，而 `isRunning` 是
/// `body()`（即 `executor.run`）同步跑起来之后才置起的。若在 `body()` 之前就放锁，`suspend` 就能插进
/// 「查完没挂起」和「run 真的置起 running」之间 —— 结果是一个已归档的会话照样起了一轮。
/// 换句话说：这段看起来「持锁太久」的代码，正是 start 与 suspend 互斥的唯一依据。
///
/// 代价是 `body` 成了在锁内执行的调用方代码，于是有两条硬约束：
/// 1. `body` 必须是**同步**的，别在里面 await；
/// 2. `body` 不得回调本类的任何方法（`start` / `suspend` / `resume`）。`NSLock` 不可重入，
///    真踩了就是硬死锁，而且卡在 `lock()` 上、连断言都执行不到 —— 所以下面的重入检测放在加锁**之前**。
///
/// 今天 `body` 只有 `AISession.sendMessage` 里的 `executor.run(text)` 一个实参，它的同步段不碰
/// lifecycle，所以没有现存死锁；检测只为拦住以后往 `body` 里塞别的东西。
final class SessionLifecycleState: AppAgentRuntimeOwned, @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false

    #if DEBUG
    /// 当前持有 `lock` 的线程，只用于重入检测。
    ///
    /// 单独一把锁：它必须在主锁**之外**读写，否则就和被检测的死锁绑在一起了。
    private let ownerLock = NSLock()
    private var owner: Thread?

    private func assertNotReentrant(_ method: StaticString) {
        ownerLock.lock()
        let current = owner
        ownerLock.unlock()
        if let current, current === Thread.current {
            assertionFailure("""
                SessionLifecycleState.\(method) 被重入了：同一线程已经持有 lifecycle 锁。
                NSLock 不可重入，继续走下去就是死锁。检查传给 start(_:) 的闭包，它不能回调
                start / suspend / resume。
                """)
        }
    }

    private func setOwner(_ thread: Thread?) {
        ownerLock.lock()
        owner = thread
        ownerLock.unlock()
    }
    #else
    private func assertNotReentrant(_ method: StaticString) {}
    private func setOwner(_ thread: Thread?) {}
    #endif

    func start(_ body: () -> AsyncStream<AIAgentEvent>) -> AsyncStream<AIAgentEvent> {
        assertNotReentrant("start")
        lock.lock()
        setOwner(Thread.current)
        defer {
            setOwner(nil)
            lock.unlock()
        }
        guard !suspended else {
            return AsyncStream {
                $0.yield(.error(SessionLifecycleError.invalid("Session is being archived or merged; restore it before running.")))
                $0.finish()
            }
        }
        return body()
    }

    func suspend(_ session: AISession) throws {
        assertNotReentrant("suspend")
        lock.lock()
        setOwner(Thread.current)
        defer {
            setOwner(nil)
            lock.unlock()
        }
        guard !suspended else { throw SessionLifecycleError.inactive(session.id) }
        guard !session.isRunning, !session.uiState.isStreaming,
              !session.turnRecords.values.contains(where: { !$0.isFinished }) else {
            throw SessionLifecycleError.running(session.id)
        }
        suspended = true
    }

    func resume() {
        assertNotReentrant("resume")
        lock.lock()
        setOwner(Thread.current)
        suspended = false
        setOwner(nil)
        lock.unlock()
    }
}
