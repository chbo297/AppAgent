import Foundation

/// A multicast, one-shot decision. Cancellation settles callers synchronously; it
/// never awaits the worker (a host responder may ignore cancellation altogether).
final class DecisionWaiter: AppAgentRuntimeOwned, @unchecked Sendable {
    private let lock = ReadersWriterLock()
    private var started = false
    private var settling = false
    private var cancelled = false
    private var result: DecisionOutcome?
    private var worker: Task<Void, Never>?
    private var continuations: [CheckedContinuation<DecisionOutcome, Never>] = []
    private var onSettle: (@Sendable () -> Void)?

    init(onSettle: @escaping @Sendable () -> Void = {}) {
        self.onSettle = onSettle
    }

    var isCancelled: Bool { lock.read { cancelled } }

    func start(_ operation: @escaping @Sendable () async -> DecisionOutcome) {
        let shouldStart = lock.writeSync { () -> Bool in
            guard !started, !settling, result == nil else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        // Do not create/run foreign async work while holding the state lock. The
        // cancellation path may race this task before its handle is published.
        let task = Task { [weak self] in
            guard !Task.isCancelled, self?.canRun == true else { return }
            let outcome = await operation()
            self?.settle(outcome)
        }
        let cancelImmediately = lock.writeSync { () -> Bool in
            guard !settling, result == nil else { return true }
            worker = task
            return false
        }
        if cancelImmediately { task.cancel() }
    }

    private var canRun: Bool { lock.read { !settling && result == nil } }

    func value() async -> DecisionOutcome {
        await withCheckedContinuation { continuation in
            let ready = lock.writeSync { () -> DecisionOutcome? in
                if let result { return result }
                // Arrivals during cleanup also wait: nobody may observe completion
                // before onSettle has removed the pending-decision registration.
                continuations.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func cancel(returning outcome: DecisionOutcome) {
        finish(outcome, cancelling: true)
    }

    func settle(_ outcome: DecisionOutcome) {
        finish(outcome, cancelling: false)
    }

    private func finish(_ outcome: DecisionOutcome, cancelling: Bool) {
        let completion = lock.writeSync { () -> (Task<Void, Never>?, (@Sendable () -> Void)?)? in
            // Even a cancellation losing the answer race must remain observable.
            if cancelling { cancelled = true }
            guard !settling, result == nil else { return nil }
            settling = true
            let completion = (worker, onSettle)
            worker = nil
            onSettle = nil
            return completion
        }
        guard let (task, cleanup) = completion else { return }
        // No foreign code or cancellation handler runs under our state lock.
        // Propagate cancellation BEFORE publishing: nested decision waiters can
        // synchronously clear their pending state before the outer callers resume.
        if cancelling { task?.cancel() }
        cleanup?()
        let waiting = lock.writeSync {
            result = outcome
            let waiting = continuations
            continuations.removeAll()
            return waiting
        }
        for continuation in waiting { continuation.resume(returning: outcome) }
    }
}

/// Serializes pending installation with cleanup, including cancellation before
/// the policy worker has even reached the responder. UI callbacks are dispatched
/// by SessionUIState, never executed under this lock.
final class DecisionPendingRegistration: AppAgentRuntimeOwned, @unchecked Sendable {
    private let lock = ReadersWriterLock()
    private let state: SessionUIState
    private let request: DecisionRequest
    private var installed = false
    private var closed = false

    init(state: SessionUIState, request: DecisionRequest) {
        self.state = state
        self.request = request
    }

    func install() -> Bool {
        lock.writeSync {
            guard !closed else { return false }
            if !installed {
                state.setPendingDecision(request)
                installed = true
            }
            return true
        }
    }

    func clear() {
        lock.writeSync {
            guard !closed else { return }
            closed = true
            if installed { state.clearPendingDecision(request) }
        }
    }
}
