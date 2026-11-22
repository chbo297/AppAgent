//
//  HostStateReporter.swift
//  AppAgent
//
//  每个会话一份，负责把宿主状态汇报给模型：每次请求模型前读一次宿主，和模型已经看到的字段逐个比对，
//  决定这一帧发全量、只发变化、只发事件还是不发；模型请求成功才算送达。
//

import Foundation

public enum HostStateReporterError: Error, Sendable, Equatable {
    case eventInboxFull
    case stalePreparation
    case preparationNotFound
    case stateReadTimedOut(seconds: TimeInterval)
}

extension HostStateReporterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .eventInboxFull:
            return "The host event inbox is full; the event was not accepted."
        case .stalePreparation:
            return "The prepared host context is stale and cannot be committed."
        case .preparationNotFound:
            return "The prepared host context no longer exists."
        case .stateReadTimedOut(let seconds):
            return String(format: "The host did not return its current state within %.1fs.", seconds)
        }
    }
}

public enum HostContextFrameMode: String, Sendable, Codable {
    /// 完整状态：模型还没见过，或者需要重发。
    case state
    /// 只发变了的字段。
    case change
    /// 状态没变，只有事件。
    case event
}

/// 为一次模型请求准备好的宿主上下文。请求成功后 `commit`，失败就 `discard`。
public struct PreparedHostContext: Sendable, Codable, Equatable {
    public let preparationId: UUID
    public let runID: UUID
    public let mode: HostContextFrameMode
    public let payloads: [HostContextPayload]
    public let eventIds: [String]
    /// 提交后模型看到的完整字段。
    public let modelFields: [String: String]
    let baselineGeneration: Int
    let providerGeneration: UInt64

    public func message(turnID: Int? = nil) -> AIAgentMessage {
        AIAgentMessage.hostContext(payloads, turnID: turnID)
    }
}
/// 会话自己的宿主状态汇报器。
///
/// 「模型已经看到了什么」只有会话自己知道：同一个宿主可以装在多个会话上，各自的进度独立。
public actor HostStateReporter {
    public static let maxPendingEventCount = 256
    /// 单个字段默认最多这么多字符，超出截断并注明，免得大段内容每轮都发给模型。
    public static let defaultFieldCharacterLimit = 4096

    private var currentProvider: (any HostStateProvider)?
    private var providerGeneration: UInt64 = 0
    private var latestFields: [String: String]?
    private var latestDescriptions: [String: String] = [:]
    /// 模型已经确认收到的字段；nil = 下一帧发完整状态。
    private var modelSeenFields: [String: String]?
    private var baselineGeneration = 0
    private var activeRunID: UUID?
    private var pendingPreparations: [UUID: PreparedHostContext] = [:]
    private var eventInbox: [HostEvent] = []
    private var processedEventIds: [String] = []

    private weak var eventStore: HostStateStore?
    private var eventSinkToken: UUID?
    private let eventStream: AsyncStream<HostEvent>
    private let eventContinuation: AsyncStream<HostEvent>.Continuation
    private var eventConsumer: Task<Void, Never>?

    /// 每次读宿主最多等这么久，超时沿用上一份。`<= 0` 不设超时。
    public private(set) var stateReadTimeout: TimeInterval = 3
    public private(set) var fieldCharacterLimit = HostStateReporter.defaultFieldCharacterLimit

    public init() {
        (eventStream, eventContinuation) = AsyncStream<HostEvent>.makePair()
    }

    deinit {
        eventConsumer?.cancel()
        eventContinuation.finish()
        if let eventSinkToken {
            eventStore?.removeEventSink(eventSinkToken)
        }
    }

    public func setStateReadTimeout(_ seconds: TimeInterval) {
        stateReadTimeout = seconds
    }

    public func setFieldCharacterLimit(_ limit: Int) {
        fieldCharacterLimit = max(1, limit)
    }

    public func currentFields() -> [String: String]? {
        latestFields
    }

    public func currentModelSeenFields() -> [String: String]? {
        modelSeenFields
    }

    public func pendingEvents() -> [HostEvent] {
        eventInbox
    }
    // MARK: - Provider

    /// 装上宿主状态来源并读一次。读失败时来源照样装上（之后每次请求前会再读），错误抛给调用方。
    /// 返回 false = 读取期间又换了来源，这次的结果作废。
    @discardableResult
    public func installProvider(_ provider: any HostStateProvider) async throws -> Bool {
        resetProvider()
        currentProvider = provider
        if let store = provider as? HostStateStore {
            let continuation = eventContinuation
            eventSinkToken = store.addEventSink { event in
                continuation.yield(event)
            }
            eventStore = store
            startEventConsumerIfNeeded()
        }
        let generation = providerGeneration
        let read = try await readState(from: provider)
        guard providerGeneration == generation else {
            return false
        }
        apply(read)
        return true
    }

    public func removeProvider() {
        resetProvider()
    }

    /// 事件按到达顺序进收件箱；消费者只弱引用 reporter，不会让它活得比会话久。
    private func startEventConsumerIfNeeded() {
        guard eventConsumer == nil else {
            return
        }
        let events = eventStream
        eventConsumer = Task { [weak self] in
            for await event in events {
                guard let self else {
                    return
                }
                await self.post(event)
            }
        }
    }

    private func resetProvider() {
        if let eventSinkToken {
            eventStore?.removeEventSink(eventSinkToken)
        }
        eventSinkToken = nil
        eventStore = nil
        currentProvider = nil
        providerGeneration &+= 1
        latestFields = nil
        latestDescriptions = [:]
        pendingPreparations.removeAll()
        eventInbox.removeAll()
        processedEventIds.removeAll()
        invalidateModelBaseline()
    }

    /// 现读一次宿主状态，不影响模型进度。给 `app_state` 工具用；没装来源返回 nil。
    public func readCurrentState() async -> [String: String]? {
        guard currentProvider != nil else {
            return nil
        }
        await refresh()
        return latestFields
    }

    // MARK: - Run

    /// 每一轮开始：这一轮的消息历史里没有宿主上下文，第一帧必须发完整状态。
    public func startRun(_ runID: UUID) {
        activeRunID = runID
        pendingPreparations.removeAll()
        invalidateModelBaseline()
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

    /// 下一帧发完整状态（上下文被压缩、宿主上下文提交失败之后）。
    public func invalidateModelBaseline() {
        modelSeenFields = nil
        baselineGeneration &+= 1
    }

    /// 收一个宿主事件。`HostStateStore.postEvent` 会自动走到这里；自己实现来源的宿主也可以直接调。
    public func post(_ event: HostEvent) {
        guard !eventInbox.contains(where: { queued in
            queued.eventId == event.eventId
        }), !processedEventIds.contains(event.eventId) else {
            return
        }
        if eventInbox.count >= Self.maxPendingEventCount {
            Logger.warning("HostStateReporter", "host event inbox full; dropping oldest event")
            eventInbox.removeFirst()
        }
        eventInbox.append(event)
    }
    // MARK: - Frames

    /// 读一次宿主，准备这次模型请求要带的宿主上下文；没有可发的返回 nil。不改变模型进度。
    public func prepare(
        runID: UUID,
        forceFullState: Bool = false
    ) async throws -> PreparedHostContext? {
        guard activeRunID == runID else {
            throw HostStateReporterError.stalePreparation
        }
        await refresh()
        guard activeRunID == runID else {
            throw HostStateReporterError.stalePreparation
        }

        let reservedEventIds = Set(pendingPreparations.values.flatMap(\.eventIds))
        let events = eventInbox.filter { event in
            !reservedEventIds.contains(event.eventId)
        }
        var payloads: [HostContextPayload] = []
        var mode = HostContextFrameMode.event
        var modelFields = modelSeenFields
        if let fields = latestFields {
            if let seen = modelSeenFields, !forceFullState {
                let change = Self.change(from: seen, to: fields)
                if !change.isEmpty {
                    payloads.append(.change(change))
                    mode = .change
                }
            } else if !fields.isEmpty {
                payloads.append(.state(HostState(fields: fields, descriptions: latestDescriptions)))
                mode = .state
            }
            modelFields = fields
        }
        payloads += events.map(HostContextPayload.event)
        guard !payloads.isEmpty else {
            return nil
        }

        let preparation = PreparedHostContext(
            preparationId: UUID(),
            runID: runID,
            mode: mode,
            payloads: payloads,
            eventIds: events.map(\.eventId),
            modelFields: modelFields ?? [:],
            baselineGeneration: baselineGeneration,
            providerGeneration: providerGeneration
        )
        pendingPreparations[preparation.preparationId] = preparation
        return preparation
    }

    /// 模型请求成功后调用：这一帧算模型看到了。
    public func commit(_ preparation: PreparedHostContext) throws {
        guard let stored = pendingPreparations.removeValue(forKey: preparation.preparationId) else {
            throw HostStateReporterError.preparationNotFound
        }
        guard stored == preparation,
              activeRunID == preparation.runID,
              providerGeneration == preparation.providerGeneration else {
            throw HostStateReporterError.stalePreparation
        }
        let eventIds = Set(preparation.eventIds)
        eventInbox.removeAll { event in
            eventIds.contains(event.eventId)
        }
        for eventId in eventIds where !processedEventIds.contains(eventId) {
            processedEventIds.append(eventId)
        }
        if processedEventIds.count > Self.maxPendingEventCount {
            processedEventIds.removeFirst(processedEventIds.count - Self.maxPendingEventCount)
        }
        // 准备之后被要求重发全量（比如上下文压缩）：事件算发出去了，状态下一帧仍发全量。
        if baselineGeneration == preparation.baselineGeneration {
            modelSeenFields = preparation.modelFields
        }
    }

    public func discard(_ preparation: PreparedHostContext) {
        pendingPreparations.removeValue(forKey: preparation.preparationId)
    }

    static func change(from seen: [String: String], to fields: [String: String]) -> HostStateChange {
        let changed = fields.filter { key, value in
            seen[key] != value
        }
        let removed = seen.keys.filter { key in
            fields[key] == nil
        }
        return HostStateChange(changed: changed, removed: removed.sorted())
    }
    // MARK: - Reading

    private func refresh() async {
        guard let provider = currentProvider else {
            return
        }
        let generation = providerGeneration
        do {
            let read = try await readState(from: provider)
            guard providerGeneration == generation else {
                return
            }
            apply(read)
        } catch {
            Logger.warning("HostStateReporter", "host state read failed; keeping previous state: \(error)")
            if case HostStateReporterError.stateReadTimedOut = error {
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: "宿主状态读取超时（\(stateReadTimeout)s），本次沿用上一份状态",
                    reason: "host_state_timeout"
                )
            }
        }
    }

    private func apply(_ read: HostStateRead) {
        let limit = fieldCharacterLimit
        latestFields = read.fields.mapValues { value in
            Self.truncated(value, limit: limit)
        }
        latestDescriptions = read.descriptions
    }

    static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(limit)) + "…（已截断，原文 \(value.count) 字）"
    }

    /// 读宿主状态，带超时。
    ///
    /// 不能用 task group 做超时：group 退出前要等所有子任务结束，宿主的读取若不响应取消
    /// （比如卡在等主线程），group 就跟着一起挂住。这里谁先到用谁，超时后那次读取留在后台自己结束，结果丢弃。
    private func readState(from provider: any HostStateProvider) async throws -> HostStateRead {
        let seconds = stateReadTimeout
        guard seconds > 0 else {
            return try await HostStateRead.load(from: provider)
        }
        let started = Date()
        let gate = HostStateReadRace()
        let read: HostStateRead = try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            let task = Task {
                do {
                    gate.finish(.success(try await HostStateRead.load(from: provider)))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.finish(.failure(HostStateReporterError.stateReadTimedOut(seconds: seconds))) {
                    task.cancel()
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0.5 {
            // 读的是已存好的状态，本该是毫秒级；慢了留个记录，好回头查宿主的实现。
            Logger.warning("HostStateReporter", String(format: "host state read took %.2fs", elapsed))
        }
        return read
    }
}

private struct HostStateRead: Sendable {
    let fields: [String: String]
    let descriptions: [String: String]

    static func load(from provider: any HostStateProvider) async throws -> HostStateRead {
        HostStateRead(
            fields: try await provider.currentState(),
            descriptions: await provider.fieldDescriptions()
        )
    }
}

/// `readState` 的赛跑：读取结果和超时谁先到，continuation 只恢复一次。
private final class HostStateReadRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostStateRead, Error>?

    func install(_ continuation: CheckedContinuation<HostStateRead, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// 返回 true = 这次调用赢了（恢复了 continuation）。
    @discardableResult
    func finish(_ result: Result<HostStateRead, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else {
            return false
        }
        pending.resume(with: result)
        return true
    }
}