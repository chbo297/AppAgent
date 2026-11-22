//
//  AppAgentAttachmentPicker.swift
//  AppAgentUI
//
//  加号面板两项能力背后的系统选择器：
//   - 图片：PHPicker（独立进程，只拿用户选中的那几张，不需要相册权限，也不用加 Info.plist 文案）；
//   - 文件：系统文件选择器，以副本方式打开，再拷进 agent 工作区。
//

#if canImport(UIKit)
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class AppAgentAttachmentPicker: NSObject {
    weak var presenter: UIViewController?
    /// 文件附件落到哪个工作区；由控制器按当前 agent 的文件资源给出。
    var workspaceRoot: () -> URL? = {
        nil
    }
    var onPicked: (([AIAgentMessage.Attachment]) -> Void)?
    var onError: ((String) -> Void)?

    func present(_ source: AppAgentInputBarAttachmentSource, remainingImageSlots: Int) {
        guard let presenter, presenter.presentedViewController == nil else {
            return
        }
        switch source {
        case .photoLibrary:
            guard remainingImageSlots > 0 else {
                onError?("最多只能选 \(AppAgentInputBar.maximumImageAttachmentCount) 张图片。")
                return
            }
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = remainingImageSlots
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            presenter.present(picker, animated: true)
        case .file:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            presenter.present(picker, animated: true)
        }
    }

    /// 读图 → 缩放压缩（后台）→ 造附件，保持用户选择的顺序；读失败的那张跳过并提示。
    private func loadImages(from providers: [NSItemProvider]) async {
        var attachments: [AIAgentMessage.Attachment] = []
        var failedCount = 0
        for provider in providers {
            guard let data = await Self.loadImageData(from: provider) else {
                failedCount += 1
                continue
            }
            let jpeg = await Task.detached(priority: .userInitiated) {
                AttachmentImageProcessing.jpegData(from: data)
            }.value
            guard let jpeg else {
                failedCount += 1
                continue
            }
            let attachment = AIAgentMessage.Attachment.image(
                jpegData: jpeg,
                name: provider.suggestedName.map { name in
                    name + ".jpg"
                } ?? "image.jpg"
            )
            // 缩略图先放进缓存：附件条与气泡都按 id 取，不必再从 base64 解一遍。
            if let thumbnail = AppAgentAttachmentImageCache.downsample(jpeg, maxPixelSize: 240) {
                AppAgentAttachmentImageCache.shared.store(thumbnail, for: attachment.id)
            }
            attachments.append(attachment)
        }
        if !attachments.isEmpty {
            onPicked?(attachments)
        }
        if failedCount > 0 {
            onError?("有 \(failedCount) 张图片读取失败，已跳过。")
        }
    }

    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        let type = UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func stageFile(at url: URL) async {
        guard let root = workspaceRoot() else {
            onError?(AttachmentFileStaging.StagingError.unreadable.localizedDescription)
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try AttachmentFileStaging.stage(fileAt: url, workspaceRoot: root)
            }
        }.value
        switch result {
        case .success(let attachment):
            onPicked?([attachment])
        case .failure(let error):
            onError?(error.localizedDescription)
        }
    }
}

extension AppAgentAttachmentPicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider)
        guard !providers.isEmpty else {
            return
        }
        Task {
            await loadImages(from: providers)
        }
    }
}

extension AppAgentAttachmentPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            return
        }
        Task {
            await stageFile(at: url)
        }
    }
}
#endif
