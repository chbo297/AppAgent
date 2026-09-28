import XCTest
@testable import AppAgent

final class HostStateProviderGenerationTests: XCTestCase {
    func testOlderProviderSnapshotCannotOverwriteNewProvider() async throws {
        let session = AISession(id: "provider-generation")
        let oldProvider = ControlledHostStateProvider(
            snapshot: Self.snapshot(revision: 1, page: "old"),
            defersSnapshot: true
        )
        let newProvider = ControlledHostStateProvider(
            snapshot: Self.snapshot(revision: 1, page: "new")
        )

        let oldInstall = Task {
            try? await session.installHostStateProvider(oldProvider)
        }
        await oldProvider.waitUntilSnapshotRequested()

        try await session.installHostStateProvider(newProvider)
        await oldProvider.releaseSnapshot()
        _ = await oldInstall.value

        let currentState = await session.hostStateMirror.currentState()
        XCTAssertEqual(
            currentState,
            .object([
                "page": .string("new")
            ])
        )
        oldProvider.finish()
        newProvider.finish()
    }

    func testOldProviderUpdateCannotOverwriteReplacementSnapshot() async throws {
        let session = AISession(id: "provider-update-generation")
        let oldProvider = ControlledHostStateProvider(
            snapshot: Self.snapshot(revision: 1, page: "old")
        )
        let newProvider = ControlledHostStateProvider(
            snapshot: Self.snapshot(revision: 1, page: "new")
        )

        try await session.installHostStateProvider(oldProvider)
        await Task.yield()
        try await session.installHostStateProvider(newProvider)

        oldProvider.send(
            .delta(
                HostStateDelta(
                    cursor: StateCursor(epoch: "epoch-1", revision: 2),
                    changes: .object([
                        "page": .string("old-detail")
                    ])
                )
            )
        )
        await Task.yield()

        let currentState = await session.hostStateMirror.currentState()
        XCTAssertEqual(
            currentState,
            .object([
                "page": .string("new")
            ])
        )
        oldProvider.finish()
        newProvider.finish()
    }

    func testDelayedOldSnapshotAfterRemoveAndReinstallCannotClearNewState() async throws {
        let session = AISession(id: "provider-remove-reinstall")
        let oldProvider = ControlledHostStateProvider(
            snapshot: Self.snapshot(revision: 1, page: "old"),
            defersSnapshot: true
        )
        let newProvider = ControlledHostStateProvider(
            snapshot: Self.snapshot(revision: 1, page: "new")
        )

        let oldInstall = Task {
            try? await session.installHostStateProvider(oldProvider)
        }
        await oldProvider.waitUntilSnapshotRequested()

        await session.removeHostStateProvider()
        try await session.installHostStateProvider(newProvider)
        await oldProvider.releaseSnapshot()
        _ = await oldInstall.value

        let currentState = await session.hostStateMirror.currentState()
        XCTAssertEqual(
            currentState,
            .object([
                "page": .string("new")
            ])
        )
        oldProvider.finish()
        newProvider.finish()
    }

    func testOldGenerationUpdateIsRejectedAfterRemoval() async throws {
        let mirror = HostStateMirror()
        let oldGeneration = await mirror.activateProviderGeneration()
        let snapshot = Self.snapshot(revision: 1, page: "old")
        let update = HostStateUpdate.delta(
            HostStateDelta(
                cursor: StateCursor(epoch: "epoch-1", revision: 2),
                changes: .object([
                    "page": .string("stale")
                ])
            )
        )

        let acceptedSnapshot = try await mirror.apply(
            snapshot,
            providerGeneration: oldGeneration
        )
        XCTAssertTrue(acceptedSnapshot)
        await mirror.removeProviderGeneration()
        let accepted = try await mirror.apply(
            update,
            providerGeneration: oldGeneration
        )
        XCTAssertFalse(accepted)
        let currentState = await mirror.currentState()
        XCTAssertEqual(currentState, snapshot.state)
    }

    private static func snapshot(revision: Int, page: String) -> HostStateSnapshot {
        HostStateSnapshot(
            cursor: StateCursor(epoch: "epoch-1", revision: revision),
            state: .object([
                "page": .string(page)
            ])
        )
    }
}

private final class ControlledHostStateProvider: HostStateProvider, @unchecked Sendable {
    private let snapshotValue: HostStateSnapshot
    private let snapshotGate: SnapshotGate?
    private let stream: AsyncStream<HostStateUpdate>
    private let streamContinuation: AsyncStream<HostStateUpdate>.Continuation

    init(
        snapshot: HostStateSnapshot,
        defersSnapshot: Bool = false
    ) {
        self.snapshotValue = snapshot
        if defersSnapshot {
            self.snapshotGate = SnapshotGate(snapshot: snapshot)
        } else {
            self.snapshotGate = nil
        }
        let pair = AsyncStream<HostStateUpdate>.makePair()
        self.stream = pair.stream
        self.streamContinuation = pair.continuation
    }

    func snapshot() async throws -> HostStateSnapshot {
        if let snapshotGate {
            return await snapshotGate.wait()
        }
        return snapshotValue
    }

    func updates() -> AsyncStream<HostStateUpdate> {
        stream
    }

    func waitUntilSnapshotRequested() async {
        guard let snapshotGate else {
            return
        }
        await snapshotGate.waitUntilRequested()
    }

    func releaseSnapshot() async {
        guard let snapshotGate else {
            return
        }
        await snapshotGate.release()
    }

    func send(_ update: HostStateUpdate) {
        streamContinuation.yield(update)
    }

    func finish() {
        streamContinuation.finish()
    }
}

private actor SnapshotGate {
    private let snapshot: HostStateSnapshot
    private var isRequested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var snapshotWaiters: [
        CheckedContinuation<HostStateSnapshot, Never>
    ] = []

    init(snapshot: HostStateSnapshot) {
        self.snapshot = snapshot
    }

    func wait() async -> HostStateSnapshot {
        markRequested()
        if isReleased {
            return snapshot
        }
        return await withCheckedContinuation { continuation in
            snapshotWaiters.append(continuation)
        }
    }

    func waitUntilRequested() async {
        if isRequested {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else {
            return
        }
        isReleased = true
        let waiters = snapshotWaiters
        snapshotWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
    }

    private func markRequested() {
        guard !isRequested else {
            return
        }
        isRequested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
