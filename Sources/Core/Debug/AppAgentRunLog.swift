//
//  AppAgentRunLog.swift
//  AppAgent
//
//  把 `Logger` 的输出同时落盘，供真机排查用。`Logger` 本身只 print 或交给宿主 handler，
//  真机上跑完就没了（没接 Xcode 的话连 print 都看不到），所以这里挂一层文件 sink：
//  按大小滚动、只留最近几个文件，`AppAgentDiagnostics` 打包时把它们一并带走。
//
//  安装是幂等的，且**不吃掉**原有 handler（原来没有 handler 就仍然 print）。
//

import Foundation

public final class AppAgentRunLog: @unchecked Sendable {

    public static let shared = AppAgentRunLog()

    /// 单个文件上限，超过就换下一个。
    public var maxFileBytes: Int = 2 * 1024 * 1024
    /// 保留的文件个数（含当前正在写的那个）。
    public var maxFiles: Int = 3

    private let queue = DispatchQueue(label: "com.appagent.runlog", qos: .utility)
    private let lock = ReadersWriterLock()
    private var _directory: URL
    private var _isInstalled = false

    /// 以下三个只在 `queue` 上访问。
    private var handle: FileHandle?
    private var currentURL: URL?
    private var writtenBytes = 0

    public init(directory: URL? = nil) {
        self._directory = directory ?? AppAgentRunLog.defaultDirectory()
    }

    /// 日志目录（默认 `Documents/AppAgent/logs`，这样 `file_read` / 系统「文件」App 都能看到）。
    public var directory: URL {
        get { lock.read { _directory } }
        set { lock.writeSync { _directory = newValue } }
    }

    public var isInstalled: Bool { lock.read { _isInstalled } }

    private static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("AppAgent/logs", isDirectory: true)
    }

    // MARK: - Install

    /// 打开 `Logger` 并把输出接到文件。重复调用无副作用。
    ///
    /// - Parameter minimumLevel: 同时设置 `Logger.minimumLevel`；传 nil 表示不动。
    public func install(minimumLevel: AppAgentLogLevel? = .debug) {
        let alreadyInstalled: Bool = lock.writeSync {
            if _isInstalled { return true }
            _isInstalled = true
            return false
        }
        guard !alreadyInstalled else { return }

        Logger.isEnabled = true
        if let minimumLevel { Logger.minimumLevel = minimumLevel }

        // 保留原 handler：宿主可能已经把日志接到自己的系统里了。
        let previous = Logger.handler
        Logger.handler = { [weak self] level, message in
            if let previous {
                previous(level, message)
            } else {
                print(message)
            }
            self?.append(message)
        }

        append("=== AppAgent run log opened: \(AppAgentRunLog.stamp(Date())) ===")
    }

    // MARK: - Write

    /// 追加一行（异步，不阻塞调用方）。
    public func append(_ line: String) {
        let dir = directory
        queue.async { [weak self] in
            self?.writeSync(line, directory: dir)
        }
    }

    /// 等待已排队的写入落盘——导出前调一下，否则最后几行还在队列里。
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    private func writeSync(_ line: String, directory dir: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if handle == nil || writtenBytes + data.count > maxFileBytes {
            rotate(directory: dir)
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            writtenBytes += data.count
        } catch {
            // 写不动就放弃这一行：日志本身不该把宿主拖挂。
        }
    }

    private func rotate(directory dir: URL) {
        try? handle?.close()
        handle = nil
        writtenBytes = 0

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("appagent-\(AppAgentRunLog.fileStamp(Date())).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        if let handle {
            let end = (try? handle.seekToEnd()) ?? 0
            writtenBytes = Int(end)
        }
        currentURL = url
        prune(directory: dir)
    }

    private func prune(directory dir: URL) {
        let all = AppAgentRunLog.logFiles(in: dir)
        guard all.count > maxFiles else { return }
        for url in all.prefix(all.count - maxFiles) where url != currentURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Read

    /// 当前保留的日志文件，按文件名（即时间）升序。
    public func files() -> [URL] {
        AppAgentRunLog.logFiles(in: directory)
    }

    /// 全部日志内容拼起来（导出文本用）。
    public func exportText() -> String {
        flush()
        return files()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    public func clear() {
        let dir = directory
        queue.sync {
            try? handle?.close()
            handle = nil
            currentURL = nil
            writtenBytes = 0
            for url in AppAgentRunLog.logFiles(in: dir) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func logFiles(in dir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Formatting

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
    static func fileStamp(_ date: Date) -> String { fileStampFormatter.string(from: date) }
}
