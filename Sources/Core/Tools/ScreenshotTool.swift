//
//  ScreenshotTool.swift
//  AppAgent
//
//  取代原来的 `vision_analyze`。那个工具的名字和职责都不贴 AppAgent 的场景：
//  它要宿主注入一个 VisionAnalyzeProvider 才能用，语义是「分析一张外部图片」，
//  而跑在 app 里的 agent 真正需要的原语是「看一眼我自己现在长什么样」。
//
//  默认内联图片，按需落盘。目标解析、像素采集均受不可变的 inspection context 约束。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct ScreenshotTool: ToolProtocol {
    public let name = "screenshot"
    public let description = """
        Capture one window/view as a PNG; never composites windows. Defaults to host scope and \
        the session scene's scoped window. Use app_runtime_inspect paths for a subtree. \
        appagent/all require approval. Limited scopes reject mixed ownership and backdrop effects. \
        save_as_file returns a saved path instead of an inline image; SDK/all captures go to SDK diagnostics.
        """
    public let parameters = Tool.Schema(
        properties: [
            "scope": HostInspectionScope.parameter,
            "path": .string(description: "View path to capture. Omit for the scoped default window. W<n> are stable window handles."),
            "maxWidth": .integer(description: "Downscale so the image is at most this many PIXELS wide (default 1024). Keeps files small on 3x screens.",
                                 minimum: 64, maximum: 4096, defaultValue: .number(1024)),
            "save_as_file": .boolean(description: "Save the PNG and return its path instead of attaching it.",
                                     defaultValue: .bool(false)),
            "name": .string(description: "Optional file stem: letters, digits, '-' or '_'. Defaults to a timestamp.")
        ],
        required: []
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .safe

    /// Host-only 截图目录，相对沙箱 Documents；SDK/all 产物不得写入这里。
    public static let directoryName = "AppAgentScreenshots"

    public init() {}

    public func safetyLevel(for arguments: [String: JSONValue]) -> Tool.SafetyLevel {
        arguments["save_as_file"]?.boolValue == true ? .moderate : .safe
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        let savesFile = arguments["save_as_file"]?.boolValue == true
        let context: HostInspectionContext
        do {
            // Enforce readOnly here too: callers can invoke tools without LLMExecutor.
            context = try await HostInspectionAccess.context(
                arguments: arguments, session: session, tool: name, isMutation: savesFile
            )
        } catch {
            return .error(error.localizedDescription)
        }
        #if canImport(UIKit)
        let requestedPath = arguments["path"]?.stringValue
        let maxPixelWidth = CGFloat(arguments["maxWidth"]?.numberValue ?? 1024)
        let stem = arguments["name"]?.stringValue

        let capture: (image: UIImage, source: String)
        do {
            capture = try await MainActor.run {
                // Validate the scene before resolving any target, with a useful ambiguity error.
                _ = try HostInspectionUIKit.activeScene(context: context)
                let path = requestedPath ?? "root"
                guard let view = DefaultRuntimeInspectProvider.view(atPath: path, context: context) else {
                    throw UIKitInspectionError.outsideScope
                }
                let source = DefaultRuntimeInspectProvider.addressablePath(of: view, context: context) ?? path
                return (try Self.render(view, maxPixelWidth: maxPixelWidth, context: context), source)
            }
        } catch {
            return .error(error.localizedDescription)
        }

        guard let data = capture.image.pngData() else {
            return .error("Failed to encode the capture as PNG.")
        }

        let scale = capture.image.scale
        let pixels = String(format: "%.0f×%.0f", capture.image.size.width * scale,
                            capture.image.size.height * scale)

        // 默认把图片附给模型看；显式要求才落盘（省 token 或留档时用）。
        guard savesFile else {
            guard data.count <= Self.maxAttachmentBytes else {
                return .error("Capture is \(data.count) bytes, over the \(Self.maxAttachmentBytes)-byte "
                              + "inline limit. Lower 'maxWidth' or pass save_as_file=true.")
            }
            return .image(Tool.ImageOutput(
                data: data,
                mediaType: "image/png",
                caption: "Screenshot of \(capture.source), scope=\(context.scope.rawValue), \(pixels) px"
            ))
        }

        do {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw StorageError.noDocuments
            }
            let url = try Self.save(data, stem: stem, scope: context.scope, documents: documents)
            return .json(.object([
                "path": .string("Documents/\(Self.storageDirectory(for: context.scope))/\(url.lastPathComponent)"),
                "absolute_path": .string(url.path),
                "source": .string(capture.source),
                "pixels": .string(pixels),
                "points": .string(String(format: "%.0f×%.0f@%.0fx",
                                         capture.image.size.width, capture.image.size.height, scale)),
                "bytes": .number(Double(data.count))
            ]))
        } catch {
            return .error("Failed to save the capture: \(error.localizedDescription)")
        }
        #else
        return .error("screenshot is only available on UIKit platforms.")
        #endif
    }

    /// 内联给模型的上限。再大就该落盘或降 maxWidth —— base64 之后还要涨 4/3。
    static let maxAttachmentBytes = 3 * 1024 * 1024

    #if canImport(UIKit)
    /// Limited scope uses only the target's layer subtree and rejects mixed ownership before
    /// rendering. drawHierarchy can sample backdrop/other UI; reserve it for authorized all scope.
    @MainActor
    static func render(
        _ view: UIView, maxPixelWidth: CGFloat, context: HostInspectionContext = .init()
    ) throws -> UIImage {
        if let rejection = HostInspectionUIKit.screenshotRejection(for: view, context: context) {
            throw NSError(domain: "ScreenshotTool", code: 2, userInfo: [NSLocalizedDescriptionKey: rejection])
        }
        let bounds = view.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              maxPixelWidth.isFinite, maxPixelWidth > 0 else {
            throw NSError(domain: "ScreenshotTool", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Screenshot target has invalid/zero size or maxWidth."])
        }
        let native = view.window?.screen.scale ?? UIScreen.main.scale
        let nativePixels = bounds.width * native
        let ratio = maxPixelWidth > 0 && nativePixels > maxPixelWidth ? maxPixelWidth / nativePixels : 1

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = native * ratio
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            if context.scope == .all {
                view.drawHierarchy(in: CGRect(origin: .zero, size: bounds.size), afterScreenUpdates: false)
            } else {
                renderer.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                view.layer.render(in: renderer.cgContext)
            }
        }
        // Discard the entire image if synchronous rendering callbacks changed ownership.
        if let rejection = HostInspectionUIKit.screenshotRejection(for: view, context: context) {
            throw NSError(domain: "ScreenshotTool", code: 2, userInfo: [NSLocalizedDescriptionKey: rejection])
        }
        return image
    }
    #endif

    // Foundation-only helpers: native Core tests inject an isolated Documents directory.
    static func storageDirectory(for scope: HostInspectionScope) -> String {
        switch scope {
        case .host: return directoryName
        case .appagent, .all: return "AppAgent/diagnostics/screenshots"
        }
    }

    static func destination(stem: String?, scope: HostInspectionScope, documents: URL) throws -> URL {
        try prepareDestination(stem: stem, scope: scope, canonicalDocuments: canonicalDocuments(documents))
    }

    static func save(_ data: Data, stem: String?, scope: HostInspectionScope, documents: URL) throws -> URL {
        // Pin the trusted root once. Re-resolving it after mkdir/write could bless a new redirect.
        let root = try canonicalDocuments(documents)
        let url = try prepareDestination(stem: stem, scope: scope, canonicalDocuments: root)
        try validateDestination(url, below: root, directoriesMustExist: true)
        try data.write(to: url, options: .atomic)
        try validateDestination(url, below: root, directoriesMustExist: true, fileMustExist: true)
        return url
    }

    private static func canonicalDocuments(_ documents: URL) throws -> URL {
        guard documents.isFileURL else { throw StorageError.noDocuments }
        // Permit the system-provided Documents prefix's aliases (e.g. /var -> /private/var),
        // but never canonicalize the relative screenshot directory into a different location.
        let root = documents.resolvingSymlinksInPath().standardizedFileURL
        try validateNode(root, type: .typeDirectory, mayBeMissing: false)
        return root
    }

    private static func prepareDestination(
        stem: String?, scope: HostInspectionScope, canonicalDocuments root: URL
    ) throws -> URL {
        let base: String
        if let stem, !stem.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            // Reject path syntax rather than silently rewriting "..", separators or encoded paths.
            guard stem.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw StorageError.invalidName
            }
            base = stem
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            base = "shot-\(formatter.string(from: Date()))"
        }
        let directory = root.appendingPathComponent(storageDirectory(for: scope), isDirectory: true)
        let url = directory.appendingPathComponent("\(base).png", isDirectory: false)
        // Check all components, including an existing/dangling file link, BEFORE any mkdir.
        try validateDestination(url, below: root, directoriesMustExist: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateDestination(url, below: root, directoriesMustExist: true)
        return url
    }

    private static func validateDestination(
        _ url: URL, below root: URL, directoriesMustExist: Bool, fileMustExist: Bool = false
    ) throws {
        if let denial = SessionRepositoryProtection.mutationDenial(logical: url, resolved: url) {
            throw NSError(domain: "ScreenshotStorage", code: 403,
                          userInfo: [NSLocalizedDescriptionKey: denial])
        }
        let components = url.pathComponents
        let prefix = root.pathComponents
        guard components.starts(with: prefix), components.count > prefix.count else {
            throw StorageError.unsafeDestination
        }
        try validateNode(root, type: .typeDirectory, mayBeMissing: false)
        var directory = root
        for component in components.dropFirst(prefix.count).dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
            try validateNode(directory, type: .typeDirectory, mayBeMissing: !directoriesMustExist)
        }
        try validateNode(url, type: .typeRegular, mayBeMissing: !fileMustExist)
    }

    private static func validateNode(_ url: URL, type: FileAttributeType, mayBeMissing: Bool) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else {
            throw StorageError.unsafeDestination
        }
        do {
            // attributesOfItem inspects the link itself, also catching dangling/self-referential
            // links for which fileExists or resolvingSymlinksInPath alone is insufficient.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == type else {
                throw StorageError.unsafeDestination
            }
        } catch let error as NSError where mayBeMissing && error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return
        }
    }

    // These pre/post checks reject existing redirections; Foundation path APIs do not provide
    // a filesystem transaction against hostile concurrent rename/symlink swaps by host code.
    private enum StorageError: Error, LocalizedError {
        case noDocuments, invalidName, unsafeDestination

        var errorDescription: String? {
            switch self {
            case .noDocuments: return "No Documents directory."
            case .invalidName: return "Invalid screenshot name. Use only letters, digits, '-' or '_'."
            case .unsafeDestination: return "Inspection denied: screenshot destination is redirected or is not a regular file/directory."
            }
        }
    }
}
