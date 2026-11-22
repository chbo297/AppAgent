//
//  AIAgentError.swift
//  AppAgent
//

import Foundation

/// 模型请求边界保存的安全网络诊断；工具错误不经过此类型。
struct ModelNetworkError: Error, LocalizedError, Sendable {
    let host: String
    let detail: String
    let domain: String
    let code: Int

    init?(_ error: Error, baseURL: String, secrets: [String] = []) {
        let underlying = error as NSError
        guard underlying.domain == NSURLErrorDomain,
              underlying.code != NSURLErrorCancelled else {
            return nil
        }
        let failingURL = underlying.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let failingURLString = underlying.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
        host = Self.hostOnly(failingURL?.absoluteString)
            ?? Self.hostOnly(failingURLString)
            ?? Self.hostOnly(baseURL)
            ?? "未知 Host"
        detail = Self.redact(underlying.localizedDescription, secrets: secrets)
        domain = underlying.domain
        code = underlying.code
    }

    var errorDescription: String? {
        "模型请求失败（Host: \(host)）\n\(detail)\n\(domain) / \(code)\n网络错误，请稍后重试。"
    }

    private static func hostOnly(_ value: String?) -> String? {
        guard let value, let host = URLComponents(string: value)?.host, !host.isEmpty,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\@?#%")
                .union(.whitespacesAndNewlines)) == nil else {
            return nil
        }
        return host
    }

    private static func redact(_ description: String, secrets: [String]) -> String {
        var result = description
        // 仅保留 URL 的 Host；包括重定向地址，不能把路径、凭据或查询参数带入历史。
        let pattern = #"(?i)(?:[a-z][a-z0-9+.-]*://|//)[^\s<>"“”‘’；。，！？（）]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else {
                    continue
                }
                let replacement = hostOnly(String(result[range])) ?? "[URL 已隐藏]"
                result.replaceSubrange(range, with: replacement)
            }
        }
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        return result
    }
}

/// Errors from the agent execution layer.
public enum AIAgentError: Error, LocalizedError, Sendable {
    case maxIterationsReached(limit: Int)
    case toolNotFound(String)
    case toolExecutionFailed(toolName: String, underlying: Error)
    case sessionNotFound(String)
    case cancelled
    case sessionReleased
    case toolExecutionDenied(String)
    case toolLoopDetected(String)
    case toolExecutionTimedOut(toolName: String)
    case concurrencyLimitReached(limit: Int)
    /// 本轮结束了却没产出任何结果或错误（执行流有出口漏发终止事件）。
    /// 兜底用：宁可报一个「异常结束」，也不能让界面永远停在「进行中」。
    case runEndedWithoutResult

    public var errorDescription: String? {
        switch self {
        case .maxIterationsReached(let limit):
            return "AIAgent loop exceeded maximum(\(limit)) iterations"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .toolExecutionFailed(let name, let error):
            return "Tool '\(name)' failed: \(error.localizedDescription)"
        case .sessionNotFound(let id):
            return "AISession not found: \(id)"
        case .cancelled:
            return "Operation cancelled"
        case .sessionReleased:
            return "AISession was released during execution"
        case .toolExecutionDenied(let name):
            return "User denied execution of tool '\(name)'"
        case .toolLoopDetected(let name):
            return "Tool loop detected: '\(name)' called repeatedly with identical arguments"
        case .toolExecutionTimedOut(let name):
            return "Tool '\(name)' execution timed out"
        case .concurrencyLimitReached(let limit):
            return "已达并行上限(\(limit))，请先暂停其他任务再重试。"
        case .runEndedWithoutResult:
            return "本轮异常结束（没有收到模型结果，也没有明确错误），请重试。"
        }
    }
}

/// Errors from the model provider layer.
public enum ModelError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    /// 模型这次吐出的工具调用残缺（参数不是 JSON 对象 / 缺名称）。还没有任何工具执行，
    /// 重发同一请求通常就能拿到完整调用，所以和 `decodingError` 分开归类为可重试。
    case malformedToolCall(String)
    case providerError(String)
    /// HTTP 200 流中携带的上游错误。兼容网关会把这类错误包装成 SSE 数据返回。
    case upstreamError(type: String?, code: String? = nil, message: String)
    /// 流在 `idleSeconds` 秒内一个字节都没来，被空闲看门狗判死（见 `StreamIdleGuard`）。
    /// 典型成因是 App 切后台被冻结、连接已断但 URLSession 既不吐数据也不报错。
    case streamStalled(idleSeconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .httpError(let code, let body):
            return "模型服务请求失败（HTTP \(code)）\n服务端返回：\(body)"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        case .malformedToolCall(let msg):
            return "模型返回的工具调用不完整：\(msg)"
        case .providerError(let msg):
            return "Provider error: \(msg)"
        case .upstreamError(let type, let code, let message):
            let identifiers = [type, code].compactMap {
                $0
            }.filter {
                !$0.isEmpty
            }.joined(separator: "/")
            if !identifiers.isEmpty {
                return "模型服务上游错误（\(identifiers)）：\(message)"
            }
            return "模型服务上游错误：\(message)"
        case .streamStalled(let idleSeconds):
            return String(format: "模型响应中断（%.0fs 没有新内容），正在重试。", idleSeconds)
        }
    }
}
