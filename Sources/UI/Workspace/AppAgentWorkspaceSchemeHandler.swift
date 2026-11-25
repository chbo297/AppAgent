#if canImport(UIKit) || (canImport(AppKit) && canImport(WebKit))
import Foundation
import WebKit

/// 每个 document 独享一个 handler 和 origin；从不访问文件系统或网络。
final class AppAgentWorkspaceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app-workspace"
    let documentID = UUID().uuidString.lowercased()
    let documentURL: URL
    private var resources: [String: Data]
    private let policy: String

    init(content: AppAgentWorkspaceH5Content) {
        documentURL = URL(string: "\(Self.scheme)://\(documentID)/index.html")!
        let origin = "\(Self.scheme)://\(documentID)"
        policy = "default-src 'none'; script-src \(origin) 'unsafe-inline'; "
            + "style-src \(origin) 'unsafe-inline'; img-src \(origin) data:; "
            + "connect-src \(origin); font-src 'none'; media-src 'none'; "
            + "frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; "
            + "base-uri 'none'; form-action 'none'"
        let background = content.hasSlot ? "transparent" : "#ffffff"
        let prefix = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(Self.escapedPolicy(policy))">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>
        html, body {
            background: \(background); min-height: 100%;
        }
        </style></head>
        """
        resources = content.resources.mapValues { text in
            Data(text.utf8)
        }
        resources["index.html"] = Data((prefix + content.html + "</html>").utf8)
        super.init()
    }

    func invalidate() {
        resources.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == documentID,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              urlSchemeTask.request.httpMethod == "GET",
              components.percentEncodedPath.hasPrefix("/") else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let path = String(components.percentEncodedPath.dropFirst())
        guard SessionWorkspaceLimits.isValidPath(path),
              url.absoluteString == "\(Self.scheme)://\(documentID)/\(path)",
              let data = resources[path],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: [
                                                "Content-Type": "\(AppAgentWorkspaceH5Content.mimeType(path)); charset=utf-8",
                                                "Content-Security-Policy": policy,
                                                "X-Content-Type-Options": "nosniff",
                                                "Cache-Control": "no-store",
                                                "Referrer-Policy": "no-referrer"
                                             ]) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // start 同步完成，没有异步任务或文件句柄需要取消。
    }

    private static func escapedPolicy(_ policy: String) -> String {
        AppAgentWorkspaceH5Content.escape(policy)
    }
}

#endif
