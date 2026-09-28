import XCTest
@testable import AppAgent

final class HostStateMirrorTests: XCTestCase {
    func testSnapshotPreparationDoesNotAdvanceCursorUntilCommit() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let snapshot = Self.snapshot(revision: 1, page: "home")

        try await mirror.apply(snapshot)
        await mirror.startRun(runID)

        let optionalPreparation = try await mirror.prepare(runID: runID)
        let preparation = try XCTUnwrap(optionalPreparation)
        XCTAssertEqual(preparation.mode, .snapshot)

        let beforeCommit = await mirror.currentModelSeenCursor()
        XCTAssertNil(beforeCommit)

        try await mirror.commit(preparation)

        let afterCommit = await mirror.currentModelSeenCursor()
        XCTAssertEqual(afterCommit, snapshot.cursor)
    }

    func testDeltaPreparationCanBeDiscardedAndPreparedAgain() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let snapshot = Self.snapshot(revision: 1, page: "home")
        let delta = HostStateDelta(
            cursor: StateCursor(epoch: "epoch-1", revision: 2),
            changes: .object([
                "page": .string("detail")
            ])
        )

        try await mirror.apply(snapshot)
        await mirror.startRun(runID)
        let optionalSnapshotPreparation = try await mirror.prepare(runID: runID)
        let snapshotPreparation = try XCTUnwrap(optionalSnapshotPreparation)
        try await mirror.commit(snapshotPreparation)
        try await mirror.apply(delta)

        let optionalFirstDeltaPreparation = try await mirror.prepare(runID: runID)
        let firstDeltaPreparation = try XCTUnwrap(optionalFirstDeltaPreparation)
        XCTAssertEqual(firstDeltaPreparation.mode, .delta)
        await mirror.discard(firstDeltaPreparation)

        let optionalSecondDeltaPreparation = try await mirror.prepare(runID: runID)
        let secondDeltaPreparation = try XCTUnwrap(optionalSecondDeltaPreparation)
        XCTAssertEqual(secondDeltaPreparation.mode, .delta)

        let seenBeforeCommit = await mirror.currentModelSeenCursor()
        XCTAssertEqual(seenBeforeCommit, snapshot.cursor)

        try await mirror.commit(secondDeltaPreparation)

        let seenAfterCommit = await mirror.currentModelSeenCursor()
        XCTAssertEqual(seenAfterCommit, delta.cursor)
    }

    func testBaselineInvalidationDuringPreparationForcesNextSnapshot() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let snapshot = Self.snapshot(revision: 1, page: "home")

        try await mirror.apply(snapshot)
        await mirror.startRun(runID)

        let optionalPreparation = try await mirror.prepare(runID: runID)
        let preparation = try XCTUnwrap(optionalPreparation)
        await mirror.invalidateModelBaseline()
        try await mirror.commit(preparation)

        let optionalNextPreparation = try await mirror.prepare(runID: runID)
        let nextPreparation = try XCTUnwrap(optionalNextPreparation)
        XCTAssertEqual(nextPreparation.mode, .snapshot)
    }

    func testCursorlessHostEventInvalidatesModelBaseline() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let snapshot = Self.snapshot(revision: 1, page: "home")

        try await mirror.apply(snapshot)
        await mirror.startRun(runID)
        let optionalInitialPreparation = try await mirror.prepare(runID: runID)
        let initialPreparation = try XCTUnwrap(optionalInitialPreparation)
        try await mirror.commit(initialPreparation)

        let event = HostEvent(
            eventId: "event-1",
            trigger: "user",
            action: "rename-page",
            changes: .object([
                "page": .string("detail")
            ])
        )
        try await mirror.apply(event)

        let seenCursor = await mirror.currentModelSeenCursor()
        let currentState = await mirror.currentState()
        XCTAssertNil(seenCursor)
        XCTAssertEqual(
            currentState,
            .object([
                "page": .string("detail")
            ])
        )
        let optionalNextPreparation = try await mirror.prepare(runID: runID)
        let nextPreparation = try XCTUnwrap(optionalNextPreparation)
        XCTAssertEqual(nextPreparation.mode, .snapshot)
    }

    func testPreparationFromAnEndedRunCannotCommit() async throws {
        let mirror = HostStateMirror()
        let firstRunID = UUID()
        let secondRunID = UUID()
        let snapshot = Self.snapshot(revision: 1, page: "home")

        try await mirror.apply(snapshot)
        await mirror.startRun(firstRunID)
        let optionalPreparation = try await mirror.prepare(runID: firstRunID)
        let preparation = try XCTUnwrap(optionalPreparation)
        await mirror.startRun(secondRunID)

        do {
            try await mirror.commit(preparation)
            XCTFail("A preparation from an ended run must not commit.")
        } catch let error as HostStateMirrorError {
            XCTAssertEqual(error, .preparationNotFound)
        }
    }

    func testSnapshotSchemaUpgradeResetsDeltaBaseline() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let firstSnapshot = Self.snapshot(
            schemaVersion: 1,
            revision: 1,
            page: "home"
        )
        let upgradedSnapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 3,
            page: "detail"
        )

        try await mirror.apply(firstSnapshot)
        await mirror.startRun(runID)
        let optionalInitialPreparation = try await mirror.prepare(runID: runID)
        let initialPreparation = try XCTUnwrap(optionalInitialPreparation)
        try await mirror.commit(initialPreparation)
        try await mirror.apply(
            HostStateDelta(
                stateSchemaVersion: 1,
                cursor: StateCursor(epoch: "epoch-1", revision: 2),
                changes: .object([
                    "page": .string("list")
                ])
            )
        )

        try await mirror.apply(upgradedSnapshot)

        let currentSnapshot = await mirror.currentSnapshot()
        XCTAssertEqual(currentSnapshot, upgradedSnapshot)
        let optionalNextPreparation = try await mirror.prepare(runID: runID)
        let nextPreparation = try XCTUnwrap(optionalNextPreparation)
        XCTAssertEqual(nextPreparation.mode, .snapshot)
        guard case .snapshot(let preparedSnapshot) = nextPreparation.payload else {
            return XCTFail("Schema upgrade must prepare a complete snapshot.")
        }
        XCTAssertEqual(preparedSnapshot.stateSchemaVersion, 2)
    }

    func testDeltaSchemaMismatchStillRejectsAfterSnapshot() async throws {
        let mirror = HostStateMirror()
        let snapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 1,
            page: "home"
        )

        try await mirror.apply(snapshot)

        do {
            try await mirror.apply(
                HostStateDelta(
                    stateSchemaVersion: 1,
                    cursor: StateCursor(epoch: "epoch-1", revision: 2),
                    changes: .object([
                        "page": .string("detail")
                    ])
                )
            )
            XCTFail("A delta with a stale schema must be rejected.")
        } catch let error as HostStateMirrorError {
            XCTAssertEqual(
                error,
                .schemaVersionMismatch(expected: 2, actual: 1)
            )
        }
        let currentSnapshot = await mirror.currentSnapshot()
        XCTAssertEqual(currentSnapshot, snapshot)
    }

    func testCursorEventUsesCurrentSnapshotSchemaAndCommitsMetadataOnce() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let snapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 1,
            page: "home"
        )
        let event = HostEvent(
            eventId: "event-v2",
            trigger: "user",
            action: "open-detail",
            cursor: StateCursor(epoch: "epoch-1", revision: 2),
            changes: .object([
                "page": .string("detail")
            ])
        )

        try await mirror.apply(snapshot)
        await mirror.startRun(runID)
        let optionalInitialPreparation = try await mirror.prepare(runID: runID)
        let initialPreparation = try XCTUnwrap(optionalInitialPreparation)
        try await mirror.commit(initialPreparation)
        try await mirror.apply(event)

        let optionalPreparation = try await mirror.prepare(runID: runID)
        let preparation = try XCTUnwrap(optionalPreparation)
        guard case .delta(let delta) = preparation.payload else {
            return XCTFail("A cursor event should prepare the state delta.")
        }
        XCTAssertEqual(delta.stateSchemaVersion, 2)
        XCTAssertEqual(
            preparation.payloads.compactMap { payload in
                if case .event(let preparedEvent) = payload {
                    return preparedEvent
                }
                return nil
            },
            [event]
        )
        let currentState = await mirror.currentState()
        XCTAssertEqual(currentState, .object([
            "page": .string("detail")
        ]))

        try await mirror.commit(preparation)
        let pendingEventsAfterCommit = await mirror.pendingEvents()
        XCTAssertEqual(pendingEventsAfterCommit, [])
        let duplicatePreparation = try await mirror.prepare(runID: runID)
        XCTAssertNil(duplicatePreparation)
    }

    func testCursorlessEventWithoutChangesForcesSnapshotAndDiscardRetainsMetadata() async throws {
        let mirror = HostStateMirror()
        let runID = UUID()
        let snapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 1,
            page: "home"
        )
        let event = HostEvent(
            eventId: "cursorless-event",
            trigger: "user",
            action: "refresh"
        )

        try await mirror.apply(snapshot)
        await mirror.startRun(runID)
        let optionalInitialPreparation = try await mirror.prepare(runID: runID)
        let initialPreparation = try XCTUnwrap(optionalInitialPreparation)
        try await mirror.commit(initialPreparation)
        try await mirror.apply(event)

        let optionalFirstPreparation = try await mirror.prepare(runID: runID)
        let firstPreparation = try XCTUnwrap(optionalFirstPreparation)
        XCTAssertEqual(firstPreparation.mode, .snapshot)
        await mirror.discard(firstPreparation)
        let pendingEventsAfterDiscard = await mirror.pendingEvents()
        XCTAssertEqual(pendingEventsAfterDiscard, [event])

        let optionalSecondPreparation = try await mirror.prepare(runID: runID)
        let secondPreparation = try XCTUnwrap(optionalSecondPreparation)
        try await mirror.commit(secondPreparation)
        let pendingEventsAfterCommit = await mirror.pendingEvents()
        let currentState = await mirror.currentState()
        XCTAssertEqual(pendingEventsAfterCommit, [])
        XCTAssertEqual(currentState, snapshot.state)
    }

    func testFailedCursorEventApplyRemainsPendingAndForcesSnapshot() async throws {
        let mirror = HostStateMirror()
        let snapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 1,
            page: "home"
        )
        let event = HostEvent(
            eventId: "gap-event",
            trigger: "system",
            action: "jump",
            cursor: StateCursor(epoch: "epoch-1", revision: 3),
            changes: .object([
                "page": .string("detail")
            ])
        )

        try await mirror.apply(snapshot)

        do {
            try await mirror.apply(event)
            XCTFail("A cursor gap must be rejected.")
        } catch let error as HostStateMirrorError {
            XCTAssertEqual(
                error,
                .revisionGap(expected: 2, actual: 3)
            )
        }
        let pendingEvents = await mirror.pendingEvents()
        XCTAssertEqual(pendingEvents, [event])
        let runID = UUID()
        await mirror.startRun(runID)
        let optionalPreparation = try await mirror.prepare(runID: runID)
        let preparation = try XCTUnwrap(optionalPreparation)
        XCTAssertEqual(preparation.mode, .snapshot)
    }

    func testSnapshotRefreshPreservesEventInboxWithinProviderGeneration() async throws {
        let mirror = HostStateMirror()
        let snapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 1,
            page: "home"
        )
        let event = HostEvent(
            eventId: "refresh-event",
            trigger: "system",
            action: "refresh"
        )

        try await mirror.apply(snapshot)
        try await mirror.apply(event)
        let refreshedSnapshot = Self.snapshot(
            schemaVersion: 2,
            revision: 2,
            page: "detail"
        )
        try await mirror.apply(refreshedSnapshot)

        let pendingEvents = await mirror.pendingEvents()
        XCTAssertEqual(pendingEvents, [event])
    }

    private static func snapshot(
        schemaVersion: Int = 1,
        revision: Int,
        page: String
    ) -> HostStateSnapshot {
        HostStateSnapshot(
            stateSchemaVersion: schemaVersion,
            cursor: StateCursor(epoch: "epoch-1", revision: revision),
            state: .object([
                "page": .string(page)
            ])
        )
    }
}
