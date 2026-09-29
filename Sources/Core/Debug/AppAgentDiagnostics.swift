//
//  AppAgentDiagnostics.swift
//  AppAgent
//
//  「导出全部调试数据」的打包实现：把散在各处的排查素材收进一个目录再压成 zip，
//  由 UI 交给系统分享面板（AirDrop / 存到文件 / 发消息）。
//
//  收哪些东西：
//  - summary.txt        运行环境 + 各项计数，先看这个就知道包里有什么
//  - debug-log.txt/json 模型接口调用记录（AppAgentDebugLog，进程内环形缓冲）
//  - run-logs/          Logger 落盘的运行日志（AppAgentRunLog，跨启动保留）
//  - sessions/          会话快照（含每轮的工具往返，能复原对话时间线）
//  - memory/            长期记忆
//
//  zip 不引第三方：用 `NSFileCoordinator` 的 `.forUploading` 读意图，系统会给一个
//  目录的临时 zip 副本，拷出来即可。整个过程是阻塞的，所以只在后台队列跑。
//

import Foundation

public enum AppAgentDiagnostics {

    public struct Bundle: Sendable {
        /// 打好的 zip 位置（临时目录，分享完可由系统清理）。
        public let url: URL
        public let byteCount: Int
        /// 包内条目的可读清单，UI 可以直接提示给用户。
        public let manifest: [String]
    }

    public enum ExportError: Error, LocalizedError {
        case packagingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .packagingFailed(let reason): return "打包失败：\(reason)"
            }
        }
    }

    /// 异步导出（在后台队列做文件拷贝与压缩，回调切回主线程）。
    ///
    /// `completion` **一定在主线程回调**：实现最后一句就是往主队列投，所以类型上直接标
    /// `@MainActor`，调用方拿到的闭包天然能碰视图，不用再自己切队列。
    public static func export(
        debugLog: AppAgentDebugLog = .shared,
        runLog: AppAgentRunLog = .shared,
        completion: @escaping @MainActor (Result<Bundle, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Bundle, Error>
            do {
                result = .success(try exportSync(debugLog: debugLog, runLog: runLog))
            } catch {
                result = .failure(error)
            }
            // 已经在往主队列投了，`assumeIsolated` 只是把这个事实告诉编译器，不改变行为。
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// 同步导出（测试直接用这个）。
    public static func exportSync(
        debugLog: AppAgentDebugLog = .shared,
        runLog: AppAgentRunLog = .shared,
        now: Date = Date()
    ) throws -> Bundle {
        let fm = FileManager.default
        let stamp = AppAgentRunLog.fileStamp(now)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appagent-diagnostics-\(stamp)", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var manifest: [String] = []

        // 1) 模型接口调用记录。
        let events = debugLog.snapshot()
        try write(debugLog.exportText(), to: root.appendingPathComponent("debug-log.txt"))
        try write(debugLog.exportJSON(), to: root.appendingPathComponent("debug-log.json"))
        manifest.append("debug-log.txt / .json — 模型调用记录 \(events.count) 条")

        // 2) Logger 运行日志（先 flush，否则最后几行还在队列里）。
        runLog.flush()
        let logFiles = runLog.files()
        if !logFiles.isEmpty {
            let dest = root.appendingPathComponent("run-logs", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for url in logFiles {
                try? fm.copyItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent))
            }
            manifest.append("run-logs/ — 运行日志 \(logFiles.count) 个文件")
        } else {
            manifest.append("run-logs/ — 空（未调用 AppAgentRunLog.shared.install()）")
        }

        // 3) 会话快照 + 4) 长期记忆。
        let copiedSessions = copyDirectory(
            sessionsDirectory(), into: root, named: "sessions", matching: "json"
        )
        manifest.append("sessions/ — 会话快照 \(copiedSessions) 个")
        let copiedMemory = copyDirectory(
            memoryDirectory(), into: root, named: "memory", matching: "json"
        )
        manifest.append("memory/ — 记忆文件 \(copiedMemory) 个")

        // 5) 概要放最后写，好把上面的计数写进去。
        try write(
            summaryText(now: now, events: events, runLogFiles: logFiles, manifest: manifest),
            to: root.appendingPathComponent("summary.txt")
        )

        let zipURL = try zip(directory: root, stamp: stamp)
        try? fm.removeItem(at: root)
        let attributes = try? fm.attributesOfItem(atPath: zipURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return Bundle(url: zipURL, byteCount: size, manifest: manifest)
    }

    // MARK: - Pieces

    static func sessionsDirectory() -> URL? {
        documents()?.appendingPathComponent("AppAgent/sessions", isDirectory: true)
    }

    static func memoryDirectory() -> URL? {
        documents()?.appendingPathComponent("AppAgent/memory", isDirectory: true)
    }

    private static func documents() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func summaryText(
        now: Date,
        events: [AppAgentDebugEvent],
        runLogFiles: [URL],
        manifest: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("AppAgent 诊断包")
        lines.append("导出时间: \(AppAgentRunLog.stamp(now))")
        lines.append("时区: \(TimeZone.current.identifier)")
        lines.append("")
        lines.append("# 运行环境")
        for (key, value) in environmentInfo() {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("# 日志配置")
        lines.append("Logger.isEnabled: \(Logger.isEnabled)")
        lines.append("Logger.minimumLevel: \(Logger.minimumLevel.label)")
        lines.append("AppAgentRunLog.isInstalled: \(AppAgentRunLog.shared.isInstalled)")
        lines.append("AppAgentRunLog.directory: \(AppAgentRunLog.shared.directory.path)")
        lines.append("")
        lines.append("# 模型调用记录")
        lines.append("总数: \(events.count)")
        for kind in ["request", "success", "failure", "retry", "fallback", "info"] {
            let count = events.filter { $0.kind.rawValue == kind }.count
            lines.append("\(kind): \(count)")
        }
        if let last = events.last {
            lines.append("最后一条: \(last.line)")
        }
        lines.append("")
        lines.append("# 包内清单")
        lines.append(contentsOf: manifest.map { "- \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func environmentInfo() -> [(String, String)] {
        var info: [(String, String)] = []
        let bundle = Foundation.Bundle.main
        info.append(("bundleId", bundle.bundleIdentifier ?? "-"))
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        info.append(("appVersion", "\(version) (\(build))"))
        info.append(("processName", ProcessInfo.processInfo.processName))
        #if canImport(UIKit) && !os(watchOS)
        info.append(("system", "iOS/Catalyst"))
        #else
        info.append(("system", "macOS"))
        #endif
        info.append(("osVersion", ProcessInfo.processInfo.operatingSystemVersionString))
        info.append(("locale", Locale.current.identifier))
        return info
    }

    /// 把 `source` 下匹配后缀的文件拷进 `root/name/`，返回拷了几个。
    @discardableResult
    private static func copyDirectory(
        _ source: URL?, into root: URL, named name: String, matching ext: String
    ) -> Int {
        guard let source else { return 0 }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }
        guard !files.isEmpty else { return 0 }
        let dest = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = 0
        for url in files {
            let target = dest.appendingPathComponent(url.lastPathComponent)
            if (try? fm.copyItem(at: url, to: target)) != nil { copied += 1 }
        }
        return copied
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 用 `NSFileCoordinator` 的 `.forUploading` 拿到目录的 zip 副本（系统实现，不引三方库）。
    private static func zip(directory: URL, stamp: String) throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appagent-diagnostics-\(stamp).zip")
        try? FileManager.default.removeItem(at: dest)

        var coordinatorError: NSError?
        var copyError: Error?
        var produced = false
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: .forUploading, error: &coordinatorError
        ) { temporary in
            do {
                try FileManager.default.copyItem(at: temporary, to: dest)
                produced = true
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard produced else { throw ExportError.packagingFailed("zip 未生成") }
        return dest
    }
}
