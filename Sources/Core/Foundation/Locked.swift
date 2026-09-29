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

    /// 在一次临界区内完成读-改-写。
    ///
    /// `value += 1` 走的是 get 再 set 两次加锁，中间别的线程能插进来，计数器就会丢号。
    /// 需要原子自增 / 原子追加时用这个，不要用复合赋值。
    public func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        _lock.withLock { body(&_value) }
    }

    /// `$value` 拿到 wrapper 自身，这样调用方能写 `$counter.mutate { $0 += 1 }`。
    public var projectedValue: Locked<Value> { self }
}

// MARK: - WeakLocked

/// Thread-safe property wrapper for weak references.
///
/// Swift does not allow `weak` on property-wrapper-backed properties,
/// so this type encapsulates the weak reference internally.
/// Supports both concrete class types and class-bound protocol existentials
/// (e.g., `any AIAgentDelegate` where `AIAgentDelegate: AnyObject`).
///
/// 边界（写清楚以免又变成「靠调用方自觉」）：
/// - `Value: Sendable` 是硬约束，所以取出来的引用可以跨隔离域用 —— 这一点和
///   `Locked` / `TrackedLocked` 对齐，不再是「盒子安全、内容随缘」。
/// - **不能**再加 `Value: AnyObject`：`AIAgent.delegate` 存的是 `any AIAgentDelegate`
///   这种类约束协议的存在类型，而存在类型不满足 `AnyObject` 泛型约束
///   （编译器原话：`requires that 'any AIAgentDelegate' be a class type`）。
///   因此「Value 必须是引用类型」仍然是调用方的责任：塞进值类型的话，
///   `as AnyObject?` 会把它桥成临时对象，弱引用下一刻就空。
/// - 盒子只保证**引用读写本身**是原子的；被引用对象内部状态的线程安全由那个类型自己负责。
///
/// 当前使用点（都满足上面两条）：
/// - `AISessionManager.agent` / `AIAgentMask._agent`：`AIAgent`（class，`@unchecked Sendable`）。
/// - `AIAgent.delegate`：`any AIAgentDelegate`，协议声明为 `AnyObject, Sendable`。
/// - 测试里的 `WeakLocked<UIView>` / `WeakLocked<AISession>`：只取元类型做身份判定，
///   两者都是 class（`UIView` 因为 `@MainActor` 隔离而隐式 Sendable）。
///
/// Usage:
///     @WeakLocked
///     public private(set) var agent: AIAgent?
@propertyWrapper
public final class WeakLocked<Value: Sendable>: @unchecked Sendable {
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

    /// 原子读改写，并标脏。
    ///
    /// 字典 / 数组这类容器**必须**走这里：`get` 出来改完再 `set` 回去，三步之间不是临界区，
    /// 两处并发更新会互相覆盖（`AISession.turnRecords` 就是被多个阶段打点并发写的）。
    /// 注意：带 `isEqual` 的实例走 `mutate` 也一律标脏（改没改不好判，宁可多存一次）。
    public func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        _lock.withLock {
            let result = body(&_value)
            _isDirty = true
            return result
        }
    }

    /// 让 `$property.mutate { … }` 可用，和 `Locked` 的用法保持一致。
    public var projectedValue: TrackedLocked<Value> { self }
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
