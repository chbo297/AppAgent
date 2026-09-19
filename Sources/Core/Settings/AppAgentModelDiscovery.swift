//
//  AppAgentModelDiscovery.swift
//  AppAgent
//
//  探索一个接口：先按协议并行拉取「接口声明支持的模型」，再对每个「模型 × 协议」候选
//  并行发一次最小流式请求，验证真实可用性并测量首 token 时延。
//  OpenAI 兼容：GET {base}/models   + POST {base}/chat/completions
//  Anthropic ：GET {base}/v1/models + POST {base}/v1/messages
//  base 已以 /v1 结尾时（OneAPI 等网关）不再重复追加 /v1。
//

import Foundation

/// 「模型 × 协议」候选。同一模型 id 若两种协议都声明支持，则产生两个候选，各自独立勾选与排序。
public struct AppAgentModelCandidate: Sendable, Hashable {
    public var modelId: String
    public var apiProtocol: APIProtocol

    public init(modelId: String, apiProtocol: APIProtocol) {
        self.modelId = modelId
        self.apiProtocol = apiProtocol
    }
}

/// 单个候选的真实可用性探测结果。
public struct AppAgentModelAvailability: Sendable {
    public var candidate: AppAgentModelCandidate
    public var isAvailable: Bool
    /// 首 token 返回时长（秒）；不可用时为 nil。
    public var firstTokenLatency: TimeInterval?
    /// 不可用原因（面向用户的短文案）。
    public var failureReason: String?

    public init(
        candidate: AppAgentModelCandidate,
        isAvailable: Bool,
        firstTokenLatency: TimeInterval? = nil,
        failureReason: String? = nil
    ) {
        self.candidate = candidate
        self.isAvailable = isAvailable
        self.firstTokenLatency = firstTokenLatency
        self.failureReason = failureReason
    }
}

public enum AppAgentModelDiscovery {

    /// 设置页会探查的协议：OpenAI Chat Completions 与 Anthropic Messages。
    public static let defaultCandidateProtocols: [APIProtocol] = [.openaiCompletions, .anthropicMessages]

    public enum DiscoveryError: LocalizedError {
        case noProtocols
        case invalidURL
        case http(status: Int, body: String)
        case emptyResult
        case transport(String)
        case timeout
        case noContent

        public var errorDescription: String? {
            switch self {
            case .noProtocols: return "没有可探查的协议"
            case .invalidURL: return "接口地址无效"
            case .http(let status, _): return "HTTP \(status)"
            case .emptyResult: return "未能从该接口获取到模型列表"
            case .transport(let msg): return "网络失败：\(msg)"
            case .timeout: return "超时"
            case .noContent: return "无内容返回"
            }
        }
    }

    // MARK: - 接口声明支持的模型

    /// 并行探查候选协议，返回「探查成功（返回了非空模型列表）的协议 + 其声明支持的模型 id」。
    /// 全部协议都失败时抛出最后一个错误。
    public static func probeProtocols(
        baseURL: String,
        apiKey: String,
        candidateProtocols: [APIProtocol] = defaultCandidateProtocols,
        customHeaders: [String: String]
    ) async throws -> [(apiProtocol: APIProtocol, modelIDs: [String])] {
        guard !candidateProtocols.isEmpty else { throw DiscoveryError.noProtocols }

        // 并行拉取；结果按 candidateProtocols 的顺序归位，避免返回顺序抖动。
        var outcomes: [APIProtocol: Result<[String], Error>] = [:]
        await withTaskGroup(of: (APIProtocol, Result<[String], Error>).self) { group in
            for proto in candidateProtocols {
                group.addTask {
                    do {
                        let ids = try await fetchModelIDs(
                            baseURL: baseURL, apiKey: apiKey, apiProtocol: proto, customHeaders: customHeaders
                        )
                        return (proto, .success(ids))
                    } catch {
                        return (proto, .failure(error))
                    }
                }
            }
            for await (proto, result) in group { outcomes[proto] = result }
        }

        var results: [(apiProtocol: APIProtocol, modelIDs: [String])] = []
        var lastError: Error?
        for proto in candidateProtocols {
            switch outcomes[proto] {
            case .success(let ids) where !ids.isEmpty:
                results.append((apiProtocol: proto, modelIDs: ids))
            case .success:
                lastError = DiscoveryError.emptyResult
                Logger.warning("ModelDiscovery", "protocol \(proto.rawValue): empty model list")
            case .failure(let error):
                lastError = error
                Logger.warning("ModelDiscovery", "protocol \(proto.rawValue) failed: \(error)")
                AppAgentDebugLog.shared.record(
                    .failure,
                    message: "拉取模型列表失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                    apiProtocol: proto.rawValue
                )
            case nil:
                break
            }
        }
        if results.isEmpty { throw lastError ?? DiscoveryError.emptyResult }
        return results
    }

    /// 探查并展平为「模型 × 协议」候选列表（按协议顺序、组内保持接口返回顺序）。
    public static func discoverCandidates(
        baseURL: String,
        apiKey: String,
        candidateProtocols: [APIProtocol] = defaultCandidateProtocols,
        customHeaders: [String: String]
    ) async throws -> [AppAgentModelCandidate] {
        let groups = try await probeProtocols(
            baseURL: baseURL, apiKey: apiKey, candidateProtocols: candidateProtocols, customHeaders: customHeaders
        )
        return groups.flatMap { group in
            group.modelIDs.map { AppAgentModelCandidate(modelId: $0, apiProtocol: group.apiProtocol) }
        }
    }

    // MARK: - 真实可用性 + 首 token 时延

    /// 对单个候选发一次最小流式请求（"hi"，max_tokens 很小），验证真实可用性并测首 token 时延。
    public static func probeAvailability(
        candidate: AppAgentModelCandidate,
        baseURL: String,
        apiKey: String,
        customHeaders: [String: String],
        contextWindow: Int,
        maxTokens: Int,
        timeout: TimeInterval = 20
    ) async -> AppAgentModelAvailability {
        let spec = ModelSpec(
            id: candidate.modelId,
            reasoning: false,
            inputModalities: ["text"],
            contextWindow: contextWindow,
            maxTokens: maxTokens
        )
        let provider = AnthropicProvider(
            baseURL: baseURL,
            apiKey: apiKey,
            apiProtocol: candidate.apiProtocol,
            customHeaders: customHeaders,
            models: [spec],
            requestTimeout: timeout,
            defaultRequestMaxTokens: probeMaxTokens
        )

        do {
            let latency = try await withTimeout(timeout) {
                let start = Date()
                let stream = provider.streamCompletion(
                    messages: [.user("hi")], system: [], tools: [], modelId: candidate.modelId
                )
                for try await event in stream {
                    switch event {
                    case .textDelta(let text) where !text.isEmpty:
                        return Date().timeIntervalSince(start)
                    case .toolCall, .done:
                        return Date().timeIntervalSince(start)
                    default:
                        continue
                    }
                }
                throw DiscoveryError.noContent
            }
            return AppAgentModelAvailability(candidate: candidate, isAvailable: true, firstTokenLatency: latency)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Logger.warning(
                "ModelDiscovery",
                "probe \(candidate.modelId)@\(candidate.apiProtocol.rawValue) unavailable: \(reason)"
            )
            AppAgentDebugLog.shared.record(
                .failure,
                message: "可用性实测失败：\(reason)",
                apiProtocol: candidate.apiProtocol.rawValue,
                modelId: candidate.modelId
            )
            return AppAgentModelAvailability(candidate: candidate, isAvailable: false, failureReason: reason)
        }
    }

    /// 并行测试全部候选（默认最多 6 个在飞），每个候选一有结果就回调一次，便于 UI 逐个点亮。
    @discardableResult
    public static func probeAvailability(
        candidates: [AppAgentModelCandidate],
        baseURL: String,
        apiKey: String,
        customHeaders: [String: String],
        contextWindow: Int,
        maxTokens: Int,
        timeout: TimeInterval = 20,
        maxConcurrent: Int = 8,
        onResult: @escaping @Sendable (AppAgentModelAvailability) -> Void = { _ in }
    ) async -> [AppAgentModelAvailability] {
        guard !candidates.isEmpty else { return [] }
        var results: [AppAgentModelAvailability] = []
        await withTaskGroup(of: AppAgentModelAvailability.self) { group in
            var next = 0
            let limit = min(max(1, maxConcurrent), candidates.count)
            while next < limit {
                let candidate = candidates[next]
                group.addTask {
                    await probeAvailability(
                        candidate: candidate, baseURL: baseURL, apiKey: apiKey, customHeaders: customHeaders,
                        contextWindow: contextWindow, maxTokens: maxTokens, timeout: timeout
                    )
                }
                next += 1
            }
            while let result = await group.next() {
                results.append(result)
                onResult(result)
                guard next < candidates.count else { continue }
                let candidate = candidates[next]
                group.addTask {
                    await probeAvailability(
                        candidate: candidate, baseURL: baseURL, apiKey: apiKey, customHeaders: customHeaders,
                        contextWindow: contextWindow, maxTokens: maxTokens, timeout: timeout
                    )
                }
                next += 1
            }
        }
        return results
    }

    // MARK: - 内部实现

    /// 可用性探测请求的输出上限：只要看到首 token 即可判定，无需让模型写完。
    private static let probeMaxTokens = 16

    private static func fetchModelIDs(
        baseURL: String,
        apiKey: String,
        apiProtocol: APIProtocol,
        customHeaders: [String: String]
    ) async throws -> [String] {
        guard let url = modelsURL(baseURL: baseURL, apiProtocol: apiProtocol) else {
            throw DiscoveryError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if apiProtocol == .anthropicMessages {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // OneAPI 等网关的 Anthropic 兼容入口只认 Bearer，两种都带上。
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.transport("invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DiscoveryError.http(status: http.statusCode, body: String(body.prefix(500)))
        }
        return parseModelIDs(from: data)
    }

    /// models 列表 URL：OpenAI 系 `{base}/models`；Anthropic `{base}/v1/models`，
    /// 但 base 已以 `/v1` 结尾时（OneAPI 等网关）不再重复追加。
    static func modelsURL(baseURL: String, apiProtocol: APIProtocol) -> URL? {
        let base = normalizedBase(baseURL)
        guard !base.isEmpty else { return nil }
        guard apiProtocol == .anthropicMessages else { return URL(string: base + "/models") }
        return URL(string: base.hasSuffix("/v1") ? base + "/models" : base + "/v1/models")
    }

    /// 去掉末尾斜杠与首尾空白。
    static func normalizedBase(_ baseURL: String) -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// 解析模型 id：兼容 `{ "data": [ {"id": ...} ] }` 与顶层数组两种形态。
    private static func parseModelIDs(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let array: [Any]
        if let obj = root as? [String: Any], let dataArray = obj["data"] as? [Any] {
            array = dataArray
        } else if let topArray = root as? [Any] {
            array = topArray
        } else {
            return []
        }
        return array.compactMap { element in
            if let dict = element as? [String: Any], let id = dict["id"] as? String { return id }
            if let str = element as? String { return str }
            return nil
        }
    }

    /// URLSession 请求。用 `data(for:)` 而不是手写 dataTask + continuation：前者
    /// 响应 Task 取消，`withTimeout` 里输掉的那一路才能真的把请求带走。
    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw DiscoveryError.transport(error.localizedDescription)
        }
    }

    /// 给一段异步操作加超时：先完成者胜出，另一方取消。
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DiscoveryError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw DiscoveryError.timeout }
            return result
        }
    }


}

