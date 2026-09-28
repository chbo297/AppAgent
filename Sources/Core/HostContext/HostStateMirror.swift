//
//  HostStateMirror.swift
//  AppAgent
//

import Foundation

public enum HostStateMirrorError: Error, Sendable, Equatable {
    case snapshotRequired
    case epochChanged
    case revisionGap(expected: Int, actual: Int)
    case schemaVersionMismatch(expected: Int, actual: Int)
    case eventInboxFull
    case stalePreparation
    case preparationNotFound
}

extension HostStateMirrorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .snapshotRequired:
            return "A complete host state snapshot is required before applying this update."
        case .epochChanged:
            return "The host state epoch changed and requires a new snapshot."
        case .revisionGap(let expected, let actual):
            return "Host state revision gap: expected \(expected), received \(actual)."
        case .schemaVersionMismatch(let expected, let actual):
            return "Host state schema mismatch: expected \(expected), received \(actual)."
        case .eventInboxFull:
            return "The host event inbox is full; the event was not accepted."
        case .stalePreparation:
            return "The prepared host context is stale and cannot be committed."
        case .preparationNotFound:
            return "The prepared host context no longer exists."
        }
    }
}

public enum HostContextFrameMode: String, Sendable, Codable {
    case snapshot
    case delta
    case event
}

/// An immutable host-context request prepared for one provider attempt.
public struct PreparedHostContext: Sendable, Codable, Equatable {
    public let preparationId: UUID
    public let runID: UUID
    public let mode: HostContextFrameMode
    public let cursor: StateCursor
    public let baselineGeneration: Int
    public let stateBoundaryGeneration: Int
    public let payload: HostContextPayload
    public let additionalPayloads: [HostContextPayload]
    public let eventIds: [String]

    public init(
        preparationId: UUID,
        runID: UUID,
        mode: HostContextFrameMode,
        cursor: StateCursor,
        baselineGeneration: Int = 0,
        stateBoundaryGeneration: Int = 0,
        payload: HostContextPayload,
        additionalPayloads: [HostContextPayload] = [],
        eventIds: [String] = []
    ) {
        self.preparationId = preparationId
        self.runID = runID
        self.mode = mode
        self.cursor = cursor
        self.baselineGeneration = baselineGeneration
        self.stateBoundaryGeneration = stateBoundaryGeneration
        self.payload = payload
        self.additionalPayloads = additionalPayloads
        self.eventIds = eventIds
    }

    public init(
        preparationId: UUID,
        runID: UUID,
        mode: HostContextFrameMode,
        cursor: StateCursor,
        baselineGeneration: Int = 0,
        stateBoundaryGeneration: Int = 0,
        payloads: [HostContextPayload],
        eventIds: [String] = []
    ) {
        precondition(!payloads.isEmpty)
        self.init(
            preparationId: preparationId,
            runID: runID,
            mode: mode,
            cursor: cursor,
            baselineGeneration: baselineGeneration,
            stateBoundaryGeneration: stateBoundaryGeneration,
            payload: payloads[0],
            additionalPayloads: Array(payloads.dropFirst()),
            eventIds: eventIds
        )
    }

    public var payloads: [HostContextPayload] {
        [payload] + additionalPayloads
    }

    public func message(turnID: Int? = nil) -> AIAgentMessage {
        AIAgentMessage.hostContext(
            payloads,
            turnID: turnID
        )
    }
}

/// Session-owned mirror of the host's latest structured state.
///
/// The mirror deliberately owns the model-seen cursor. A host may be shared by
/// several sessions, but each session has an independent view of what its model
/// has actually received.
public actor HostStateMirror {
    public static let maxPendingEventCount = 256

    private var latestSnapshot: HostStateSnapshot?
    private var deltaHistory: [HostStateDelta] = []
    private var modelSeenCursor: StateCursor?
    private var forceSnapshot = true
    private var activeRunID: UUID?
    private var pendingPreparations: [UUID: PreparedHostContext] = [:]
    private var eventInbox: [HostEvent] = []
    private var processedEventIds: [String] = []
    private var providerGeneration: UInt64 = 0
    private var providerInstallToken: UInt64 = 0
    private var providerUpdateTask: Task<Void, Never>?
    private var knownPageDefinitions: [String: HostPageDefinition] = [:]
    private var baselineGeneration = 0
    private var stateBoundaryGeneration = 0

    public init() {}

    public func currentSnapshot() -> HostStateSnapshot? {
        latestSnapshot
    }

    public func currentState() -> JSONValue? {
        latestSnapshot?.state
    }

    public func currentCursor() -> StateCursor? {
        latestSnapshot?.cursor
    }

    public func currentModelSeenCursor() -> StateCursor? {
        modelSeenCursor
    }

    public func pendingEvents() -> [HostEvent] {
        eventInbox
    }

    /// Install a provider and begin consuming its updates.
    ///
    /// The provider lifetime, initial snapshot, refreshes, and update stream
    /// are all serialized by this actor. A delayed older install can finish
    /// its provider await, but it cannot apply anything after a newer
    /// generation has taken over.
    @discardableResult
    public func installProvider(
        _ provider: any HostStateProvider
    ) async throws -> Bool {
        let candidateToken = beginProviderInstall()
        let snapshot: HostStateSnapshot
        do {
            snapshot = try await provider.snapshot()
        } catch {
            guard providerInstallToken == candidateToken else {
                return false
            }
            throw error
        }
        guard providerInstallToken == candidateToken else {
            return false
        }

        providerUpdateTask?.cancel()
        providerUpdateTask = nil
        providerGeneration &+= 1
        latestSnapshot = snapshot
        deltaHistory.removeAll()
        modelSeenCursor = nil
        forceSnapshot = true
        pendingPreparations.removeAll()
        eventInbox.removeAll()
        processedEventIds.removeAll()
        baselineGeneration &+= 1
        stateBoundaryGeneration &+= 1

        let generation = providerGeneration
        let updates = provider.updates()
        providerUpdateTask = Task { [weak self] in
            await self?.consumeProviderUpdates(
                updates,
                providerGeneration: generation,
                provider: provider
            )
        }
        return true
    }

    /// Move the provider lifetime forward without installing a replacement.
    @discardableResult
    public func removeProviderGeneration() -> UInt64 {
        advanceProviderGeneration()
    }

    /// Move the provider lifetime forward and return the new generation.
    @discardableResult
    public func activateProviderGeneration() -> UInt64 {
        advanceProviderGeneration()
    }

    private func advanceProviderGeneration() -> UInt64 {
        providerInstallToken &+= 1
        providerUpdateTask?.cancel()
        providerUpdateTask = nil
        providerGeneration &+= 1
        pendingPreparations.removeAll()
        eventInbox.removeAll()
        processedEventIds.removeAll()
        modelSeenCursor = nil
        forceSnapshot = true
        baselineGeneration &+= 1
        stateBoundaryGeneration &+= 1
        return providerGeneration
    }

    public func startRun(_ runID: UUID) {
        activeRunID = runID
        pendingPreparations.removeAll()
        modelSeenCursor = nil
        forceSnapshot = true
        baselineGeneration &+= 1
    }

    public func endRun(_ runID: UUID) {
        guard activeRunID == runID else {
            return
        }
        activeRunID = nil
        pendingPreparations = pendingPreparations.filter { _, preparation in
            preparation.runID != runID
        }
    }

    @discardableResult
    public func apply(_ update: HostStateUpdate) throws -> Bool {
        switch update {
        case .snapshot(let snapshot):
            try apply(snapshot)
            return true
        case .delta(let delta):
            try apply(delta)
            return true
        case .event(let event):
            try apply(event)
            return true
        }
    }

    @discardableResult
    public func apply(
        _ update: HostStateUpdate,
        providerGeneration generation: UInt64
    ) throws -> Bool {
        guard providerGeneration == generation else {
            return false
        }
        return try apply(update)
    }

    @discardableResult
    public func apply(
        _ snapshot: HostStateSnapshot,
        providerGeneration generation: UInt64
    ) throws -> Bool {
        try apply(
            .snapshot(snapshot),
            providerGeneration: generation
        )
    }

    public func apply(_ snapshot: HostStateSnapshot) throws {
        latestSnapshot = snapshot
        deltaHistory.removeAll()
        modelSeenCursor = nil
        forceSnapshot = true
        baselineGeneration &+= 1
        stateBoundaryGeneration &+= 1
        pendingPreparations.removeAll()
        // A snapshot is a recovery boundary for state history, not a provider
        // lifetime boundary. Event metadata remains pending until a provider
        // request commits it, and processed IDs remain deduplicated within the
        // same provider generation. Generation transitions clear both.
    }

    public func apply(_ delta: HostStateDelta) throws {
        guard let current = latestSnapshot else {
            forceSnapshot = true
            throw HostStateMirrorError.snapshotRequired
        }
        guard current.stateSchemaVersion == delta.stateSchemaVersion else {
            forceSnapshot = true
            throw HostStateMirrorError.schemaVersionMismatch(
                expected: current.stateSchemaVersion,
                actual: delta.stateSchemaVersion
            )
        }
        guard current.cursor.epoch == delta.cursor.epoch else {
            forceSnapshot = true
            throw HostStateMirrorError.epochChanged
        }

        let expectedRevision = current.cursor.revision + 1
        guard delta.cursor.revision == expectedRevision else {
            forceSnapshot = true
            throw HostStateMirrorError.revisionGap(
                expected: expectedRevision,
                actual: delta.cursor.revision
            )
        }

        let mergedState = Self.merge(current.state, with: delta.changes)
        latestSnapshot = HostStateSnapshot(
            stateSchemaVersion: current.stateSchemaVersion,
            cursor: delta.cursor,
            state: mergedState
        )
        deltaHistory.append(delta)
        if deltaHistory.count > 256 {
            deltaHistory.removeFirst(deltaHistory.count - 256)
        }
        forceSnapshot = false
    }

    public func apply(_ hostEvent: HostEvent) throws {
        guard !eventInbox.contains(where: { queuedEvent in
            queuedEvent.eventId == hostEvent.eventId
        }),
        !processedEventIds.contains(hostEvent.eventId) else {
            return
        }
        guard eventInbox.count < Self.maxPendingEventCount else {
            throw HostStateMirrorError.eventInboxFull
        }

        if let cursor = hostEvent.cursor {
            guard let current = latestSnapshot else {
                forceSnapshot = true
                eventInbox.append(hostEvent)
                return
            }
            guard let changes = hostEvent.changes else {
                if cursor.revision > current.cursor.revision
                    || cursor.epoch != current.cursor.epoch {
                    invalidateModelBaseline()
                }
                eventInbox.append(hostEvent)
                return
            }
            do {
                let delta = HostStateDelta(
                    stateSchemaVersion: current.stateSchemaVersion,
                    cursor: cursor,
                    changes: changes
                )
                try apply(delta)
            } catch {
                forceSnapshot = true
                eventInbox.append(hostEvent)
                throw error
            }
        } else if let current = latestSnapshot {
            if let changes = hostEvent.changes {
                latestSnapshot = HostStateSnapshot(
                    stateSchemaVersion: current.stateSchemaVersion,
                    cursor: current.cursor,
                    state: Self.merge(current.state, with: changes)
                )
            }
            // A cursorless event cannot be represented in delta history. The
            // next model request must therefore carry a fresh snapshot, even
            // when this event has no state changes.
        }

        if hostEvent.cursor == nil {
            invalidateModelBaseline()
        }
        eventInbox.append(hostEvent)
    }

    private func beginProviderInstall() -> UInt64 {
        providerInstallToken &+= 1
        return providerInstallToken
    }

    public func registerPageDefinition(_ definition: HostPageDefinition) {
        knownPageDefinitions[definition.pageId] = definition
    }

    public func knownPageDefinition(for pageId: String) -> HostPageDefinition? {
        knownPageDefinitions[pageId]
    }

    public func knownPageDefinitionsSnapshot() -> [String: HostPageDefinition] {
        knownPageDefinitions
    }

    /// Force a full snapshot on the next provider request.
    public func invalidateModelBaseline() {
        modelSeenCursor = nil
        forceSnapshot = true
        baselineGeneration &+= 1
    }

    @discardableResult
    public func invalidateModelBaseline(
        providerGeneration generation: UInt64
    ) -> Bool {
        guard providerGeneration == generation else {
            return false
        }
        invalidateModelBaseline()
        return true
    }

    /// Prepare an immutable context frame without changing the seen cursor.
    public func prepare(
        runID: UUID,
        forceSnapshot requestedSnapshot: Bool = false
    ) throws -> PreparedHostContext? {
        guard activeRunID == runID else {
            throw HostStateMirrorError.stalePreparation
        }
        guard let latestSnapshot else {
            return nil
        }

        let reservedEventIds = Set(
            pendingPreparations.values.flatMap(\.eventIds)
        )
        let pendingEvents = eventInbox.filter {
            !reservedEventIds.contains($0.eventId)
        }
        let hasCursorlessEvent = pendingEvents.contains { $0.cursor == nil }
        let shouldSendSnapshot = requestedSnapshot
            || forceSnapshot
            || modelSeenCursor == nil
            || modelSeenCursor?.epoch != latestSnapshot.cursor.epoch
            || hasCursorlessEvent

        var frameMode: HostContextFrameMode
        var payloads: [HostContextPayload] = []
        if shouldSendSnapshot {
            frameMode = .snapshot
            payloads.append(.snapshot(latestSnapshot))
        } else if let seen = modelSeenCursor,
                  seen.revision < latestSnapshot.cursor.revision {
            guard let changes = mergedChanges(
                after: seen,
                through: latestSnapshot.cursor
            ) else {
                frameMode = .snapshot
                payloads.append(.snapshot(latestSnapshot))
                let eventPayloads = pendingEvents.map(HostContextPayload.event)
                payloads.append(contentsOf: eventPayloads)
                let preparation = PreparedHostContext(
                    preparationId: UUID(),
                    runID: runID,
                    mode: frameMode,
                    cursor: latestSnapshot.cursor,
                    baselineGeneration: baselineGeneration,
                    stateBoundaryGeneration: stateBoundaryGeneration,
                    payloads: payloads,
                    eventIds: pendingEvents.map(\.eventId)
                )
                pendingPreparations[preparation.preparationId] = preparation
                return preparation
            }
            frameMode = .delta
            payloads.append(
                .delta(
                    HostStateDelta(
                        stateSchemaVersion: latestSnapshot.stateSchemaVersion,
                        cursor: latestSnapshot.cursor,
                        changes: changes
                    )
                )
            )
        } else {
            guard !pendingEvents.isEmpty else {
                return nil
            }
            frameMode = .event
        }

        let eventPayloads = pendingEvents.map(HostContextPayload.event)
        payloads.append(contentsOf: eventPayloads)
        let preparation = PreparedHostContext(
            preparationId: UUID(),
            runID: runID,
            mode: frameMode,
            cursor: latestSnapshot.cursor,
            baselineGeneration: baselineGeneration,
            stateBoundaryGeneration: stateBoundaryGeneration,
            payloads: payloads,
            eventIds: pendingEvents.map(\.eventId)
        )
        pendingPreparations[preparation.preparationId] = preparation
        return preparation
    }

    /// Commit only after the provider response has completed successfully.
    public func commit(_ preparation: PreparedHostContext) throws {
        guard let stored = pendingPreparations[preparation.preparationId] else {
            throw HostStateMirrorError.preparationNotFound
        }
        guard stored == preparation,
              activeRunID == preparation.runID,
              let latestSnapshot,
              latestSnapshot.cursor.epoch == preparation.cursor.epoch,
              latestSnapshot.cursor.revision >= preparation.cursor.revision,
              stateBoundaryGeneration == preparation.stateBoundaryGeneration else {
            throw HostStateMirrorError.stalePreparation
        }
        if let seen = modelSeenCursor {
            guard seen.epoch == preparation.cursor.epoch else {
                throw HostStateMirrorError.stalePreparation
            }
        }
        pendingPreparations.removeValue(forKey: preparation.preparationId)
        let eventIds = Set(preparation.eventIds)
        eventInbox.removeAll { eventIds.contains($0.eventId) }
        for eventId in eventIds where !processedEventIds.contains(eventId) {
            processedEventIds.append(eventId)
        }
        if processedEventIds.count > Self.maxPendingEventCount {
            processedEventIds.removeFirst(processedEventIds.count - Self.maxPendingEventCount)
        }
        if modelSeenCursor == nil
            || modelSeenCursor?.revision ?? 0 < preparation.cursor.revision {
            modelSeenCursor = preparation.cursor
        }
        forceSnapshot = baselineGeneration != preparation.baselineGeneration
    }

    public func discard(_ preparation: PreparedHostContext) {
        pendingPreparations.removeValue(forKey: preparation.preparationId)
    }

    private func mergedChanges(
        after cursor: StateCursor,
        through target: StateCursor
    ) -> JSONValue? {
        guard cursor.epoch == target.epoch else {
            return nil
        }
        let pending = deltaHistory.filter { delta in
            delta.cursor.epoch == cursor.epoch
                && delta.cursor.revision > cursor.revision
                && delta.cursor.revision <= target.revision
        }
        guard let first = pending.first,
              first.cursor.revision == cursor.revision + 1,
              pending.last?.cursor.revision == target.revision else {
            return nil
        }

        var merged: JSONValue = .object([:])
        var expected = cursor.revision + 1
        for delta in pending {
            guard delta.cursor.revision == expected else {
                return nil
            }
            merged = Self.merge(merged, with: delta.changes)
            expected += 1
        }
        return merged
    }

    private static func merge(
        _ base: JSONValue,
        with changes: JSONValue
    ) -> JSONValue {
        guard case .object(let changeObject) = changes else {
            return changes
        }
        guard case .object(let baseObject) = base else {
            return .object(changeObject)
        }

        var result = baseObject
        for (key, change) in changeObject {
            if let existing = result[key],
               case .object = existing,
               case .object = change {
                result[key] = merge(existing, with: change)
            } else {
                result[key] = change
            }
        }
        return .object(result)
    }

    private func consumeProviderUpdates(
        _ updates: AsyncStream<HostStateUpdate>,
        providerGeneration generation: UInt64,
        provider: any HostStateProvider
    ) async {
        for await update in updates {
            do {
                let accepted = try apply(
                    update,
                    providerGeneration: generation
                )
                guard accepted else {
                    return
                }
            } catch {
                Logger.warning(
                    "HostStateMirror",
                    "host state update gap; refreshing snapshot: \(error)"
                )
                do {
                    let refreshed = try await provider.snapshot()
                    let accepted = try apply(
                        refreshed,
                        providerGeneration: generation
                    )
                    guard accepted else {
                        return
                    }
                } catch {
                    let invalidated = invalidateModelBaseline(
                        providerGeneration: generation
                    )
                    guard invalidated else {
                        return
                    }
                    Logger.error(
                        "HostStateMirror",
                        "host state snapshot refresh failed: \(error)"
                    )
                }
            }
        }
    }
}
