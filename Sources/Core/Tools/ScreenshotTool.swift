//
//  ScreenshotTool.swift
//  AppAgent
//
//  取代原来的 `vision_analyze`。那个工具的名字和职责都不贴 AppAgent 的场景：
//  它要宿主注入一个 VisionAnalyzeProvider 才能用，语义是「分析一张外部图片」，
//  而跑在 app 里的 agent 真正需要的原语是「看一眼我自己现在长什么样」。
//
//  对标 Codex 的 `view_image`：抓帧 → 落盘 → 返回路径与尺寸。
//
//  当前只落盘不内联：`Tool.Output` 还没有 image 分支，provider mapper 也还不会把
//  图片映射成多模态 content block，硬塞 base64 会被工具输出预算截断成废数据。
//  落盘这一步本身有用（宿主 UI 能展示、能喂给识图服务、人能直接看），也是将来接
//  多模态通道的必要前置。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct ScreenshotTool: ToolProtocol {
    public let name = "screenshot"
    public let description = """
        Capture what the app looks like right now and look at it. Renders a window (or one \
        view) to a PNG and returns it as an image the model can see, plus the pixel size. \
        Omit 'path' for the key window; pass a view path from app_runtime_inspect \
        ("0/2/1", or "W1:0/2/1" for another window) to capture just that view. \
        'maxWidth' bounds the pixel width (default 1024) — lower it when you only need the layout. \
        Set 'save_as_file'=true to write the PNG into the workspace instead of attaching it, \
        which avoids spending tokens on pixels you do not need to see. \
        Use this when the view hierarchy text is not enough to judge layout, spacing or styling.
        """
    public let parameters = Tool.Schema(
        properties: [
            "path": .string(description: "View path to capture. Omit for the whole key window."),
            "maxWidth": .integer(description: "Downscale so the image is at most this many PIXELS wide (default 1024). Keeps files small on 3x screens.",
                                 minimum: 64, maximum: 4096, defaultValue: .number(1024)),
            "save_as_file": .boolean(description: "Write the PNG to the workspace and return its path instead of attaching the image.",
                                     defaultValue: .bool(false)),
            "name": .string(description: "Optional file name stem when saving; a timestamp is used otherwise.")
        ],
        required: []
    )
    public let group = "host-runtime"
    public let safetyLevel: Tool.SafetyLevel = .safe

    /// 截图目录，相对沙箱 Documents。
    public static let directoryName = "AppAgentScreenshots"

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        #if canImport(UIKit)
        let requestedPath = arguments["path"]?.stringValue
        let maxPixelWidth = CGFloat(arguments["maxWidth"]?.numberValue ?? 1024)
        let stem = arguments["name"]?.stringValue

        let capture: (image: UIImage, source: String)? = await MainActor.run {
            let target: UIView?
            let source: String
            if let requestedPath, !requestedPath.isEmpty, requestedPath != "root" {
                target = DefaultRuntimeInspectProvider.view(atPath: requestedPath)
                source = requestedPath
            } else {
                target = DefaultRuntimeInspectProvider.keyWindow()
                source = "keyWindow"
            }
            guard let view = target, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            return (Self.render(view, maxPixelWidth: maxPixelWidth), source)
        }

        guard let capture else {
            if let requestedPath, !requestedPath.isEmpty {
                return .error("No view at path '\(requestedPath)', or it has zero size.")
            }
            return .error("No key window to capture.")
        }

        guard let data = capture.image.pngData() else {
            return .error("Failed to encode the capture as PNG.")
        }

        let scale = capture.image.scale
        let pixels = String(format: "%.0f×%.0f", capture.image.size.width * scale,
                            capture.image.size.height * scale)

        // 默认把图片附给模型看；显式要求才落盘（省 token 或留档时用）。
        guard arguments["save_as_file"]?.boolValue == true else {
            guard data.count <= Self.maxAttachmentBytes else {
                return .error("Capture is \(data.count) bytes, over the \(Self.maxAttachmentBytes)-byte "
                              + "inline limit. Lower 'maxWidth' or pass save_as_file=true.")
            }
            return .image(Tool.ImageOutput(
                data: data,
                mediaType: "image/png",
                caption: "Screenshot of \(capture.source), \(pixels) px"
            ))
        }

        do {
            let url = try Self.destination(stem: stem)
            try data.write(to: url, options: .atomic)
            return .json(.object([
                "path": .string("Documents/\(Self.directoryName)/\(url.lastPathComponent)"),
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
    /// 抓帧。用 `drawHierarchy` 而不是 `layer.render`，后者画不出 visual effect view
    /// 和部分系统渲染的内容。`maxWidth` 按**像素**算：3x 屏上 402pt 就是 1206px，
    /// 按点算等于没有上限，文件会几百 KB。
    @MainActor
    private static func render(_ view: UIView, maxPixelWidth: CGFloat) -> UIImage {
        let bounds = view.bounds
        let native = UIScreen.main.scale
        let nativePixels = bounds.width * native
        let ratio = maxPixelWidth > 0 && nativePixels > maxPixelWidth ? maxPixelWidth / nativePixels : 1

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(0.1, native * ratio)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }

    private static func destination(stem: String?) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ScreenshotTool", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No Documents directory."])
        }
        let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeStem: String
        if let stem, !stem.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            safeStem = String(stem.unicodeScalars.filter { allowed.contains($0) })
        } else {
            safeStem = ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = safeStem.isEmpty ? "shot-\(formatter.string(from: Date()))" : safeStem
        return directory.appendingPathComponent("\(base).png")
    }
    #endif
}
