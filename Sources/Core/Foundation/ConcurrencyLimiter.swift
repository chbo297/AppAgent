//
//  ConcurrencyLimiter.swift
//  AppAgent
//

import Foundation

/// Actor-based concurrency limiter with FIFO queuing.
/// Used by LLM providers to limit the number of concurrent API requests.
///
/// When `current < limit`, callers pass through `wait()` immediately.
/// When `current >= limit`, callers are suspended and queued in FIFO order.
actor ConcurrencyLimiter {
    private let limit: Int
    private var current: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0, "ConcurrencyLimiter limit must be positive")
        self.limit = limit
    }

    /// Acquire a slot. Returns immediately if under the limit, otherwise suspends until a slot opens.
    func wait() async {
        if current < limit {
            current += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // current was already incremented by signal() before resuming us
    }

    /// Release a slot and wake the next waiter (if any).
    ///
    /// When a waiter exists, we increment `current` *before* resuming
    /// the continuation. This prevents actor reentrancy from allowing
    /// another `wait()` call to see `current < limit` in between.
    func signal() {
        current -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            current += 1 // reserve the slot before resuming
            next.resume()
        }
    }
}
