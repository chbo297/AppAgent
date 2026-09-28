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
final class SessionLifecycleState: AppAgentRuntimeOwned, @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false

    func start(_ body: () -> AsyncStream<AIAgentEvent>) -> AsyncStream<AIAgentEvent> {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else {
            return AsyncStream {
                $0.yield(.error(SessionLifecycleError.invalid("Session is being archived or merged; restore it before running.")))
                $0.finish()
            }
        }
        return body()
    }

    func suspend(_ session: AISession) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { throw SessionLifecycleError.inactive(session.id) }
        guard !session.isRunning, !session.uiState.isStreaming,
              !session.turnRecords.values.contains(where: { !$0.isFinished }) else {
            throw SessionLifecycleError.running(session.id)
        }
        suspended = true
    }

    func resume() {
        lock.lock()
        suspended = false
        lock.unlock()
    }
}
