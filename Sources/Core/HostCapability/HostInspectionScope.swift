import Foundation

/// Explicit ownership marker, including SDK classes compiled into a host module.
/// Runtime/UI ownership resolution belongs to HostInspectionUIKit.
public protocol AppAgentRuntimeOwned: AnyObject {}

public enum HostInspectionScope: String, CaseIterable, Codable, Hashable, Sendable {
    case host
    case appagent
    case all

    public func includes(appAgentOwned: Bool) -> Bool {
        switch self {
        case .host: return !appAgentOwned
        case .appagent: return appAgentOwned
        case .all: return true
        }
    }

    public static let parameter: JSONSchema = .string(
        description: """
            Inspection scope: host (default) excludes AppAgent internals. appagent inspects \
            only the SDK; all includes both. appagent/all require separate, turn-limited \
            approval for reads and mutations. detail=full does not broaden scope.
            """,
        enumValues: allCases.map(\.rawValue),
        defaultValue: .string("host")
    )
}

/// Immutable per-call target boundary. Creating a context is not itself an approval;
/// tools obtain it through HostInspectionAccess before calling a provider.
public struct HostInspectionContext: Sendable, Equatable {
    public let scope: HostInspectionScope
    public let sceneIdentifier: String?

    public init(scope: HostInspectionScope = .host, sceneIdentifier: String? = nil) {
        self.scope = scope
        self.sceneIdentifier = sceneIdentifier
    }
}

public enum HostInspectionError: Error, LocalizedError, Sendable, Equatable {
    case invalidScope
    case denied
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .invalidScope:
            return "Invalid inspection scope. Use 'host', 'appagent', or 'all'."
        case .denied:
            return "Inspection denied: AppAgent access was not approved, was cancelled, or has expired."
        case .readOnly:
            return "Inspection denied: mutations are disabled by the readOnly policy."
        }
    }
}

enum HostInspectionAccess {
    @TaskLocal static var authorization: HostInspectionAuthorization?

    static func context(
        arguments: [String: JSONValue], session: AISession, tool: String,
        isMutation: Bool = false
    ) async throws -> HostInspectionContext {
        let scope: HostInspectionScope
        if let raw = arguments["scope"] {
            guard let value = raw.stringValue, let parsed = HostInspectionScope(rawValue: value) else {
                throw HostInspectionError.invalidScope
            }
            scope = parsed
        } else {
            scope = .host
        }
        guard !Task.isCancelled, let chain = session.decisionPolicyChain() else {
            throw HostInspectionError.denied
        }
        try checkBoundaries(scope: scope, isMutation: isMutation, chain: chain)

        let inherited = authorization.flatMap { $0.accepts(session) ? $0 : nil }
        // Ordinary host reads never invoke a policy callback or ask for SDK approval.
        if scope == .host {
            return HostInspectionContext(
                scope: scope,
                sceneIdentifier: inherited?.sceneIdentifier
                    ?? chain.compactMap(\.inspectionSceneIdentifier).first
            )
        }

        let grant = inherited ?? HostInspectionAuthorization(session: session)
        defer { if inherited == nil { grant.invalidate() } }
        let allowed = await grant.authorize(scope: scope, isMutation: isMutation, requester: session)
        // Preserve the specific readOnly error even if it was enabled while awaiting UI.
        guard session.matchesDecisionPolicyChain(chain) else { throw HostInspectionError.denied }
        try checkBoundaries(scope: scope, isMutation: isMutation, chain: chain)
        guard allowed, !Task.isCancelled, grant.isValid else {
            Logger.info("HostInspection", "\(tool): scope=\(scope.rawValue) denied")
            throw HostInspectionError.denied
        }
        return HostInspectionContext(scope: scope, sceneIdentifier: grant.sceneIdentifier)
    }

    /// Both frozen configuration and live host restrictions apply. Evaluate the whole
    /// chain's readOnly boundary first, so an SDK opt-out cannot mask that error.
    static func checkBoundaries(
        scope: HostInspectionScope, isMutation: Bool, chain: [AISession]
    ) throws {
        if isMutation, chain.contains(where: {
            $0.executionPolicy.toolMutationPolicy == .readOnly
        }) {
            throw HostInspectionError.readOnly
        }
        if scope != .host, chain.contains(where: { !$0.allowsAppAgentInspection }) {
            throw HostInspectionError.denied
        }
    }
}

/// One run's authorization cache. Task-local inheritance is necessary but not
/// sufficient: callers must be the owner or an actual descendant by object identity.
/// The cache holds user/owner decisions, never a child's policy override.
final class HostInspectionAuthorization: AppAgentRuntimeOwned, @unchecked Sendable {
    private struct Key: Hashable {
        let scope: HostInspectionScope
        let isMutation: Bool
    }

    private let session: AISession
    private let ownerChain: [AISession]
    let sceneIdentifier: String?
    private let lock = ReadersWriterLock()
    private var valid = true
    private var decisions: [Key: DecisionWaiter] = [:]
    private var callers: [UUID: DecisionWaiter] = [:]

    init(session: AISession) {
        self.session = session
        ownerChain = session.decisionPolicyChain() ?? []
        sceneIdentifier = ownerChain.compactMap(\.inspectionSceneIdentifier).first
    }

    var isValid: Bool { lock.read { valid } }

    func accepts(_ requester: AISession) -> Bool {
        guard isValid, !ownerChain.isEmpty, session.matchesDecisionPolicyChain(ownerChain),
              let chain = requester.decisionPolicyChain() else { return false }
        return chain.contains { $0 === session }
    }

    func invalidate() {
        let pending = lock.writeSync { () -> [DecisionWaiter] in
            guard valid else { return [] }
            valid = false
            let pending = Array(decisions.values) + Array(callers.values)
            decisions.removeAll()
            callers.removeAll()
            return pending
        }
        for waiter in pending { waiter.cancel(returning: .deny) }
    }

    func authorize(
        scope: HostInspectionScope, isMutation: Bool, requester: AISession? = nil
    ) async -> Bool {
        let requester = requester ?? session
        guard !Task.isCancelled, isValid, accepts(requester),
              let chain = requester.decisionPolicyChain(),
              boundariesAllow(scope: scope, isMutation: isMutation, chain: chain) else { return false }
        if scope == .host { return true }

        // Each caller has a cancellation gate around BOTH policy awaits and the shared
        // UI await. Invalidation therefore does not rely on host code cooperating either.
        let caller = DecisionWaiter()
        let id = UUID()
        let registered = lock.writeSync {
            guard valid else { return false }
            callers[id] = caller
            return true
        }
        guard registered else { return false }
        defer { _ = lock.writeSync { callers.removeValue(forKey: id) } }
        let request = DecisionRequest.appAgentInspection(scope: scope, isMutation: isMutation)

        return await withTaskCancellationHandler {
            caller.start { [self] in
                guard await policyAllows(request, requester: requester, chain: chain),
                      let shared = sharedDecision(scope: scope, isMutation: isMutation) else { return .deny }
                return await withTaskCancellationHandler {
                    shared.start { [session] in await session.requestDecision(request) }
                    let outcome = await shared.value()
                    guard !shared.isCancelled, Self.isApproval(outcome),
                          await policyAllows(request, requester: requester, chain: chain),
                          !shared.isCancelled else { return .deny }
                    return .allowOnce
                } onCancel: {
                    // A cancelled participant revokes this key for everyone in the turn.
                    // Retain the settled waiter in decisions so late callers cannot reask.
                    shared.cancel(returning: .deny)
                }
            }
            let outcome = await caller.value()
            return !Task.isCancelled && !caller.isCancelled && Self.isApproval(outcome)
                && isValid && accepts(requester) && requester.matchesDecisionPolicyChain(chain)
                && boundariesAllow(scope: scope, isMutation: isMutation, chain: chain)
        } onCancel: {
            caller.cancel(returning: .deny)
        }
    }

    private func sharedDecision(scope: HostInspectionScope, isMutation: Bool) -> DecisionWaiter? {
        lock.writeSync {
            guard valid, !Task.isCancelled else { return nil }
            let key = Key(scope: scope, isMutation: isMutation)
            if let existing = decisions[key] { return existing }
            let waiter = DecisionWaiter()
            decisions[key] = waiter
            return waiter
        }
    }

    private func policyAllows(
        _ request: DecisionRequest, requester: AISession, chain: [AISession]
    ) async -> Bool {
        guard case let .appAgentInspection(scope, isMutation) = request else { return false }
        guard !Task.isCancelled, isValid, accepts(requester),
              requester.matchesDecisionPolicyChain(chain),
              boundariesAllow(scope: scope, isMutation: isMutation, chain: chain) else { return false }
        // A child denied by host policy must not even join a pending parent decision.
        let policy = await requester.decisionHostPolicy(for: request, chain: chain)
        guard policy == nil || policy.map(Self.isApproval) == true else { return false }
        return !Task.isCancelled && isValid && accepts(requester)
            && requester.matchesDecisionPolicyChain(chain)
            && boundariesAllow(scope: scope, isMutation: isMutation, chain: chain)
    }

    private func boundariesAllow(
        scope: HostInspectionScope, isMutation: Bool, chain: [AISession]
    ) -> Bool {
        do {
            try HostInspectionAccess.checkBoundaries(scope: scope, isMutation: isMutation, chain: chain)
            return true
        } catch { return false }
    }

    private static func isApproval(_ outcome: DecisionOutcome) -> Bool {
        outcome == .allowOnce || outcome == .allowForSession
    }
}
