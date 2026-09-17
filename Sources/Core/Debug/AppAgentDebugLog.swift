//
//  AppAgentDebugLog.swift
//  AppAgent
//
//  模型接口调用的调试记录：每次请求、失败、重试、模型回退、成功都记一条，
//  供「调试窗口」实时展示与导出。进程内环形缓冲，不落盘（导出时由 UI 决定去向）。
//

import Foundation

/// 一条调试记录。
public struct AppAgentDebugEvent: Sendable, Codable, Equatable {

    public enum Kind: String, Sendable, Codable {
        /// 发起一次模型流式请求。
        case request
        /// 请求成功（含首个 token 到达后的完整消费）。
        case success
        /// 请求失败（附分类原因）。
        case failure
        /// 失败后按退避策略重试。
        case retry
        /// 当前模型不可用，切换到下一个可用模型。
        case fallback
        /// 其他信息（探查、配置变更等）。
        case info
    }

    public var id: String
    public var timestamp: Date
    public var kind: Kind
    public var sessionId: String?
    /// Provider 注册名或实现名。
    public var provider: String?
    /// 线协议（openai-completions / anthropic-messages）。
    public var apiProtocol: String?
    public var modelId: String?
    /// 执行循环的迭代序号。
    public var iteration: Int?
    /// 第几次重试（retry 事件）。
    public var attempt: Int?
    /// 失败分类（ErrorClassifier.FailoverReason）。
    public var reason: String?
    public var statusCode: Int?
    public var message: String
    public var durationMs: Int?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        kind: Kind,
        message: String,
        sessionId: String? = nil,
        provider: String? = nil,
        apiProtocol: String? = nil,
        modelId: String? = nil,
        iteration: Int? = nil,
        attempt: Int? = nil,
        reason: String? = nil,
        statusCode: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.sessionId = sessionId
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.modelId = modelId
        self.iteration = iteration
        self.attempt = attempt
        self.reason = reason
        self.statusCode = statusCode
        self.durationMs = durationMs
    }

    /// 单行文本形式（调试窗口列表与导出共用）。
    public var line: String {
        let time = AppAgentDebugEvent.timeFormatter.string(from: timestamp)
        var parts: [String] = ["[\(time)]", kind.rawValue.uppercased()]
        if let modelId = modelId {
            parts.append(apiProtocol.map { "\(modelId)@\($0)" } ?? modelId)
        }
        if let iteration = iteration { parts.append("iter=\(iteration)") }
        if let attempt = attempt { parts.append("attempt=\(attempt)") }
        if let reason = reason { parts.append("reason=\(reason)") }
        if let statusCode = statusCode { parts.append("http=\(statusCode)") }
        if let durationMs = durationMs { parts.append("\(durationMs)ms") }
        parts.append("- \(message)")
        return parts.joined(separator: " ")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

}

/// 全局调试记录器（环形缓冲 + 实时订阅 + 导出）。
///
/// 用法：`AppAgentDebugLog.shared.record(...)` 写入；UI 侧设置 `onEvent` 实时刷新，
/// 用 `snapshot()` 取全量、`exportText()` / `exportJSON()` 导出。
public final class AppAgentDebugLog: @unchecked Sendable {

    public static let shared = AppAgentDebugLog()

    private let lock = ReadersWriterLock()
    private var _events: [AppAgentDebugEvent] = []
    private var _capacity: Int
    private var _isEnabled: Bool = true
    private var _onEvent: ((AppAgentDebugEvent) -> Void)?

    public init(capacity: Int = 500) {
        self._capacity = max(1, capacity)
    }

    /// 是否记录。关闭后 record 直接丢弃（已有记录保留）。
    public var isEnabled: Bool {
        get { lock.read { _isEnabled } }
        set { lock.writeSync { _isEnabled = newValue } }
    }

    /// 环形缓冲上限，超出后丢弃最旧记录。
    public var capacity: Int {
        get { lock.read { _capacity } }
        set {
            lock.writeSync {
                _capacity = max(1, newValue)
                if _events.count > _capacity {
                    _events.removeFirst(_events.count - _capacity)
                }
            }
        }
    }

    /// 新记录回调（可能在任意线程触发，UI 侧需自行切主线程）。
    public var onEvent: ((AppAgentDebugEvent) -> Void)? {
        get { lock.read { _onEvent } }
        set { lock.writeSync { _onEvent = newValue } }
    }

    public func record(_ event: AppAgentDebugEvent) {
        let observer: ((AppAgentDebugEvent) -> Void)? = lock.writeSync {
            guard _isEnabled else { return nil }
            _events.append(event)
            if _events.count > _capacity {
                _events.removeFirst(_events.count - _capacity)
            }
            return _onEvent
        }
        observer?(event)
    }

    public func record(
        _ kind: AppAgentDebugEvent.Kind,
        message: String,
        sessionId: String? = nil,
        provider: String? = nil,
        apiProtocol: String? = nil,
        modelId: String? = nil,
        iteration: Int? = nil,
        attempt: Int? = nil,
        reason: String? = nil,
        statusCode: Int? = nil,
        durationMs: Int? = nil
    ) {
        record(AppAgentDebugEvent(
            kind: kind,
            message: message,
            sessionId: sessionId,
            provider: provider,
            apiProtocol: apiProtocol,
            modelId: modelId,
            iteration: iteration,
            attempt: attempt,
            reason: reason,
            statusCode: statusCode,
            durationMs: durationMs
        ))
    }

    /// 当前全部记录（按时间升序）。
    public func snapshot() -> [AppAgentDebugEvent] { lock.read { _events } }

    /// 只取失败 / 重试 / 回退这类异常记录。
    public func failures() -> [AppAgentDebugEvent] {
        lock.read { _events.filter { $0.kind == .failure || $0.kind == .retry || $0.kind == .fallback } }
    }

    public func clear() {
        lock.writeSync { _events.removeAll() }
    }

    /// 纯文本导出（每行一条）。
    public func exportText() -> String {
        snapshot().map { $0.line }.joined(separator: "\n")
    }

    /// JSON 导出（便于贴到 issue 或喂给工具分析）。
    public func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot()),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

