//
//  AIAgentMessageAttachment.swift
//  AppAgent
//
//  用户随提问一起发出的附件（输入栏「+」面板里选的图片 / 文件）。
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AIAgentMessage {

    /// 用户附件。图片把压缩后的字节直接存进消息（base64，随会话快照落盘），走 provider 的多模态通道；
    /// 文件先拷进 agent 工作区，模型拿到的是文件名、类型和逻辑 URI（可用 `file` 工具读取），
    /// 小的纯文本文件再把正文内联进去，省一次工具往返。
    public struct Attachment: Sendable, Codable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable {
            case image
            case file
        }

        public let id: String
        public let kind: Kind
        public let name: String
        public let mediaType: String
        public let byteCount: Int
        /// 图片附件发给模型的字节（已缩放压缩）。文件附件为 nil。
        public let image: ImageAttachment?
        /// 文件附件在 agent 文件资源里的逻辑 URI，如 `agent://workspace/attachments/<id>/a.txt`。
        public let resourceURI: String?
        /// 文件附件内联给模型的 UTF-8 正文；只有足够小的纯文本文件才有。
        public let inlineText: String?

        public init(
            id: String = UUID().uuidString,
            kind: Kind,
            name: String,
            mediaType: String,
            byteCount: Int,
            image: ImageAttachment? = nil,
            resourceURI: String? = nil,
            inlineText: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.mediaType = mediaType
            self.byteCount = byteCount
            self.image = image
            self.resourceURI = resourceURI
            self.inlineText = inlineText
        }

        /// 用已经压缩好的 JPEG 字节造一个图片附件（压缩见 `AttachmentImageProcessing`）。
        public static func image(
            jpegData: Data,
            name: String = "image.jpg",
            id: String = UUID().uuidString
        ) -> Attachment {
            Attachment(
                id: id,
                kind: .image,
                name: name,
                mediaType: "image/jpeg",
                byteCount: jpegData.count,
                image: ImageAttachment(data: jpegData, mediaType: "image/jpeg")
            )
        }

        /// 不走多模态通道时给模型看的文字描述。文件附件永远走这一路；图片附件只在缺字节时兜底。
        public var modelText: String {
            switch kind {
            case .image:
                return "[User attached image: \(name)]"
            case .file:
                var lines = [
                    "[User attached file]",
                    "name: \(name)",
                    "type: \(mediaType)",
                    "size: \(byteCount) bytes"
                ]
                if let resourceURI {
                    lines.append("location: \(resourceURI) (read it with the `file` tool, op=read)")
                }
                if let inlineText {
                    lines.append("content:\n<file_content>\n\(inlineText)\n</file_content>")
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    /// 本条消息里用户附带的图片 / 文件，按发送顺序。
    public var attachments: [Attachment] {
        content.compactMap { part in
            if case .attachment(let attachment) = part {
                return attachment
            }
            return nil
        }
    }
}

// MARK: - Image processing

/// 相册图片发给模型前的缩放与压缩：长边封顶、统一转 JPEG（HEIC / PNG 一并处理，方向按 EXIF 摆正）。
public enum AttachmentImageProcessing {
    /// 长边上限。Anthropic 建议不超过 1568px，再大只会被服务端缩小、白占上行流量和上下文。
    public static let maximumPixelSize = 1568
    public static let compressionQuality = 0.8

    public static func jpegData(
        from data: Data,
        maximumPixelSize: Int = maximumPixelSize,
        compressionQuality: Double = compressionQuality
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

// MARK: - File staging

/// 把用户选的文件拷进 agent 工作区，生成文件附件。
///
/// 拷贝而不是引用原路径：文件选择器给的 URL 是临时副本或安全作用域 URL，过后就失效；
/// 放进 `agent://workspace` 之后，模型在后续轮次也能用 `file` 工具按 URI 读到它。
public enum AttachmentFileStaging {
    public static let maximumByteCount = 20 * 1024 * 1024
    public static let maximumInlineTextByteCount = 64 * 1024
    public static let directoryName = "attachments"

    public enum StagingError: Error, LocalizedError, Equatable {
        case tooLarge(byteCount: Int, limit: Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .tooLarge(_, let limit):
                return "文件超过 \(limit / 1024 / 1024) MB，暂不支持发送。"
            case .unreadable:
                return "无法读取这个文件。"
            }
        }
    }

    public static func stage(
        fileAt sourceURL: URL,
        workspaceRoot: URL,
        workspaceURI: String = "agent://workspace",
        id: String = UUID().uuidString
    ) throws -> AIAgentMessage.Attachment {
        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile != false else {
            throw StagingError.unreadable
        }
        if let size = values?.fileSize, size > maximumByteCount {
            throw StagingError.tooLarge(byteCount: size, limit: maximumByteCount)
        }

        let name = sanitizedFileName(sourceURL.lastPathComponent)
        let directory = workspaceRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw StagingError.unreadable
        }

        let byteCount = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // 拷贝前读不到大小时（resourceValues 失败）上面的检查会放行，按落盘后的实际大小再卡一次。
        guard byteCount <= maximumByteCount else {
            try? FileManager.default.removeItem(at: directory)
            throw StagingError.tooLarge(byteCount: byteCount, limit: maximumByteCount)
        }
        let type = UTType(filenameExtension: destination.pathExtension)
        let mediaType = type?.preferredMIMEType ?? "application/octet-stream"
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let uri = "\(workspaceURI)/\(directoryName)/\(id)/\(encodedName)"

        return AIAgentMessage.Attachment(
            id: id,
            kind: .file,
            name: name,
            mediaType: mediaType,
            byteCount: byteCount,
            resourceURI: uri,
            inlineText: inlineText(at: destination, byteCount: byteCount)
        )
    }

    /// 只保留最后一段文件名，去掉路径分隔符与开头的点，防止拼路径时穿出 attachments 目录。
    static func sanitizedFileName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// 小于上限、能按 UTF-8 解码且不含 NUL 的才算纯文本，直接内联给模型。
    private static func inlineText(at url: URL, byteCount: Int) -> String? {
        guard byteCount > 0, byteCount <= maximumInlineTextByteCount,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            return nil
        }
        return text
    }

    // MARK: - Cleanup

    /// 启动清扫只动早于这个时长的目录：刚拷进来、还没发出去的附件不能被扫掉。
    public static let sweepMinimumAge: TimeInterval = 24 * 60 * 60

    /// 删掉一个还没发出去就被移除的文件附件（`attachments/<id>/` 整个目录）。
    /// 不是本模块拷进来的附件（没有 resourceURI、或 URI 不在 attachments 下）什么都不做。
    @discardableResult
    public static func discard(
        _ attachment: AIAgentMessage.Attachment,
        workspaceRoot: URL,
        workspaceURI: String = "agent://workspace"
    ) -> Bool {
        guard attachment.kind == .file,
              stagedDirectoryID(of: attachment, workspaceURI: workspaceURI) == attachment.id,
              isSafeDirectoryName(attachment.id) else {
            return false
        }
        let directory = attachmentsRoot(in: workspaceRoot).appendingPathComponent(attachment.id, isDirectory: true)
        return (try? FileManager.default.removeItem(at: directory)) != nil
    }

    /// 消息里引用到的暂存目录 id。
    public static func referencedDirectoryIDs(
        in messages: [AIAgentMessage],
        workspaceURI: String = "agent://workspace"
    ) -> Set<String> {
        var ids = Set<String>()
        for message in messages {
            for case .attachment(let attachment) in message.content {
                if let id = stagedDirectoryID(of: attachment, workspaceURI: workspaceURI) {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// 删掉没有任何会话引用、且早于 `minimumAge` 的暂存目录，返回删掉的个数。
    /// 只认 `stage` 生成的 UUID 目录名：attachments 下别人放的目录（agent 用 file 工具写的、宿主自建的）一律不碰。
    ///
    /// `referencedIDs` 必须覆盖所有还可能被打开的会话（活跃 + 废纸篓）；读不全时调用方应放弃清扫，
    /// 不能拿半份引用表来删。永久删除的会话不再引用，它的附件下次启动时被这里清掉。
    @discardableResult
    public static func sweep(
        workspaceRoot: URL,
        referencedIDs: Set<String>,
        minimumAge: TimeInterval = sweepMinimumAge,
        now: Date = Date()
    ) -> Int {
        let root = attachmentsRoot(in: workspaceRoot)
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard UUID(uuidString: name) != nil,
                  !referencedIDs.contains(name),
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge else {
                continue
            }
            if (try? FileManager.default.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    private static func attachmentsRoot(in workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 从 `agent://workspace/attachments/<id>/<name>` 里取出 `<id>`；不是这个形状就是 nil。
    private static func stagedDirectoryID(
        of attachment: AIAgentMessage.Attachment,
        workspaceURI: String
    ) -> String? {
        let prefix = "\(workspaceURI)/\(directoryName)/"
        guard let uri = attachment.resourceURI, uri.hasPrefix(prefix) else {
            return nil
        }
        let rest = uri.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else {
            return nil
        }
        let id = String(rest[..<slash])
        return isSafeDirectoryName(id) ? id : nil
    }

    private static func isSafeDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}
