import XCTest
@testable import AppAgent

final class SessionLifecycleTests: XCTestCase {
    private func agent(_ storage: any SessionStorage, id: String = "lifecycle") -> AIAgent {
        AIAgent(id: id, profile: .init(autoPersist: false, registerBuiltInTools: false),
                toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
                memoryStorage: InMemoryMemoryStorage(), sessionStorage: storage)
    }

    private func rejects(_ operation: () async throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected lifecycle rejection", file: file, line: line)
        } catch {}
    }

    func testFileArchiveSurvivesRestartAndPurgeCannotRevive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = agent(FileSessionStorage(directory: root))
        let source = await first.createSession(title: "Keep forever")
        source.addUserMessage("complete history")
        let snapshot = source.toSnapshot()
        try await first.deleteSession(source.id)
        XCTAssertNil(first.session(id: source.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("trash/\(source.id).json").path))

        let storage = FileSessionStorage(directory: root)
        let restarted = agent(storage)
        try await restarted.restoreAll()
        XCTAssertTrue(restarted.allSessions.isEmpty)
        let archives = try await restarted.sessionManager.archivedSessions()
        XCTAssertEqual(archives.map(\.id), [source.id])
        XCTAssertNotNil(archives.first?.archivedAt)
        let restored = try await restarted.sessionManager.restoreArchivedSession(source.id)
        XCTAssertEqual(restored.messages.map(\.text), ["complete history"])
        XCTAssertNil(restored.toSnapshot().archivedAt)
        XCTAssertFalse(restored === source)
        await rejects { try await restarted.sessionManager.purgeArchivedSession(source.id) }
        await rejects { try await first.sessionManager.saveSession(source) }
        try await restarted.sessionManager.archiveSession(source.id)
        try await restarted.sessionManager.purgeArchivedSession(source.id)
        await rejects { try await restarted.sessionManager.saveSession(restored) }
        await rejects { try await storage.save(session: snapshot) }
        let anotherStorage = FileSessionStorage(directory: root)
        await rejects { try await anotherStorage.save(session: snapshot) }
        try await restarted.sessionManager.saveAll()
        let active = try await anotherStorage.loadAll()
        let trash = try await anotherStorage.loadArchived()
        XCTAssertTrue(active.isEmpty)
        XCTAssertTrue(trash.isEmpty)
        let marker = root.appendingPathComponent("trash/\(source.id).json.purged")
        XCTAssertEqual(try Data(contentsOf: marker).count, 0)
    }

    func testInMemoryArchiveRestoreRejectsOldInstanceSave() async throws {
        let storage = InMemorySessionStorage()
        let owner = agent(storage)
        let old = await owner.createSession(title: "Old")
        old.addUserMessage("retained")
        try await owner.sessionManager.archiveSession(old.id)
        await rejects { try await owner.sessionManager.saveSession(old) }
        let restored = try await owner.sessionManager.restoreArchivedSession(old.id)
        old.addUserMessage("late executor write")
        await rejects { try await owner.sessionManager.saveSession(old) }
        try await owner.sessionManager.saveAll()
        let loaded = try await storage.load(id: old.id)
        XCTAssertEqual(loaded?.messages.map(\.text), ["retained"])
        XCTAssertEqual(restored.messages.map(\.text), ["retained"])
    }

    func testFileStorageInstancesSerializeConcurrentSaveArchiveAndPurge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = FileSessionStorage(directory: root)
        let b = FileSessionStorage(directory: root)
        for index in 0..<12 {
            let now = Date()
            let snapshot = SessionSnapshot(id: "race-\(index)", title: "Keep", createdAt: now, updatedAt: now,
                                           messages: [.user(String(repeating: "history", count: 2_000))])
            try await a.save(session: snapshot)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await a.archive(session: snapshot) }
                for _ in 0..<8 {
                    group.addTask {
                        do { try await b.save(session: snapshot) }
                        catch SessionLifecycleError.inactive { /* archive won the race */ }
                    }
                }
                try await group.waitForAll()
            }
            let activeAfterArchive = try await b.load(id: snapshot.id)
            XCTAssertNil(activeAfterArchive)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await a.purgeArchived(id: snapshot.id) }
                group.addTask {
                    do {
                        try await b.save(session: snapshot)
                        XCTFail("Archived/purged identity was revived")
                    } catch SessionLifecycleError.inactive {}
                }
                try await group.waitForAll()
            }
            let activeAfterPurge = try await b.load(id: snapshot.id)
            XCTAssertNil(activeAfterPurge)
        }
        let archives = try await b.loadArchived()
        XCTAssertTrue(archives.isEmpty)
    }

    func testSharedRepositoryIsScopedToOwnerIncludingArchives() async throws {
        let storage = InMemorySessionStorage()
        let a = agent(storage, id: "a")
        let b = agent(storage, id: "a_b")
        let sa = await a.createSession(title: "A")
        let sb = await b.createSession(title: "B")
        try await a.sessionManager.saveAll()
        try await b.sessionManager.saveAll()
        let nextA = agent(storage, id: "a")
        try await nextA.restoreAll()
        XCTAssertEqual(nextA.allSessions.map(\.id), [sa.id])
        XCTAssertNil(nextA.session(id: sb.id))
        await rejects { try await nextA.sessionManager.archiveSession(sb.id) }
        try await b.sessionManager.archiveSession(sb.id)
        let archives = try await nextA.sessionManager.archivedSessions()
        XCTAssertTrue(archives.isEmpty)
        await rejects { _ = try await nextA.sessionManager.restoreArchivedSession(sb.id) }
        await rejects { try await nextA.sessionManager.purgeArchivedSession(sb.id) }
        let current = try XCTUnwrap(nextA.session(id: sa.id))
        for op in ["read", "rename", "set_model", "archive", "restore"] {
            let output = try await SessionManageTool().execute(
                arguments: ["op": .string(op), "session_id": .string(sb.id),
                            "title": .string("stolen"), "model": .string("none/model")], session: current)
            guard case .error = output else { return XCTFail("Cross-owner \(op) accepted") }
        }
    }

    func testUnsupportedStorageDoesNotCallLegacyDelete() async throws {
        let storage = LegacyOnlySessionStorage()
        let owner = agent(storage)
        let session = await owner.createSession(title: "Keep")
        try await owner.sessionManager.saveSession(session)
        await rejects { try await owner.deleteSession(session.id) }
        XCTAssertTrue(owner.session(id: session.id) === session)
        let deletes = await storage.deleteCount
        XCTAssertEqual(deletes, 0)
        let loaded = await storage.load(id: session.id)
        XCTAssertNotNil(loaded)
    }

    func testFailuresDoNotPublishLifecycleOrCreateRenameSuccess() async throws {
        let storage = ControlledSessionStorage()
        let owner = agent(storage)
        let source = await owner.createSession(title: "Source")
        let caller = await owner.createSession(title: "Caller")
        source.addUserMessage("keep")
        await storage.fail("archive")
        await rejects { try await owner.sessionManager.archiveSession(source.id) }
        XCTAssertTrue(owner.session(id: source.id) === source)
        // Failed archive releases admission, so a subsequent attempt can succeed.
        await storage.fail(nil)
        try await owner.sessionManager.archiveSession(source.id)
        await storage.fail("restore")
        await rejects { _ = try await owner.sessionManager.restoreArchivedSession(source.id) }
        XCTAssertNil(owner.session(id: source.id))
        let archives = try await owner.sessionManager.archivedSessions()
        XCTAssertEqual(archives.count, 1)
        await storage.fail(nil)
        let restored = try await owner.sessionManager.restoreArchivedSession(source.id)
        await storage.fail("save")
        for op in ["create", "rename"] {
            let result = try await SessionManageTool().execute(
                arguments: ["op": .string(op), "session_id": .string(restored.id),
                            "title": .string("changed")], session: caller)
            guard case .error = result else { return XCTFail("Storage error hidden by \(op)") }
        }
        XCTAssertEqual(restored.title, "Source")
        XCTAssertEqual(owner.allSessions.count, 2)
    }

    func testSaveAllAndArchiveSerializeAcrossReentrantStorageAwait() async throws {
        let storage = ControlledSessionStorage()
        let owner = agent(storage)
        let source = await owner.createSession(title: "Source")
        source.addUserMessage("keep")
        await storage.hold("save")
        let save = Task { try await owner.sessionManager.saveAll() }
        await storage.entered.wait()
        let archive = Task { try await owner.sessionManager.archiveSession(source.id) }
        // Reentrant storage is intentionally vulnerable: a wrongly concurrent archive would be
        // undone when the held save resumes. The manager, not the fake storage, must serialize.
        await storage.release.signal()
        try await save.value
        try await archive.value
        let loaded = await storage.load(id: source.id)
        XCTAssertNil(loaded)
        let archives = try await storage.loadArchived()
        XCTAssertEqual(archives.count, 1)
    }

    func testArchivePublishesAfterCommitAndBlocksQueuedLateSavesAndRuns() async throws {
        let storage = ControlledSessionStorage()
        let owner = agent(storage)
        let source = await owner.createSession(title: "Source")
        await storage.hold("archive")
        let archive = Task { try await owner.sessionManager.archiveSession(source.id) }
        await storage.entered.wait()
        XCTAssertTrue(owner.session(id: source.id) === source, "Memory removal must wait for storage success")
        var errors = 0
        for await event in source.sendMessage("must not start") {
            if case .error = event { errors += 1 }
        }
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(source.messages.isEmpty)
        let late = Task { try await owner.sessionManager.saveSession(source) }
        let all = Task { try await owner.sessionManager.saveAll() }
        await storage.release.signal()
        try await archive.value
        await rejects { try await late.value }
        try await all.value
        let loaded = await storage.load(id: source.id)
        XCTAssertNil(loaded)
    }

    func testUnfinishedTurnRefusesArchiveAndMergeWithoutChangingSources() async throws {
        let owner = agent(InMemorySessionStorage())
        let a = await owner.createSession(title: "A")
        let b = await owner.createSession(title: "B")
        let turn = a.addUserMessage("unfinished")
        a.openTurnRecord(turnID: turn, modelRef: nil)
        await rejects { try await owner.sessionManager.archiveSession(a.id) }
        await rejects { _ = try await owner.sessionManager.mergeSessions([b.id, a.id]) }
        XCTAssertEqual(owner.allSessions.count, 2)
        // Any source already suspended before failure must be released.
        try b.lifecycle.suspend(b)
        b.lifecycle.resume()
    }
}

private actor LegacyOnlySessionStorage: SessionStorage, AppAgentRuntimeOwned {
    private var snapshots: [String: SessionSnapshot] = [:]
    private(set) var deleteCount = 0
    func save(session: SessionSnapshot) { snapshots[session.id] = session }
    func load(id: String) -> SessionSnapshot? { snapshots[id] }
    func loadAll() -> [SessionSnapshot] { Array(snapshots.values) }
    func delete(id: String) { deleteCount += 1; snapshots.removeValue(forKey: id) }
}

/// Deliberately reentrant and lacking stale-save protection, like a custom async storage.
private actor ControlledSessionStorage: SessionStorage, AppAgentRuntimeOwned {
    let entered = ReadySignal()
    let release = ReadySignal()
    private var blockedOperation: String?
    private var failingOperation: String?
    private var active: [String: SessionSnapshot] = [:]
    private var archives: [String: SessionSnapshot] = [:]

    func hold(_ operation: String) { blockedOperation = operation }
    func fail(_ operation: String?) { failingOperation = operation }
    private func checkpoint(_ operation: String) async throws {
        if blockedOperation == operation {
            blockedOperation = nil
            await entered.signal()
            await release.wait()
        }
        if failingOperation == operation { throw SessionLifecycleError.invalid("Injected \(operation) failure") }
    }
    func save(session: SessionSnapshot) async throws {
        try await checkpoint("save")
        active[session.id] = session
    }
    func load(id: String) -> SessionSnapshot? { active[id] }
    func loadAll() -> [SessionSnapshot] { Array(active.values) }
    func delete(id: String) throws { throw SessionLifecycleError.unsupported }
    func archive(session: SessionSnapshot) async throws {
        try await checkpoint("archive")
        archives[session.id] = session.withArchivedAt(Date())
        active.removeValue(forKey: session.id)
    }
    func loadArchived() async throws -> [SessionSnapshot] { Array(archives.values) }
    func restoreArchived(id: String) async throws -> SessionSnapshot {
        try await checkpoint("restore")
        guard let snapshot = archives.removeValue(forKey: id) else { throw SessionLifecycleError.notFound(id) }
        active[id] = snapshot.withArchivedAt(nil)
        return snapshot.withArchivedAt(nil)
    }
    func purgeArchived(id: String) async throws {
        try await checkpoint("purge")
        archives.removeValue(forKey: id)
    }
}
