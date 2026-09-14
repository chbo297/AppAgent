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

    private let lock = ReadersWriterLock()

    // MARK: - Built-in State (backing)

    private var _isStreaming: Bool = false
    private var _streamingText: String = ""
    private var _lastError: Error?

    // MARK: - Custom State (backing)

    private var _customState: [String: Any] = [:]

    // MARK: - Observer (backing)

    private var _onChange: ((_ key: String) -> Void)?

    // MARK: - Public Read Access

    /// Whether the session is currently streaming a response.
    public var isStreaming: Bool { lock.read { _isStreaming } }

    /// The text being accumulated during the current streaming response.
    public var streamingText: String { lock.read { _streamingText } }

    /// The last error encountered, if any.
    public var lastError: Error? { lock.read { _lastError } }

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

    func setError(_ error: Error?) {
        let callback = lock.writeSync { () -> ((String) -> Void)? in
            _lastError = error
            return _onChange
        }
        if error != nil {
            dispatchCallback(callback, key: "lastError")
        }
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

    // MARK: - Private

    private func dispatchCallback(_ callback: ((String) -> Void)?, key: String) {
        guard let callback else { return }
        DispatchQueue.main.async { callback(key) }
    }
}
