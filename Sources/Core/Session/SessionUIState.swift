//
//  SessionUIState.swift
//  AppAgent
//

import Foundation

/// UI state intermediary layer that decouples AISession from the UI.
///
/// AISession internals and tools update this object's data.
/// The UI layer observes changes via the `onChange` callback.
///
/// Built-in state covers streaming lifecycle. The generic `customState`
/// dictionary allows HostApp-defined tools to store arbitrary UI-relevant
/// data without coupling to any specific UI framework.
///
/// Thread-safe: all mutable state is protected by a `ReadersWriterLock`.
/// The `onChange` callback is always dispatched to the main queue.
public final class SessionUIState: @unchecked Sendable {

    /// 自定义状态键：当前实际使用的模型引用（运行期回退后会更新）。
    public static let activeModelKey = "activeModelRef"

    /// `onChange` 在「等用户决定」状态变化时带的 key。
    public static let pendingDecisionKey = "pendingDecision"

    private let lock = ReadersWriterLock()

    // MARK: - Built-in State (backing)

    private var _isStreaming: Bool = false
    private var _streamingText: String = ""
    private var _reasoningText: String = ""
    private var _lastError: Error?
    /// 还在等用户拍板的请求**栈**。
    ///
    /// 不是单槽：safe 级工具并发跑，两个 `clarify` / 两次授权可以同时在等。单槽的话
    /// 先答完的那个会把「还有人在等」这个阻塞态直接清掉，宿主据此判断就错了。
    private var _pendingDecisions: [DecisionRequest] = []

    // MARK: - Custom State (backing)

    private var _customState: [String: Any] = [:]

    // MARK: - Observer (backing)

    private var _onChange: ((_ key: String) -> Void)?

    // MARK: - Public Read Access

    /// Whether the session is currently streaming a response.
    public var isStreaming: Bool { lock.read { _isStreaming } }

    /// The text being accumulated during the current streaming response.
    public var streamingText: String { lock.read { _streamingText } }

    /// 本轮累计的「思考过程」文本（推理模型才有；仅用于展示）。
    public var reasoningText: String { lock.read { _reasoningText } }

    /// The last error encountered, if any.
    public var lastError: Error? { lock.read { _lastError } }

    // MARK: - Pending Decision (awaiting user)

    /// 会话里的「等用户决定」状态：正在被问的那一个（入栈顺序里最早、还没被答复的）。
    ///
    /// 与 UI 一致：面板贴的也是队首那张卡。非 nil 时执行流正 await 用户拍板。
    public var pendingDecision: DecisionRequest? { lock.read { _pendingDecisions.first } }

    /// 当前有多少个请求在等用户拍板。
    public var pendingDecisionCount: Int { lock.read { _pendingDecisions.count } }

    /// UI layer sets this callback to respond to state changes.
    /// The key parameter indicates which state changed.
    ///
    /// Built-in keys: "isStreaming", "streamingText", "lastError"
    /// Custom keys: whatever the tools set via `set(_:value:)`
    public var onChange: ((_ key: String) -> Void)? {
        get { lock.read { _onChange } }
        set { lock.writeSync { _onChange = newValue } }
    }

    public init() {}

    // MARK: - Built-in State Updates (internal, called by AISession)

    func setStreaming(_ value: Bool) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _isStreaming = value
            return _onChange
        }
        dispatchCallback(callback, key: "isStreaming")
    }

    func appendStreamingText(_ delta: String) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _streamingText += delta
            return _onChange
        }
        dispatchCallback(callback, key: "streamingText")
    }

    func resetStreamingText() {
        lock.writeSync { _streamingText = "" }
    }

    func appendReasoningText(_ delta: String) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _reasoningText += delta
            return _onChange
        }
        dispatchCallback(callback, key: "reasoningText")
    }

    func resetReasoningText() {
        lock.writeSync { _reasoningText = "" }
    }

    func setError(_ error: Error?) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _lastError = error
            return _onChange
        }
        if error != nil {
            dispatchCallback(callback, key: "lastError")
        }
    }

    // MARK: - Pending Decision Updates (public — tools set these while awaiting the user)

    /// 进入「等用户决定」态。`AISession.requestDecision` 在问人之前调用。
    public func setPendingDecision(_ decision: DecisionRequest) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _pendingDecisions.append(decision)
            return _onChange
        }
        dispatchCallback(callback, key: Self.pendingDecisionKey)
    }

    /// 用户已决定（或工具放弃等待），退出阻塞态。
    ///
    /// 传上原来的 request，多个请求并发在等时才摘得准；**显式传了但没命中就什么都不做**
    /// （宁可漏摘也不能把别人还在等的那一条摘掉）。缺省（nil）时摘最后入栈的那个。
    public func clearPendingDecision(_ decision: DecisionRequest? = nil) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            guard !_pendingDecisions.isEmpty else { return nil }
            if let decision = decision {
                guard let index = _pendingDecisions.lastIndex(of: decision) else { return nil }
                _pendingDecisions.remove(at: index)
            } else {
                _pendingDecisions.removeLast()
            }
            return _onChange
        }
        dispatchCallback(callback, key: Self.pendingDecisionKey)
    }

    // MARK: - Custom State (public, tools can read/write)
    /// Set a custom state value.
    public func set<T>(_ key: String, value: T) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _customState[key] = value
            return _onChange
        }
        dispatchCallback(callback, key: key)
    }

    /// Get a custom state value.
    public func get<T>(_ key: String) -> T? {
        lock.read { _customState[key] as? T }
    }

    /// Remove a custom state value.
    public func remove(_ key: String) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _customState.removeValue(forKey: key)
            return _onChange
        }
        dispatchCallback(callback, key: key)
    }

    /// 往「字符串数组」型的自定义状态里原子地补一项（已存在则不动），返回补完之后的全量。
    ///
    /// 为什么要单独一个方法：`get` 出来 + 追加 + `set` 回去这三步之间不是临界区。
    /// safe 级工具是并发执行的，两次授权「本会话都允许」互相覆盖，其中一次就白点了
    /// （下一次同样的操作还会再问一遍）。授权名单只增不减，所以合并即可。
    @discardableResult
    public func appendUnique(_ value: String, forKey key: String) -> [String] {
        let (callback, merged) = lock.writeSync { () -> (((String) -> Void)?, [String]) in
            var list = _customState[key] as? [String] ?? []
            if !list.contains(value) { list.append(value) }
            _customState[key] = list
            return (_onChange, list)
        }
        dispatchCallback(callback, key: key)
        return merged
    }

    // MARK: - Private

    private func dispatchCallback(_ callback: ((String) -> Void)?, key: String) {
        guard let callback else { return }
        DispatchQueue.main.async { callback(key) }
    }
}
