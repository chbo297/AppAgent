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

    /// 宿主定义的捕获通道。SDK 不规定通道集合或业务语义，只要求通道名可安全用于
    /// JSONL 文件名；工具会从当前配置和落盘文件中发现已使用的通道。
    public static var channels: [String] {
        var names = Set(channelsDict(readConfig()).keys.filter(isValidChannel))
        for file in files() {
            if let channel = channelName(fromCaptureFile: file.name) {
                names.insert(channel)
            }
        }
        return names.sorted()
    }

    public static func isValidChannel(_ channel: String) -> Bool {
        guard !channel.isEmpty, channel.utf8.count <= 128 else {
            return false
        }
        return channel.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value == 45
                || value == 46
                || value == 95
                || value >= 48 && value <= 57
                || value >= 65 && value <= 90
                || value >= 97 && value <= 122
        }
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

    private static func channelName(fromCaptureFile name: String) -> String? {
        guard name.hasPrefix("cap_"), name.hasSuffix(".jsonl") else {
            return nil
        }
        let body = name.dropFirst(4).dropLast(5)
        var end = body.endIndex
        while let separator = body[..<end].lastIndex(of: "_") {
            let candidate = String(body[..<separator])
            let suffixStart = body.index(after: separator)
            let suffix = body[suffixStart..<body.endIndex]
            if isValidChannel(candidate), suffix.first?.isNumber == true {
                return candidate
            }
            end = separator
        }
        return nil
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

    /// 有界读取；webviewId 与容器检视共享，runId 限定 seq 所属的进程生命周期。
    /// 需要获知读取预算、损坏记录和采集状态时使用 readSnapshot。
    public static func records(
        channel: String,
        limit: Int,
        sinceSeq: UInt64?,
        webviewId: String? = nil,
        callId: String? = nil,
        runId: String? = nil,
        pageId: String? = nil
    ) -> [[String: Any]] {
        readSnapshot(channel: channel, limit: limit, sinceSeq: sinceSeq,
                     webviewId: webviewId, callId: callId, runId: runId,
                     pageId: pageId)["records"] as? [[String: Any]] ?? []
    }

    /// 只读已落盘的证据。空结果不代表没有调用；采集可能关闭、未接入或尚未写盘。
    /// 默认最多扫描最新 64 个文件、合计 8 MiB，返回最多 500 条、256 KiB JSON。
    public static func readSnapshot(
        channel: String,
        limit: Int,
        sinceSeq: UInt64?,
        webviewId: String? = nil,
        callId: String? = nil,
        runId: String? = nil,
        pageId: String? = nil
    ) -> [String: Any] {
        readSnapshot(directory: directory(), channel: channel, limit: limit, sinceSeq: sinceSeq,
                     webviewId: webviewId, callId: callId, runId: runId, pageId: pageId)
    }

    // 目录与预算可注入，测试只操作自己的临时目录，不触碰宿主的真实抓包文件。
    static func readSnapshot(
        directory: String,
        channel: String,
        limit: Int,
        sinceSeq: UInt64?,
        webviewId: String? = nil,
        callId: String? = nil,
        runId: String? = nil,
        pageId: String? = nil,
        maxScanBytes: Int = 8 * 1024 * 1024,
        maxFiles: Int = 64,
        maxOutputBytes: Int = 256 * 1024
    ) -> [String: Any] {
        guard isValidChannel(channel) else {
            return ["records": [], "count": 0, "warnings": ["unknown_channel"]]
        }
        let fm = FileManager.default
        let config = channelsDict(readConfig())[channel] as? [String: Any] ?? [:]
        let enabled = config["enabled"] as? Bool ?? false
        var warnings: [String] = []
        if !enabled {
            warnings.append("capture_disabled: records, if any, are historical")
        }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: directory)
        } catch {
            return ["channel": channel, "captureEnabled": enabled, "count": 0, "records": [],
                    "truncated": false, "scannedBytes": 0, "scannedFiles": 0,
                    "warnings": warnings + ["capture_directory_unavailable"]]
        }
        let prefix = "cap_\(channel)_"
        var candidates: [(path: String, modified: TimeInterval)] = []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".jsonl") {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }
            candidates.append((path, (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
        }
        candidates.sort {
            if $0.modified != $1.modified {
                return $0.modified > $1.modified
            }
            return $0.path > $1.path
        }
        let fileLimit = max(0, maxFiles)
        var scanTruncated = candidates.count > fileLimit
        var scannedBytes = 0
        var scannedFiles = 0
        var malformed = 0
        var unreadable = 0
        var recs: [[String: Any]] = []
        var cursorNeedsRun = false
        let filters = ["webviewId": webviewId, "callId": callId, "runId": runId, "pageId": pageId]
        for candidate in candidates.prefix(fileLimit) {
            let budget = max(0, maxScanBytes - scannedBytes)
            guard budget > 0 else {
                scanTruncated = true
                break
            }
            do {
                let tail = try captureTail(path: candidate.path, budget: budget)
                scannedBytes += tail.bytes
                scannedFiles += 1
                scanTruncated = scanTruncated || tail.truncated
                for line in tail.data.split(separator: 0x0A) where !line.isEmpty {
                    // 单条超大记录不允许撑爆解析器；旧 producer 的无界数据明确记为读取损失。
                    guard line.count <= 256 * 1024,
                          let rec = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        malformed += 1
                        continue
                    }
                    if let recordedChannel = rec["ch"] as? String, recordedChannel != channel {
                        malformed += 1
                        continue
                    }
                    guard filters.allSatisfy({ key, value in
                        value == nil || rec[key] as? String == value
                    }) else {
                        continue
                    }
                    if let sinceSeq {
                        if runId == nil, rec["runId"] as? String != nil {
                            cursorNeedsRun = true
                            continue
                        }
                        guard let seq = sequence(rec), seq > sinceSeq else {
                            continue
                        }
                    }
                    recs.append(rec)
                }
            } catch {
                unreadable += 1
            }
        }
        if cursorNeedsRun {
            // 新格式的 seq 会在进程重启后归零，禁止将上次进程的游标套到新进程。
            recs.removeAll()
            warnings.append("sinceSeq_requires_runId")
        }
        recs.sort {
            let leftTime = ($0["ts"] as? NSNumber)?.doubleValue ?? 0
            let rightTime = ($1["ts"] as? NSNumber)?.doubleValue ?? 0
            if leftTime != rightTime {
                return leftTime < rightTime
            }
            return (sequence($0) ?? 0) < (sequence($1) ?? 0)
        }
        let requestedLimit = min(500, max(1, limit))
        var truncated = scanTruncated || recs.count > requestedLimit
        var selected: [[String: Any]] = []
        var outputBytes = 0
        for rec in recs.suffix(requestedLimit).reversed() {
            guard let data = try? JSONSerialization.data(withJSONObject: rec),
                  outputBytes + data.count <= max(0, maxOutputBytes) else {
                truncated = true
                continue
            }
            selected.append(rec)
            outputBytes += data.count
        }
        selected.reverse()
        if scanTruncated {
            warnings.append("scan_budget_reached: older records were not fully searched")
        }
        if malformed > 0 {
            warnings.append("malformed_or_oversized_records: \(malformed)")
        }
        if unreadable > 0 {
            warnings.append("unreadable_files: \(unreadable)")
        }
        if selected.isEmpty {
            warnings.append("no_matching_evidence: this does not prove that no messages occurred")
        }
        var result: [String: Any] = [
            "channel": channel, "captureEnabled": enabled, "count": selected.count,
            "records": selected, "truncated": truncated, "scanTruncated": scanTruncated,
            "scannedBytes": scannedBytes, "scannedFiles": scannedFiles, "warnings": warnings
        ]
        let runs = Set(selected.compactMap {
            $0["runId"] as? String
        })
        let hasOneRun = runs.count == 1 && selected.allSatisfy {
            $0["runId"] as? String == runs.first
        }
        let lastSeq = selected.compactMap {
            sequence($0)
        }.max()
        if hasOneRun, let selectedRun = runs.first, let lastSeq {
            result["nextCursor"] = ["runId": selectedRun, "sinceSeq": lastSeq]
        }
        return result
    }

    private static func sequence(_ record: [String: Any]) -> UInt64? {
        guard let value = record["seq"] as? NSNumber,
              value.doubleValue.isFinite, value.doubleValue >= 0,
              value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue < Double(UInt64.max) else {
            return nil
        }
        return value.uint64Value
    }

    private static func captureTail(path: String, budget: Int) throws
        -> (data: Data, bytes: Int, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer {
            try? handle.close()
        }
        let length = try handle.seekToEnd()
        let count = Int(min(length, UInt64(max(0, budget))))
        let start = length - UInt64(count)
        var startsAtLine = start == 0
        if start > 0 {
            try handle.seek(toOffset: start - 1)
            startsAtLine = try handle.read(upToCount: 1)?.first == 0x0A
        }
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: count) ?? Data()
        if !startsAtLine {
            guard let newline = data.firstIndex(of: 0x0A) else {
                return (Data(), data.count, true)
            }
            return (Data(data.suffix(from: data.index(after: newline))), data.count, true)
        }
        return (data, data.count, start > 0)
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
