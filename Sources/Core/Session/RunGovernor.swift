//
//  RunGovernor.swift
//  AppAgent
//

import Foundation

/// Concurrency admission policy for top-level agent runs.
///
/// MVP: a simple fixed-limit gate. Only top-level sessions (`delegationDepth == 0`)
/// count against the limit; sub-sessions spawned by `DelegateTaskTool` are exempt.
/// The "running count" is derived directly from `executor.isRunning` at the call site
/// (see `AISessionManager.runningSessionCount`) — there is no separate counter to drift
/// out of sync with the executors.
///
/// Kept as a type (not an inline constant) so a future token / weighted / thread-safe
/// version can drop in without touching the call sites in `AISessionManager` /
/// `AISession.sendMessage`.
///
/// Immutable by construction: the only storage is `limit` (`let`) and `canAdmit` is a pure
/// function of its arguments, so plain `Sendable` holds — no `@unchecked` escape hatch needed.
/// A future stateful version must protect that state (lock or actor) instead of re-adding
/// `@unchecked`.
public final class RunGovernor: Sendable {

    /// Maximum number of concurrently running top-level sessions.
    public let limit: Int

    public init(limit: Int = 9) {
        self.limit = limit
    }

    /// Whether a new run can be admitted given the current running count.
    ///
    /// - Parameters:
    ///   - runningCount: number of top-level sessions currently running an agent loop.
    ///   - isAlreadyRunning: whether the requesting session is itself already running.
    ///     A re-run reuses its own slot, so it is always admitted.
    /// - Returns: `true` if the run may start now, `false` if it should be hard-blocked.
    public func canAdmit(runningCount: Int, isAlreadyRunning: Bool) -> Bool {
        if isAlreadyRunning { return true }
        return runningCount < limit
    }
}
