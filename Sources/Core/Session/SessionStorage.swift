//
//  SessionStorage.swift
//  AppAgent
//

import Foundation

// MARK: - AISession Storage Protocol

/// Abstraction for session persistence.
public protocol SessionStorage: Sendable {
    func save(session: SessionSnapshot) async throws
    func load(id: String) async throws -> SessionSnapshot?
    func loadAll() async throws -> [SessionSnapshot]
    func delete(id: String) async throws
    /// Must commit a recoverable archive, never fall back to permanent deletion.
    func archive(session: SessionSnapshot) async throws
    func loadArchived() async throws -> [SessionSnapshot]
    func restoreArchived(id: String) async throws -> SessionSnapshot
    /// Trusted manual UI only.
    func purgeArchived(id: String) async throws
}

public extension SessionStorage {
    func archive(session: SessionSnapshot) async throws { throw SessionLifecycleError.unsupported }
    func loadArchived() async throws -> [SessionSnapshot] { throw SessionLifecycleError.unsupported }
    func restoreArchived(id: String) async throws -> SessionSnapshot { throw SessionLifecycleError.unsupported }
    func purgeArchived(id: String) async throws { throw SessionLifecycleError.unsupported }
}

/// A serializable snapshot of a session for persistence.
/// Uses AIAgentMessage directly (which is Codable) for full-fidelity round-trip persistence
/// including tool calls and tool results.
public struct SessionSnapshot: Sendable, Codable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messages: [AIAgentMessage]
    public let metadata: [String: String]?
    /// 每一轮的阶段与终局。后加的键，旧快照缺它就是空数组。
    public let turnRecords: [AIAgentTurnRecord]?
    /// Execution policy captured when the session was persisted.
    /// Optional for backward compatibility with snapshots written before policy persistence.
    public let executionPolicy: AIAgentExecutionPolicy?
    public let archivedAt: Date?
    public let ownerAgentID: String?

    public init(id: String, title: String, createdAt: Date, updatedAt: Date,
                messages: [AIAgentMessage], metadata: [String: String]? = nil,
                turnRecords: [AIAgentTurnRecord]? = nil,
                executionPolicy: AIAgentExecutionPolicy? = nil,
                archivedAt: Date? = nil, ownerAgentID: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.metadata = metadata
        self.turnRecords = turnRecords
        self.executionPolicy = executionPolicy
        self.archivedAt = archivedAt
        self.ownerAgentID = ownerAgentID
    }

    /// 手写解码只为一件事：**turnRecords 解不开不能拖垮整个快照**。
    ///
    /// `FileSessionStorage.loadAll` 对解码失败的文件是整份跳过的，所以「新加的键
    /// 格式变了」会变成「整段对话没了」。对话记录比阶段信息重要得多，这里 `try?` 吞掉。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.messages = try container.decode([AIAgentMessage].self, forKey: .messages)
        self.metadata = try? container.decodeIfPresent([String: String].self, forKey: .metadata)
        self.turnRecords = try? container.decodeIfPresent([AIAgentTurnRecord].self, forKey: .turnRecords)
        self.executionPolicy = try? container.decodeIfPresent(AIAgentExecutionPolicy.self, forKey: .executionPolicy)
        self.archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.ownerAgentID = try container.decodeIfPresent(String.self, forKey: .ownerAgentID)
    }

    func withArchivedAt(_ date: Date?) -> SessionSnapshot {
        SessionSnapshot(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                        messages: messages, metadata: metadata, turnRecords: turnRecords,
                        executionPolicy: executionPolicy,
                        archivedAt: date, ownerAgentID: ownerAgentID)
    }
}

// MARK: - In-Memory Storage (for testing)

/// Simple in-memory storage implementation.
public actor InMemorySessionStorage: SessionStorage {
    private var sessions: [String: SessionSnapshot] = [:]
    private var archived: [String: SessionSnapshot] = [:]
    private var purged: Set<String> = []

    public init() {}

    public func save(session: SessionSnapshot) throws {
        guard archived[session.id] == nil, !purged.contains(session.id) else {
            throw SessionLifecycleError.inactive(session.id)
        }
        sessions[session.id] = session.withArchivedAt(nil)
    }

    public func load(id: String) throws -> SessionSnapshot? {
        sessions[id]
    }

    public func loadAll() throws -> [SessionSnapshot] {
        Array(sessions.values)
    }

    public func delete(id: String) throws {
        guard let snapshot = sessions[id] else { throw SessionLifecycleError.notFound(id) }
        try archiveSnapshot(snapshot)
    }

    private func archiveSnapshot(_ session: SessionSnapshot) throws {
        guard archived[session.id] == nil, !purged.contains(session.id) else {
            throw SessionLifecycleError.inactive(session.id)
        }
        archived[session.id] = session.withArchivedAt(Date())
        sessions.removeValue(forKey: session.id)
    }

    public func archive(session: SessionSnapshot) async throws {
        try archiveSnapshot(session)
    }

    public func loadArchived() async throws -> [SessionSnapshot] { Array(archived.values) }

    public func restoreArchived(id: String) async throws -> SessionSnapshot {
        guard sessions[id] == nil else { throw SessionLifecycleError.conflict(id) }
        guard let snapshot = archived[id] else { throw SessionLifecycleError.notFound(id) }
        let restored = snapshot.withArchivedAt(nil)
        sessions[id] = restored
        archived.removeValue(forKey: id)
        return restored
    }

    public func purgeArchived(id: String) async throws {
        guard sessions[id] == nil else { throw SessionLifecycleError.conflict(id) }
        guard archived[id] != nil else { throw SessionLifecycleError.notFound(id) }
        purged.insert(id)
        archived.removeValue(forKey: id)
    }
}

// MARK: - File-Based Storage

/// File-based session storage using JSON files.
/// Degrades gracefully: corrupted files are skipped during loadAll.
public actor FileSessionStorage: SessionStorage {
    private let directory: URL
    // File operations are synchronous and short. Share a lock across instances, because two
    // storage actors may point at the same repository (including symlink aliases).
    // Recursive only for delete -> load/archive; no suspension occurs while this is held.
    private static let repositoryLock = NSRecursiveLock()

    private func transaction<T>(_ body: () throws -> T) rethrows -> T {
        Self.repositoryLock.lock()
        defer { Self.repositoryLock.unlock() }
        return try body()
    }

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.directory = docs.appendingPathComponent("AppAgent/sessions", isDirectory: true)
        }
        SessionRepositoryProtection.register(directory: self.directory)
        // Creation errors are reported by the first operation, not hidden by a throwing-free init.
    }

    public func save(session: SessionSnapshot) throws {
        try transaction {
            let url = try fileURL(session.id, in: directory)
            guard !exists(try fileURL(session.id, in: trash)),
                  !exists(try tombstone(session.id)) else {
                throw SessionLifecycleError.inactive(session.id)
            }
            try write(session.withArchivedAt(nil), to: url)
        }
    }

    private var trash: URL { directory.appendingPathComponent("trash", isDirectory: true) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func fileURL(_ id: String, in root: URL) throws -> URL {
        guard !id.isEmpty, id != ".", id != "..",
              !id.contains("/"), !id.contains("\\"), !id.contains("\0") else {
            throw SessionLifecycleError.invalid("Invalid session ID.")
        }
        return root.appendingPathComponent("\(id).json")
    }

    private func tombstone(_ id: String) throws -> URL {
        try fileURL(id, in: trash).appendingPathExtension("purged")
    }

    private func write(_ session: SessionSnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
    }

    public func load(id: String) throws -> SessionSnapshot? {
        try transaction {
            let url = try fileURL(id, in: directory)
            guard exists(url) else { return nil }
            return try read(url).withArchivedAt(nil)
        }
    }

    private func read(_ url: URL) throws -> SessionSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionSnapshot.self, from: data)
    }

    public func loadAll() throws -> [SessionSnapshot] {
        try transaction { try loadDirectory(directory).map { $0.withArchivedAt(nil) } }
    }

    private func loadDirectory(_ root: URL) throws -> [SessionSnapshot] {
        guard exists(root) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return files.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            do { return try read(url) }
            catch {
                Logger.warning("FileSessionStorage", "Cannot read \(url.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    public func delete(id: String) throws {
        try transaction {
            guard let snapshot = try load(id: id) else { throw SessionLifecycleError.notFound(id) }
            try archiveSnapshot(snapshot)
        }
    }

    private func archiveSnapshot(_ session: SessionSnapshot) throws {
        try transaction {
            let active = try fileURL(session.id, in: directory)
            let destination = try fileURL(session.id, in: trash)
            guard !exists(destination), !exists(try tombstone(session.id)) else {
                throw SessionLifecycleError.inactive(session.id)
            }
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            // Persist the latest complete snapshot first. The rename is the commit point.
            // If it fails the active file remains readable; directory location determines lifecycle.
            try write(session.withArchivedAt(Date()), to: active)
            try FileManager.default.moveItem(at: active, to: destination)
        }
    }

    public func archive(session: SessionSnapshot) async throws {
        try archiveSnapshot(session)
    }

    public func loadArchived() async throws -> [SessionSnapshot] {
        try transaction { try loadDirectory(trash) }
    }

    public func restoreArchived(id: String) async throws -> SessionSnapshot {
        try transaction {
            let active = try fileURL(id, in: directory)
            let source = try fileURL(id, in: trash)
            guard !exists(active) else { throw SessionLifecycleError.conflict(id) }
            guard exists(source), !exists(try tombstone(id)) else { throw SessionLifecycleError.notFound(id) }
            let snapshot = try read(source).withArchivedAt(nil)
            try FileManager.default.moveItem(at: source, to: active)
            return snapshot
        }
    }

    public func purgeArchived(id: String) async throws {
        try transaction {
            guard !exists(try fileURL(id, in: directory)) else { throw SessionLifecycleError.conflict(id) }
            let source = try fileURL(id, in: trash)
            guard exists(source) else { throw SessionLifecycleError.notFound(id) }
            // Rename to a non-session path commits the purge without a window in which save can revive it.
            let marker = try tombstone(id)
            try FileManager.default.moveItem(at: source, to: marker)
            // Keep a small permanent tombstone, not expired-trash cleanup.
            do { try Data().write(to: marker, options: .atomic) }
            catch {
                // Restore the archive when erasing the payload fails.
                try FileManager.default.moveItem(at: marker, to: source)
                throw error
            }
        }
    }
}
