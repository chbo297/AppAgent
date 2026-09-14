//
//  Locked.swift
//  AppAgent
//

import Foundation
import os

// MARK: - UnfairLock (internal)

/// Lightweight mutex wrapper around `os_unfair_lock`.
///
/// `os_unfair_lock` must not be moved in memory once initialized,
/// so we heap-allocate it via `UnsafeMutablePointer`.
final class UnfairLock: @unchecked Sendable {
    private let _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = .allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    @inline(__always)
    func lock() { os_unfair_lock_lock(_lock) }

    @inline(__always)
    func unlock() { os_unfair_lock_unlock(_lock) }

    @inline(__always)
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}

// MARK: - Locked

/// Thread-safe property wrapper using `os_unfair_lock`.
///
/// Usage:
///     @Locked
///     public var value: Int = 0
@propertyWrapper
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let _lock = UnfairLock()
    private var _value: Value

    public init(wrappedValue: Value) {
        self._value = wrappedValue
    }

    public var wrappedValue: Value {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

// MARK: - WeakLocked

/// Thread-safe property wrapper for weak references.
///
/// Swift does not allow `weak` on property-wrapper-backed properties,
/// so this type encapsulates the weak reference internally.
/// Supports both concrete class types and class-bound protocol existentials
/// (e.g., `any AIAgentDelegate` where `AIAgentDelegate: AnyObject`).
///
/// Usage:
///     @WeakLocked
///     public private(set) var agent: AIAgent?
@propertyWrapper
public final class WeakLocked<Value>: @unchecked Sendable {
    private let _lock = UnfairLock()
    private weak var _ref: AnyObject?

    public init(wrappedValue: Value? = nil) {
        self._ref = wrappedValue as AnyObject?
    }

    public var wrappedValue: Value? {
        get { _lock.withLock { _ref as? Value } }
        set { _lock.withLock { _ref = newValue as AnyObject? } }
    }
}

// MARK: - TrackedLocked

/// Thread-safe property wrapper with dirty-tracking for deferred persistence.
///
/// Tracks whether the value has actually changed since the last `clearDirty()`.
/// For `Equatable` values, pass `isEqual: ==` to skip marking dirty on same-value assignment.
/// Without `isEqual`, every assignment marks the property as dirty.
///
/// Usage:
///     @TrackedLocked(isEqual: ==)
///     public var title: String = "New Chat"
@propertyWrapper
public final class TrackedLocked<Value: Sendable>: @unchecked Sendable {
    private let _lock = UnfairLock()
    private var _value: Value
    private var _isDirty: Bool = false
    private let isEqual: ((Value, Value) -> Bool)?

    /// Init without equality check — every assignment marks dirty.
    public init(wrappedValue: Value) {
        self._value = wrappedValue
        self.isEqual = nil
    }

    /// Init with equality check — only marks dirty when value actually changes.
    public init(wrappedValue: Value,
                isEqual: @escaping (Value, Value) -> Bool) {
        self._value = wrappedValue
        self.isEqual = isEqual
    }

    public var wrappedValue: Value {
        get { _lock.withLock { _value } }
        set {
            _lock.withLock {
                if let isEqual = isEqual, isEqual(_value, newValue) { return }
                _value = newValue
                _isDirty = true
            }
        }
    }

    /// Whether this property has been modified since last `clearDirty()`.
    public var isDirty: Bool {
        _lock.withLock { _isDirty }
    }

    /// Clear the dirty flag (call after successful persistence).
    public func clearDirty() {
        _lock.withLock { _isDirty = false }
    }
}

// MARK: - ReadersWriterLock

/// Mutex lock with reader-writer style API, backed by `os_unfair_lock`.
///
/// Usage:
///     private let lock = ReadersWriterLock()
///     var value: Int {
///         get { lock.read { _value } }
///         set { lock.writeSync { _value = newValue } }
///     }
public final class ReadersWriterLock: @unchecked Sendable {
    private let _lock = UnfairLock()

    public init() {}

    /// Synchronous read (exclusive).
    public func read<T>(_ work: () -> T) -> T {
        _lock.withLock { work() }
    }

    /// Synchronous write (exclusive, blocks until complete).
    @discardableResult
    public func writeSync<T>(_ work: () -> T) -> T {
        _lock.withLock { work() }
    }
}
