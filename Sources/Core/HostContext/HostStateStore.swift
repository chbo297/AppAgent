//
//  HostStateStore.swift
//  AppAgent
//
//  宿主状态的现成存放处。宿主只做一件事：状态变了就把对应字段写进来。
//  SDK 每次请求模型前读一份副本，自己比对哪些字段变了。OC 可直接使用。
//

import Foundation

@objc(AppAgentHostStateStore)
public final class HostStateStore: NSObject, HostStateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String: String] = [:]
    private var descriptions: [String: String] = [:]
    private var eventSinks: [UUID: @Sendable (HostEvent) -> Void] = [:]

    public override init() {
        super.init()
    }

    // MARK: - 写状态（任意线程）

    /// 写一个字段；传 nil 删除。值是给模型读的文本，数值转字符串时注意防抖。
    @objc(setField:forKey:)
    public func setField(_ value: String?, forKey key: String) {
        lock.lock()
        fields[key] = value
        lock.unlock()
    }

    /// 合并写入多个字段，没提到的字段保持不变。
    @objc(setFields:)
    public func setFields(_ values: [String: String]) {
        lock.lock()
        fields.merge(values) { _, new in
            new
        }
        lock.unlock()
    }

    /// 整体替换：没出现在 `values` 里的字段都删掉。
    @objc(replaceAllFields:)
    public func replaceAllFields(_ values: [String: String]) {
        lock.lock()
        fields = values
        lock.unlock()
    }

    /// 给字段写一句含义说明。key 本身看得懂的不用写；说明只随完整状态发给模型。
    @objc(setDescription:forKey:)
    public func setDescription(_ description: String?, forKey key: String) {
        lock.lock()
        descriptions[key] = description
        lock.unlock()
    }

    // MARK: - 事件

    /// 告诉 SDK 发生了一件事（比如用户点了某个按钮）。它会随下一次模型请求发出，只发一次。
    @objc(postEventWithTrigger:action:detail:)
    public func postEvent(trigger: String, action: String, detail: String?) {
        postEvent(trigger: trigger, action: action, detail: detail, displayPolicy: .collapsed)
    }

    public func postEvent(
        trigger: String,
        action: String,
        detail: String? = nil,
        displayPolicy: AIAgentMessageDisplayPolicy
    ) {
        let event = HostEvent(trigger: trigger, action: action, detail: detail, displayPolicy: displayPolicy)
        lock.lock()
        let sinks = Array(eventSinks.values)
        lock.unlock()
        for sink in sinks {
            sink(event)
        }
    }

    // MARK: - 工具

    /// 把字典 / 数组转成固定格式的 JSON 文本（key 排序），同样的内容总是得到同样的文本。
    /// 不能转成 JSON 的对象返回 nil。
    @objc(stableTextFromObject:)
    public static func stableText(from object: Any) -> String? {
        if let text = object as? String {
            return text
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - HostStateProvider

    public func currentState() async -> [String: String] {
        copyFields()
    }

    public func fieldDescriptions() async -> [String: String] {
        copyDescriptions()
    }

    /// 同步读一份当前字段（宿主自己调试或展示用）。
    @objc public func copyFields() -> [String: String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return fields
    }

    private func copyDescriptions() -> [String: String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return descriptions
    }

    // MARK: - SDK 内部

    /// 每个装了这个 store 的会话注册一个接收口；返回的 token 用来注销。
    func addEventSink(_ sink: @escaping @Sendable (HostEvent) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        eventSinks[token] = sink
        lock.unlock()
        return token
    }

    func removeEventSink(_ token: UUID) {
        lock.lock()
        eventSinks.removeValue(forKey: token)
        lock.unlock()
    }
}
