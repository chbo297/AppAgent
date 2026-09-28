import XCTest
@testable import AppAgent

final class HostInspectionScopeTests: XCTestCase {
    private func session(responder: ScopeResponder? = nil) -> AISession {
        let session = AISession(id: UUID().uuidString)
        session.decisionResponders = DecisionResponderCentral()
        if let responder { session.decisionResponders.register(responder) }
        return session
    }

    func testHostAndFullDetailNeverRequestApproval() async throws {
        let responder = ScopeResponder()
        let session = session(responder: responder)
        session.inspectionSceneIdentifier = "scene-A"
        let context = try await HostInspectionAccess.context(
            arguments: ["detail": .string("full")], session: session, tool: "test"
        )
        XCTAssertEqual(context, HostInspectionContext(sceneIdentifier: "scene-A"))
        XCTAssertTrue(responder.requests.isEmpty)
    }

    func testMissingResponderInvalidScopeAndHostOptOutFailClosed() async {
        let session = session()
        for arguments: [String: JSONValue] in [
            ["scope": .string("appagent")], ["scope": .string("everything")], ["scope": .null]
        ] {
            do {
                _ = try await HostInspectionAccess.context(arguments: arguments, session: session, tool: "test")
                XCTFail("must reject")
            } catch {}
        }
        let responder = ScopeResponder()
        session.decisionResponders.register(responder)
        session.allowsAppAgentInspection = false
        do {
            _ = try await HostInspectionAccess.context(
                arguments: ["scope": .string("all")], session: session, tool: "test"
            )
            XCTFail("host opt-out must reject")
        } catch {}
        XCTAssertTrue(responder.requests.isEmpty)
    }

    func testTurnCoalescesReadsButNotWritesOrWiderScope() async {
        let responder = ScopeResponder()
        let session = session(responder: responder)
        let grant = HostInspectionAuthorization(session: session)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask { await grant.authorize(scope: .appagent, isMutation: false) }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(responder.requests.count, 1)
        let write = await grant.authorize(scope: .appagent, isMutation: true)
        let all = await grant.authorize(scope: .all, isMutation: false)
        XCTAssertTrue(write)
        XCTAssertTrue(all)
        XCTAssertEqual(responder.requests.count, 3)
        grant.invalidate()
        let expired = await grant.authorize(scope: .appagent, isMutation: false)
        XCTAssertFalse(expired)
        let nextTurn = HostInspectionAuthorization(session: session)
        _ = await nextTurn.authorize(scope: .appagent, isMutation: false)
        XCTAssertEqual(responder.requests.count, 4, "allowForSession is still capped to the turn")
        nextTurn.invalidate()
    }

    func testReadOnlyDoesNotAskToEscalate() async {
        var profile = AIAgentProfile()
        profile.toolMutationPolicy = .readOnly
        let session = AISession(id: "read-only", agentMask: AIAgentMask(
            profile: profile, toolCentral: ToolCentral()
        ))
        let responder = ScopeResponder()
        session.decisionResponders = DecisionResponderCentral()
        session.decisionResponders.register(responder)
        do {
            _ = try await HostInspectionAccess.context(
                arguments: ["scope": .string("all")], session: session, tool: "test", isMutation: true
            )
            XCTFail("read-only must reject")
        } catch {}
        XCTAssertTrue(responder.requests.isEmpty)
    }

    func testDelegationInheritsRestrictionsAndRoutesDecisionToParent() async throws {
        let responder = ScopeResponder()
        let parent = session(responder: responder)
        parent.inspectionSceneIdentifier = "scene-parent"
        parent.toolPolicy = .init(
            allowedNames: ["screenshot", "delegate_task"], excludedNames: ["app_hotfix"],
            allowedGroups: ["host-runtime"], excludedGroups: ["host-storage"]
        )
        let child = session()
        DelegateTaskTool.inheritBoundaries(from: parent, into: child)
        XCTAssertEqual(child.toolPolicy?.allowedNames, parent.toolPolicy?.allowedNames)
        XCTAssertEqual(child.toolPolicy?.excludedNames, ["app_hotfix", "delegate_task"])
        XCTAssertEqual(child.toolPolicy?.allowedGroups, parent.toolPolicy?.allowedGroups)
        XCTAssertEqual(child.toolPolicy?.excludedGroups, parent.toolPolicy?.excludedGroups)
        XCTAssertEqual(child.inspectionSceneIdentifier, "scene-parent")
        let grant = HostInspectionAuthorization(session: parent)
        try await HostInspectionAccess.$authorization.withValue(grant) {
            _ = try await HostInspectionAccess.context(
                arguments: ["scope": .string("appagent")], session: parent, tool: "test"
            )
            let context = try await HostInspectionAccess.context(
                arguments: ["scope": .string("appagent")], session: child, tool: "test"
            )
            XCTAssertEqual(context.sceneIdentifier, "scene-parent")
        }
        XCTAssertEqual(responder.requests.count, 1)
        _ = await child.requestDecision(.clarification(question: "child", choices: []))
        XCTAssertEqual(responder.sessionIDs.last, parent.id)
        parent.allowsAppAgentInspection = false
        let anotherChild = session()
        DelegateTaskTool.inheritBoundaries(from: parent, into: anotherChild)
        XCTAssertFalse(anotherChild.allowsAppAgentInspection)
        grant.invalidate()
    }

    func testDeniedGrantIsCachedOnlyWithinTurn() async {
        let responder = ScopeResponder(outcome: .deny)
        let session = session(responder: responder)
        let grant = HostInspectionAuthorization(session: session)
        let first = await grant.authorize(scope: .all, isMutation: false)
        let second = await grant.authorize(scope: .all, isMutation: false)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(responder.requests.count, 1)
        grant.invalidate()
    }

    func testGrantDoesNotLeakToUnrelatedSessionAndFreezesScene() async throws {
        let responder = ScopeResponder()
        let owner = session(responder: responder)
        owner.inspectionSceneIdentifier = "original"
        let grant = HostInspectionAuthorization(session: owner)
        owner.inspectionSceneIdentifier = "changed"
        let unrelated = session()
        try await HostInspectionAccess.$authorization.withValue(grant) {
            let context = try await HostInspectionAccess.context(
                arguments: ["scope": .string("all")], session: owner, tool: "test"
            )
            XCTAssertEqual(context.sceneIdentifier, "original")
            do {
                _ = try await HostInspectionAccess.context(
                    arguments: ["scope": .string("all")], session: unrelated, tool: "test"
                )
                XCTFail("unrelated sessions must not share the grant")
            } catch {}
        }
        grant.invalidate()
    }

    func testCancellationCannotTurnLateApprovalIntoGrant() async {
        let started = expectation(description: "decision started")
        let responder = ScopeResponder(onRequest: { started.fulfill() }, suspend: true)
        let session = session(responder: responder)
        let grant = HostInspectionAuthorization(session: session)
        let task = Task { await grant.authorize(scope: .all, isMutation: true) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNil(session.uiState.pendingDecision)
        grant.invalidate()
    }

    func testPendingApprovalRechecksParentAndChildOptOut() async {
        for scope in [HostInspectionScope.appagent, .all] {
            for isMutation in [false, true] {
                for revokeParent in [false, true] {
                    let started = expectation(description: "approval pending")
                    let responder = ScopeResponder(onRequest: { started.fulfill() }, hold: true)
                    let parent = session(responder: responder)
                    let child = session()
                    child.decisionParent = parent
                    let grant = HostInspectionAuthorization(session: parent)
                    let task = Task {
                        await HostInspectionAccess.$authorization.withValue(grant) {
                            do {
                                _ = try await HostInspectionAccess.context(
                                    arguments: ["scope": .string(scope.rawValue)], session: child,
                                    tool: "test", isMutation: isMutation
                                )
                                return false
                            } catch HostInspectionError.denied { return true }
                            catch { return false }
                        }
                    }
                    await fulfillment(of: [started], timeout: 2)
                    (revokeParent ? parent : child).allowsAppAgentInspection = false
                    responder.release()
                    let denied = await task.value
                    XCTAssertTrue(denied, "\(scope), mutation=\(isMutation), parent=\(revokeParent)")
                    XCTAssertEqual(responder.sessionIDs, [parent.id])
                    XCTAssertNil(parent.uiState.pendingDecision)
                    grant.invalidate()
                }
            }
        }
    }

    func testStandaloneApprovalRechecksOptOut() async {
        let started = expectation(description: "standalone approval pending")
        let responder = ScopeResponder(onRequest: { started.fulfill() }, hold: true)
        let session = session(responder: responder)
        let task = Task {
            do {
                _ = try await HostInspectionAccess.context(
                    arguments: ["scope": .string("all")], session: session, tool: "test"
                )
                return false
            } catch HostInspectionError.denied { return true }
            catch { return false }
        }
        await fulfillment(of: [started], timeout: 2)
        session.allowsAppAgentInspection = false
        responder.release()
        let denied = await task.value
        XCTAssertTrue(denied)
    }

    func testDecisionHonorsChildAndParentPolicyBeforeRoutingUI() async {
        let policy = ScopePolicy()
        let agent = policyAgent(policy)
        let parent = policySession(agent: agent)
        let child = policySession(agent: agent)
        child.decisionParent = parent
        let parentResponder = ScopeResponder()
        let childResponder = ScopeResponder()
        parent.decisionResponders.register(parentResponder)
        child.decisionResponders.register(childResponder)
        let requests: [DecisionRequest] = [
            .appAgentInspection(scope: .appagent, isMutation: false),
            .appAgentInspection(scope: .all, isMutation: true),
            .toolAuthorization(tool: "test", safetyLevel: .dangerous, detail: nil),
            .privateNetworkAccess(host: "localhost", url: "http://localhost")
        ]
        for request in requests {
            policy.set(.deny, for: child)
            policy.set(.allowOnce, for: parent)
            let childDenial = await child.requestDecision(request)
            XCTAssertEqual(childDenial, .deny)
            policy.set(.allowForSession, for: child)
            policy.set(.deny, for: parent)
            let parentDenial = await child.requestDecision(request)
            XCTAssertEqual(parentDenial, .deny, "child allow must not skip parent deny")
        }
        XCTAssertTrue(parentResponder.requests.isEmpty)
        XCTAssertTrue(childResponder.requests.isEmpty)

        policy.set(nil, for: child)
        policy.set(nil, for: parent)
        let routed = await child.requestDecision(requests[0])
        XCTAssertEqual(routed, .allowForSession)
        XCTAssertEqual(Array(policy.sessionIDs.suffix(2)), [child.id, parent.id])
        XCTAssertEqual(parentResponder.sessionIDs, [parent.id])
        XCTAssertTrue(childResponder.requests.isEmpty)
        withExtendedLifetime(agent) {}
    }

    func testCachedTurnGrantCannotBypassChildOrParentPolicy() async throws {
        let policy = ScopePolicy()
        let agent = policyAgent(policy)
        let parent = policySession(agent: agent)
        let child = policySession(agent: agent)
        child.decisionParent = parent
        let responder = ScopeResponder()
        parent.decisionResponders.register(responder)
        let grant = HostInspectionAuthorization(session: parent)
        defer { grant.invalidate() }
        try await HostInspectionAccess.$authorization.withValue(grant) {
            for isMutation in [false, true] {
                policy.set(nil, for: parent)
                policy.set(nil, for: child)
                _ = try await HostInspectionAccess.context(
                    arguments: ["scope": .string("appagent")], session: parent,
                    tool: "test", isMutation: isMutation
                )
                for denyChild in [true, false] {
                    policy.set(denyChild ? .deny : .allowOnce, for: child)
                    policy.set(denyChild ? .allowOnce : .deny, for: parent)
                    do {
                        _ = try await HostInspectionAccess.context(
                            arguments: ["scope": .string("appagent")], session: child,
                            tool: "test", isMutation: isMutation
                        )
                        XCTFail("a cached user answer must not override either host policy")
                    } catch HostInspectionError.denied {}
                }
                policy.set(nil, for: parent)
                policy.set(nil, for: child)
                _ = try await HostInspectionAccess.context(
                    arguments: ["scope": .string("appagent")], session: child,
                    tool: "test", isMutation: isMutation
                )
            }
        }
        XCTAssertEqual(responder.requests.count, 2, "read and write grants remain separate")
        XCTAssertTrue(policy.sessionIDs.contains(child.id))
        withExtendedLifetime(agent) {}
    }

    func testDeniedChildCannotJoinPendingParentGrant() async {
        let policy = ScopePolicy()
        let agent = policyAgent(policy)
        let parent = policySession(agent: agent)
        let child = policySession(agent: agent)
        child.decisionParent = parent
        policy.set(.deny, for: child)
        let started = expectation(description: "parent pending")
        let childFinished = expectation(description: "child rejected without waiting for parent")
        let responder = ScopeResponder(onRequest: { started.fulfill() }, hold: true)
        parent.decisionResponders.register(responder)
        let grant = HostInspectionAuthorization(session: parent)
        let parentTask = Task { await grant.authorize(scope: .all, isMutation: false) }
        await fulfillment(of: [started], timeout: 2)
        let childTask = Task {
            let result = await grant.authorize(scope: .all, isMutation: false, requester: child)
            XCTAssertFalse(result)
            childFinished.fulfill()
        }
        await fulfillment(of: [childFinished], timeout: 2)
        responder.release()
        await childTask.value
        let parentResult = await parentTask.value
        XCTAssertTrue(parentResult, "a child-specific denial must not poison the parent's grant")
        XCTAssertEqual(responder.requests.count, 1)
        grant.invalidate()
        withExtendedLifetime(agent) {}
    }

    func testSDKMutationAllowedButReadAndWriteScopeGrantsStaySeparate() async throws {
        let responder = ScopeResponder()
        let session = session(responder: responder)
        let grant = HostInspectionAuthorization(session: session)
        defer { grant.invalidate() }
        try await HostInspectionAccess.$authorization.withValue(grant) {
            for scope in [HostInspectionScope.appagent, .all] {
                for isMutation in [false, true] {
                    for _ in 0..<2 {
                        let context = try await HostInspectionAccess.context(
                            arguments: ["scope": .string(scope.rawValue)], session: session,
                            tool: "test", isMutation: isMutation
                        )
                        XCTAssertEqual(context.scope, scope)
                    }
                }
            }
        }
        XCTAssertEqual(responder.requests, [
            .appAgentInspection(scope: .appagent, isMutation: false),
            .appAgentInspection(scope: .appagent, isMutation: true),
            .appAgentInspection(scope: .all, isMutation: false),
            .appAgentInspection(scope: .all, isMutation: true)
        ])
    }

    func testReadOnlyChildCannotReuseParentMutationGrant() async throws {
        let responder = ScopeResponder()
        let parent = session(responder: responder)
        var profile = AIAgentProfile()
        profile.toolMutationPolicy = .readOnly
        let child = AISession(id: "read-only-child", agentMask: AIAgentMask(
            profile: profile, toolCentral: ToolCentral()
        ))
        child.decisionParent = parent
        let grant = HostInspectionAuthorization(session: parent)
        defer { grant.invalidate() }
        try await HostInspectionAccess.$authorization.withValue(grant) {
            _ = try await HostInspectionAccess.context(
                arguments: ["scope": .string("all")], session: parent, tool: "test", isMutation: true
            )
            do {
                _ = try await HostInspectionAccess.context(
                    arguments: ["scope": .string("all")], session: child, tool: "test", isMutation: true
                )
                XCTFail("readOnly must reject even with a cached parent write grant")
            } catch HostInspectionError.readOnly {}
            _ = try await HostInspectionAccess.context(
                arguments: ["scope": .string("all")], session: child, tool: "test"
            )
        }
        XCTAssertEqual(responder.requests.count, 2, "readOnly still permits approved SDK reads")
    }

    func testReadOnlyParentAndOptOutDoNotAddHostConfirmation() async throws {
        var profile = AIAgentProfile()
        profile.toolMutationPolicy = .readOnly
        let parent = AISession(id: "read-only-parent", agentMask: AIAgentMask(
            profile: profile, toolCentral: ToolCentral()
        ))
        let responder = ScopeResponder()
        parent.decisionResponders = DecisionResponderCentral()
        parent.decisionResponders.register(responder)
        let child = session()
        child.decisionParent = parent
        parent.allowsAppAgentInspection = false
        child.allowsAppAgentInspection = false
        for scope in HostInspectionScope.allCases {
            do {
                _ = try await HostInspectionAccess.context(
                    arguments: ["scope": .string(scope.rawValue)], session: child,
                    tool: "test", isMutation: true
                )
                XCTFail("parent readOnly cannot be escalated")
            } catch HostInspectionError.readOnly {}
        }
        let context = try await HostInspectionAccess.context(
            arguments: ["scope": .string("host"), "detail": .string("full")],
            session: child, tool: "test"
        )
        XCTAssertEqual(context.scope, .host)
        XCTAssertTrue(responder.requests.isEmpty)
    }

    func testCancellationSettlesSharedWaitersWithoutResponderCooperation() async {
        await checkUncooperativeResponder(invalidate: false)
    }

    func testInvalidationSettlesSharedWaitersWithoutResponderCooperation() async {
        await checkUncooperativeResponder(invalidate: true)
    }

    private func checkUncooperativeResponder(invalidate: Bool) async {
        let started = expectation(description: "uncooperative responder entered")
        let finished = expectation(description: "all scope callers finish before responder release")
        finished.expectedFulfillmentCount = 12
        let responder = ScopeResponder(onRequest: { started.fulfill() }, hold: true)
        let session = session(responder: responder)
        let grant = HostInspectionAuthorization(session: session)
        let first = Task {
            let result = await grant.authorize(scope: .all, isMutation: true)
            XCTAssertFalse(result)
            finished.fulfill()
        }
        // Cancel a caller known to own the pending decision, not an unscheduled task
        // that could observe cancellation before it ever joins the shared waiter.
        await fulfillment(of: [started], timeout: 2)
        let others = (0..<11).map { _ in
            Task {
                let result = await grant.authorize(scope: .all, isMutation: true)
                XCTAssertFalse(result)
                finished.fulfill()
            }
        }
        if invalidate { grant.invalidate() } else { first.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertNil(session.uiState.pendingDecision)
        XCTAssertEqual(responder.requests.count, 1)
        // Release only AFTER the bounded assertion: the old await task.value would time out.
        responder.release()
        await first.value
        for task in others { await task.value }
        let late = await grant.authorize(scope: .all, isMutation: true)
        XCTAssertFalse(late, "late approval must not resurrect a cancelled/invalidated grant")
        grant.invalidate()
    }

    func testCancelledDirectDecisionClearsPendingWithoutResponderCooperation() async {
        let started = expectation(description: "decision pending")
        let finished = expectation(description: "decision cancelled before responder release")
        let responder = ScopeResponder(onRequest: { started.fulfill() }, hold: true)
        let parent = session(responder: responder)
        let child = session()
        child.decisionParent = parent
        let task = Task {
            let outcome = await child.requestDecision(.appAgentInspection(scope: .all, isMutation: true))
            XCTAssertEqual(outcome, .deny)
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(parent.uiState.pendingDecision)
        XCTAssertNil(child.uiState.pendingDecision)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertNil(parent.uiState.pendingDecision)
        responder.release()
        await task.value
    }

    func testWaiterCancellationBeforeStartAndRepeatedSettlementAreExactlyOnce() async {
        let cleanupCount = Locked(wrappedValue: 0)
        let waiter = DecisionWaiter(onSettle: { cleanupCount.mutate { $0 += 1 } })
        waiter.cancel(returning: .deny)
        waiter.cancel(returning: .allowOnce)
        waiter.start {
            XCTFail("a settled waiter must never start its responder")
            return .allowOnce
        }
        let result = await waiter.value()
        XCTAssertEqual(result, .deny)
        XCTAssertTrue(waiter.isCancelled)
        XCTAssertEqual(cleanupCount.wrappedValue, 1)
    }

    func testWaiterConcurrentAnswerAndCancellationSettleExactlyOnce() async {
        for _ in 0..<32 {
            let cleanupCount = Locked(wrappedValue: 0)
            let waiter = DecisionWaiter(onSettle: { cleanupCount.mutate { $0 += 1 } })
            waiter.start { .allowOnce }
            let results = await withTaskGroup(of: DecisionOutcome.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        if index.isMultiple(of: 2) { waiter.cancel(returning: .deny) }
                        return await waiter.value()
                    }
                }
                var results: [DecisionOutcome] = []
                for await result in group { results.append(result) }
                return results
            }
            XCTAssertEqual(results.count, 12)
            XCTAssertTrue(results.allSatisfy { $0 == results.first })
            XCTAssertTrue(waiter.isCancelled)
            XCTAssertEqual(cleanupCount.wrappedValue, 1)
        }
    }

    private func policyAgent(_ policy: ScopePolicy) -> AIAgent {
        var profile = AIAgentProfile()
        profile.registerBuiltInTools = false
        let agent = AIAgent(
            id: UUID().uuidString, profile: profile, toolCentral: ToolCentral(),
            providerCentral: ModelProviderCentral(), memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        agent.delegate = policy
        return agent
    }

    private func policySession(agent: AIAgent) -> AISession {
        let session = AISession(id: UUID().uuidString, agentMask: AIAgentMask(
            profile: agent.profile, toolCentral: agent.toolCentral, agent: agent
        ))
        session.decisionResponders = DecisionResponderCentral()
        return session
    }
}

private final class ScopePolicy: AIAgentDelegate, @unchecked Sendable {
    private let lock = ReadersWriterLock()
    private var outcomes: [String: DecisionOutcome] = [:]
    private var recordedIDs: [String] = []
    var sessionIDs: [String] { lock.read { recordedIDs } }

    func set(_ outcome: DecisionOutcome?, for session: AISession) {
        lock.writeSync { outcomes[session.id] = outcome }
    }

    func aiAgent(_ aiAgent: AIAgent, session: AISession,
                 policyFor request: DecisionRequest) async -> DecisionOutcome? {
        lock.writeSync {
            recordedIDs.append(session.id)
            return outcomes[session.id]
        }
    }
}

private final class ScopeResponder: DecisionResponder, @unchecked Sendable {
    private let lock = ReadersWriterLock()
    private var recordedRequests: [DecisionRequest] = []
    private var recordedIDs: [String] = []
    let outcome: DecisionOutcome
    let onRequest: @Sendable () -> Void
    let suspend: Bool
    let hold: Bool
    private var heldContinuation: CheckedContinuation<DecisionOutcome?, Never>?
    private var released = false
    var requests: [DecisionRequest] { lock.read { recordedRequests } }
    var sessionIDs: [String] { lock.read { recordedIDs } }

    init(outcome: DecisionOutcome = .allowForSession,
         onRequest: @escaping @Sendable () -> Void = {}, suspend: Bool = false, hold: Bool = false) {
        self.outcome = outcome
        self.onRequest = onRequest
        self.suspend = suspend
        self.hold = hold
    }

    func respond(to request: DecisionRequest, session: AISession) async -> DecisionOutcome? {
        lock.writeSync {
            recordedRequests.append(request)
            recordedIDs.append(session.id)
        }
        if hold {
            // Deliberately no cancellation handler: only the test can release this responder.
            return await withCheckedContinuation { continuation in
                let resumeNow = lock.writeSync {
                    if released { return true }
                    heldContinuation = continuation
                    return false
                }
                onRequest()
                if resumeNow { continuation.resume(returning: outcome) }
            }
        }
        onRequest()
        if suspend { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        return outcome // Deliberately approves even after cancellation; the grant must reject it.
    }

    func release() {
        let continuation = lock.writeSync {
            released = true
            let continuation = heldContinuation
            heldContinuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
