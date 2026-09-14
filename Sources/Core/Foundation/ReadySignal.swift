//
//  ReadySignal.swift
//  AppAgent
//

import Foundation

/// One-shot readiness signal that supports multiple waiters.
///
/// Used to gate operations that depend on async initialization completing.
/// Multiple callers can `wait()` concurrently; all are released when `signal()` is called.
/// Calling `wait()` after `signal()` returns immediately.
public actor ReadySignal {
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Mark as ready. All current and future waiters are released immediately.
    public func signal() {
        isReady = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    /// Wait until the signal is triggered. Returns immediately if already signaled.
    public func wait() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
