import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import AppAgent

/// 输入栏「+」附件：图片走三家协议的多模态通道，文件拷进工作区并以文字描述给模型。
final class UserAttachmentTests: XCTestCase {

    private func makeMessage() -> AIAgentMessage {
        let image = AIAgentMessage.Attachment.image(jpegData: Data([0xFF, 0xD8, 0xFF]), id: "img-1")
        let file = AIAgentMessage.Attachment(
            id: "file-1",
            kind: .file,
            name: "notes.txt",
            mediaType: "text/plain",
            byteCount: 5,
            resourceURI: "agent://workspace/attachments/file-1/notes.txt",
            inlineText: "hello"
        )
        return .user("看看这个", attachments: [image, file], turnID: 1)
    }

    func testUserAttachmentsReachAllThreeWireFormats() throws {
        let message = makeMessage()
        XCTAssertTrue(message.isGenuineUserInput)
        XCTAssertEqual(message.text, "看看这个")
        XCTAssertEqual(message.attachments.map(\.id), ["img-1", "file-1"])

        let anthropic = try XCTUnwrap(String(
            data: JSONEncoder().encode(AnthropicMapper.toAnthropicMessages([message])),
            encoding: .utf8
        ))
        XCTAssertTrue(anthropic.contains(#""type":"image""#))
        XCTAssertTrue(anthropic.contains(#""media_type":"image\/jpeg""#))
        XCTAssertTrue(anthropic.contains("<file_content>"))

        let chat = OpenAIChatCompletionsMapper.toMessages([message], system: [])
        let chatContent = try XCTUnwrap(chat.last?["content"] as? [[String: Any]])
        XCTAssertEqual(chatContent.first?["type"] as? String, "image_url")
        let chatText = try XCTUnwrap(chatContent.last?["text"] as? String)
        XCTAssertTrue(chatText.contains("agent://workspace/attachments/file-1/notes.txt"))
        XCTAssertTrue(chatText.hasSuffix("\n\n看看这个"))

        let responses = OpenAIResponsesMapper.toInput([message])
        let responseContent = try XCTUnwrap(responses.last?["content"] as? [[String: Any]])
        let responseTypes = responseContent.map { part in
            part["type"] as? String
        }
        XCTAssertEqual(responseTypes, ["input_image", "input_text", "input_text"])
    }

    func testAttachmentOnlyMessageHasNoEmptyTextPartAndSurvivesCoding() throws {
        let image = AIAgentMessage.Attachment.image(jpegData: Data([1, 2, 3]), id: "only")
        let message = AIAgentMessage.user("", attachments: [image])
        XCTAssertEqual(message.content.count, 1)

        let decoded = try JSONDecoder().decode(
            AIAgentMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded.attachments, [image])
        XCTAssertTrue(decoded.isGenuineUserInput)
    }

    /// 用户附图只在当前轮发给模型，更早轮次换成占位文字，不再每轮整批重发。
    func testOlderTurnUserImagesAreReplacedWithPlaceholder() {
        let oldImage = AIAgentMessage.Attachment.image(jpegData: Data([1, 2, 3]), id: "old")
        let newImage = AIAgentMessage.Attachment.image(jpegData: Data([4, 5, 6]), id: "new")
        let messages = [
            AIAgentMessage.user("第一轮", attachments: [oldImage], turnID: 1),
            AIAgentMessage(role: .assistant, content: [.text("看到了")], turnID: 1),
            AIAgentMessage.user("第二轮", attachments: [newImage], turnID: 2)
        ]

        let retained = SimpleContextCompressor.retainingRecentImages(messages, keep: 2, currentTurnID: 2)

        XCTAssertTrue(retained[0].attachments.isEmpty)
        XCTAssertTrue(retained[0].text.contains("omitted to save context"))
        XCTAssertEqual(retained[2].attachments, [newImage])
        // 不传当前轮时保持原行为：用户附图不动。
        XCTAssertEqual(SimpleContextCompressor.retainingRecentImages(messages, keep: 2)[0].attachments, [oldImage])
    }

    /// 只发图片没有文字时，当前时间 / 宿主上下文要包到这条消息上，不能落到上一轮的文字消息。
    func testAttachmentOnlyRequestReceivesMessageContext() async throws {
        let session = AISession(id: "attachment-context")
        let previous = AIAgentMessage.user("上一轮的问题", turnID: 1)
        let image = AIAgentMessage.Attachment.image(jpegData: Data([1, 2, 3]), id: "only")
        let current = AIAgentMessage.user("", attachments: [image], turnID: 2)

        let prepared = await session.executor.prepareMessagesForProvider(
            [previous, current], session: session, turnID: 2, isFirstIteration: true
        )

        XCTAssertEqual(prepared.first?.text, "上一轮的问题")
        let wrapped = try XCTUnwrap(prepared.last)
        XCTAssertFalse(wrapped.text.isEmpty)
        XCTAssertEqual(wrapped.attachments, [image])
    }

    func testStagedFileLandsInWorkspaceAndResolvesThroughRegistry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source/周报 v1.md")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# 标题".utf8).write(to: source)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)

        let attachment = try AttachmentFileStaging.stage(fileAt: source, workspaceRoot: workspace, id: "a1")

        XCTAssertEqual(attachment.kind, .file)
        XCTAssertEqual(attachment.name, "周报 v1.md")
        XCTAssertEqual(attachment.inlineText, "# 标题")
        let uri = try XCTUnwrap(attachment.resourceURI)
        let resolved = try XCTUnwrap(FileResourceRegistry(agentWorkspaceURL: workspace).resolve(uri))
        let staged = resolved.descriptor.rootURL.appendingPathComponent(resolved.relativePath)
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "# 标题")
        XCTAssertEqual(AttachmentFileStaging.sanitizedFileName("../.."), "_")
    }

    /// 发送前移除即删；启动清扫只删「没有会话引用 + 放了超过一天」的目录。
    func testStagedFilesAreRemovedWhenDiscardedOrUnreferenced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source/a.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        // 暂存目录名是 UUID；用名字取一个固定 UUID，断言时好读。
        var ids: [String: String] = [:]
        let directoryID = { (name: String) -> String in
            if let id = ids[name] {
                return id
            }
            let id = UUID().uuidString
            ids[name] = id
            return id
        }
        let folder = { (name: String) in
            workspace.appendingPathComponent("attachments/\(directoryID(name))", isDirectory: true)
        }
        let stage = { (name: String) in
            try AttachmentFileStaging.stage(fileAt: source, workspaceRoot: workspace, id: directoryID(name))
        }

        let removedBeforeSend = try stage("removed")
        XCTAssertTrue(AttachmentFileStaging.discard(removedBeforeSend, workspaceRoot: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("removed").path))

        let sent = try stage("sent")
        let archivedSent = try stage("archived")
        _ = try stage("orphan")
        _ = try stage("fresh")
        let dayAgo = Date().addingTimeInterval(-AttachmentFileStaging.sweepMinimumAge - 60)
        // 不是 stage 建的目录（比如 agent 自己写的 project-files），再旧也不能删。
        let foreign = workspace.appendingPathComponent("attachments/project-files", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: dayAgo], ofItemAtPath: foreign.path)
        for id in ["sent", "archived", "orphan"] {
            try FileManager.default.setAttributes([.modificationDate: dayAgo], ofItemAtPath: folder(id).path)
        }

        let storage = InMemorySessionStorage()
        let manager = AISessionManager(storage: storage)
        let snapshot = { (id: String, attachment: AIAgentMessage.Attachment) in
            SessionSnapshot(
                id: id, title: id, createdAt: Date(), updatedAt: Date(),
                messages: [.user("看附件", attachments: [attachment])]
            )
        }
        try await storage.save(session: snapshot("active", sent))
        try await storage.archive(session: snapshot("trashed", archivedSent))

        let removed = await manager.sweepStagedAttachments(workspaceRoot: workspace)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder("orphan").path))
        for id in ["sent", "archived", "fresh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder(id).path), "\(id) 不该被清掉")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "不是 stage 建的目录不该被清掉")
    }

    func testPhotoIsDownscaledToLongEdgeLimit() throws {
        let width = 3_000
        let height = 2_000
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let png = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let jpeg = try XCTUnwrap(AttachmentImageProcessing.jpegData(from: png as Data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(output.width, output.height), AttachmentImageProcessing.maximumPixelSize)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }
}
