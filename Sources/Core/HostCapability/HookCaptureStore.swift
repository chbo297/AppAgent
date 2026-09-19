//
//  HookCaptureStore.swift
//  AppAgent — 宿主能力层
//
//  JS↔端消息捕获的 agent 对端：读写门控配置、读取落盘的 JSONL 记录。
//  纯 Foundation，与宿主侧写入方共享同一磁盘契约（两侧不互相链接）：
//    目录: <Home>/Library/Caches/AppAgentMsgCapture/
//    文件: cap_<channel>_<yyyyMMdd>.jsonl（超 8MB 轮转为 cap_<channel>_<yyyyMMdd>_<epoch>.jsonl）
//    开关: NSUserDefaults key "appagent.msgcapture.config.v1"（JSON 字符串）
//  写开关后同进程的宿主写入方经 NSUserDefaultsDidChangeNotification 自动刷新门控。
//

import Foundation

/// 捕获特性的磁盘/配置契约常量与读写。所有方法无状态。
public enum HookCaptureStore {

    public static let configKey = "appagent.msgcapture.config.v1"
    static let dirName = "AppAgentMsgCapture"

    /// 四个消息边界，顺序（bitIndex）与宿主侧通道枚举一致。
    public static let channels = ["talos_in", "talos_out", "shell_in", "shell_out"]

    public static func isValidChannel(_ channel: String) -> Bool {
        channels.contains(channel)
    }

    // MARK: - 配置读写

    /// 读当前配置（顶层含 version / channels）。缺省返回空壳。
    public static func readConfig() -> [String: Any] {
        guard let raw = UserDefaults.standard.string(forKey: configKey),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return ["version": 1, "channels": [String: Any]()]
        }
        return dict
    }

    /// 写回配置（序列化为字符串存 UserDefaults）；触发同进程宿主写入方刷新。
    @discardableResult
    static func writeConfig(_ config: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config),
              let str = String(data: data, encoding: .utf8) else {
            return false
        }
        UserDefaults.standard.set(str, forKey: configKey)
        return true
    }

    /// 取 channels 子字典（容缺）。
    static func channelsDict(_ config: [String: Any]) -> [String: Any] {
        (config["channels"] as? [String: Any]) ?? [:]
    }

    /// 开启/更新某 channel：filter 里给出的字段覆盖写入，enabled 由调用方给定。
    @discardableResult
    static func setChannel(_ channel: String, enabled: Bool, filter: [String: Any]) -> Bool {
        guard isValidChannel(channel) else { return false }
        var config = readConfig()
        config["version"] = 1
        var chs = channelsDict(config)
        var entry = (chs[channel] as? [String: Any]) ?? [:]
        for (k, v) in filter { entry[k] = v }
        entry["enabled"] = enabled
        chs[channel] = entry
        config["channels"] = chs
        return writeConfig(config)
    }

    /// 关闭全部 channel（保留各自 filter 字段）。
    @discardableResult
    static func disableAll() -> Bool {
        var config = readConfig()
        var chs = channelsDict(config)
        for ch in channels {
            var entry = (chs[ch] as? [String: Any]) ?? [:]
            entry["enabled"] = false
            chs[ch] = entry
        }
        config["channels"] = chs
        return writeConfig(config)
    }

    // MARK: - 落盘记录读取

    static func directory() -> String {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (caches as NSString).appendingPathComponent(dirName)
    }

    /// 列出捕获文件（可选 channel 过滤），返回 (文件名, 字节数)，按名排序。
    static func files(channel: String? = nil) -> [(name: String, size: Int)] {
        let dir = directory()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let prefix = channel.map { "cap_\($0)_" }
        var out: [(name: String, size: Int)] = []
        for name in names.sorted() where name.hasPrefix("cap_") && name.hasSuffix(".jsonl") {
            if let prefix, !name.hasPrefix(prefix) { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
            out.append((name, size))
        }
        return out
    }

    /// 读取某 channel 记录，按 seq 升序返回尾部 limit 条；sinceSeq 只返回 seq 更大的。
    static func records(channel: String, limit: Int, sinceSeq: UInt64?) -> [[String: Any]] {
        let dir = directory()
        let paths = files(channel: channel).map { (dir as NSString).appendingPathComponent($0.name) }
        var recs: [[String: Any]] = []
        for path in paths {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let rec = obj as? [String: Any] else { continue }
                if let sinceSeq, let seq = (rec["seq"] as? NSNumber)?.uint64Value, seq <= sinceSeq { continue }
                recs.append(rec)
            }
        }
        recs.sort { (($0["seq"] as? NSNumber)?.uint64Value ?? 0) < (($1["seq"] as? NSNumber)?.uint64Value ?? 0) }
        if recs.count > limit { recs = Array(recs.suffix(limit)) }
        return recs
    }

    /// 删除捕获文件（可选 channel），返回删除数量。
    @discardableResult
    static func clear(channel: String? = nil) -> Int {
        let dir = directory()
        let fm = FileManager.default
        var n = 0
        for f in files(channel: channel) {
            let path = (dir as NSString).appendingPathComponent(f.name)
            if (try? fm.removeItem(atPath: path)) != nil { n += 1 }
        }
        return n
    }
}
