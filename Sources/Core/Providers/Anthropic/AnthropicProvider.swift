//
//  AnthropicProvider.swift
//  AppAgent
//

import Foundation

/// ModelProvider implementation for the Anthropic Messages API.
public final class AnthropicProvider: ModelProvider, @unchecked Sendable {
    public let name = "anthropic"
    public let baseURL: String
    public let apiKey: String
    public let apiProtocol: APIProtocol
    public let customHeaders: [String: String]
    public let models: [ModelSpec]
    public let requestTimeout: TimeInterval
    public let defaultRequestMaxTokens: Int
    private let concurrencyLimiter: ConcurrencyLimiter
    private let session: URLSession

    /// Anthropic API version, managed internally.
    private let apiVersion = "2023-06-01"

    public init(
        baseURL: String,
        apiKey: String,
        apiProtocol: APIProtocol = .anthropicMessages,
        customHeaders: [String: String] = [:],
        models: [ModelSpec],
        requestTimeout: TimeInterval = 300,
        defaultRequestMaxTokens: Int = 4096,
        maxConcurrency: Int = 5
    ) {
        precondition(!models.isEmpty, "AnthropicProvider requires at least one model")
        precondition(defaultRequestMaxTokens > 0, "defaultRequestMaxTokens must be positive")
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiProtocol = apiProtocol
        self.customHeaders = customHeaders
        self.models = models
        self.requestTimeout = requestTimeout
        self.defaultRequestMaxTokens = defaultRequestMaxTokens
        self.concurrencyLimiter = ConcurrencyLimiter(limit: maxConcurrency)
        self.session = Self.makeSession(requestTimeout: requestTimeout)
    }

    /// 每个 provider 自己一条 session，不用 `URLSession.shared`。
    ///
    /// 关键是 `shouldUseExtendedBackgroundIdleMode`：它只能在 configuration 上开，
    /// 作用是请求系统在 App 进入后台时**尽量保住已建立的 TCP 连接**。这是「切后台再回来」
    /// 这条路径上唯一能提高连接存活率的开关，`.shared` 拿不到。
    /// 连接活下来最好，没活下来也不再表现为无限期卡住 —— 由 `StreamIdleGuard` 判死重试。
    ///
    /// `timeoutIntervalForRequest` 与 `buildRequest` 里的 `request.timeoutInterval` 是同一个
    /// 语义（两次无数据之间的上限），两处都写是因为 `URLRequest` 自带 60s 默认值、不写就会
    /// 悄悄盖掉配置；两处取同一个 `requestTimeout`，不许各写一个数。
    private static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.shouldUseExtendedBackgroundIdleMode = true
        configuration.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: configuration)
    }

    /// Stream a completion from the model.
    ///
    /// Full lifecycle:
    /// 1. Acquire a concurrency slot (waits if at limit)
    /// 2. Build the HTTP request via `buildRequest`
    /// 3. Send the request and stream the SSE response
    /// 4. Parse SSE events into `ProviderStreamEvent`s
    /// 5. Release the concurrency slot
    public func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 额度的取与放由 withPermit 配对，提前 return / 抛错都不会漏还。
                    try await self.concurrencyLimiter.withPermit {
                        guard let spec = self.modelSpec(for: modelId) else {
                            throw ModelError.providerError("Model '\(modelId)' not found in provider '\(self.name)'")
                        }
                        try Task.checkCancellation()
                        let requestMaxTokens = min(spec.maxTokens, self.defaultRequestMaxTokens)
                        let request = try self.buildRequest(messages: messages, system: system, tools: tools, modelId: modelId, maxTokens: requestMaxTokens)
                        Logger.info("Anthropic", "streamCompletion: starting, model=\(modelId)")

                        // 最低支持 iOS 15 / macOS 12，`URLSession.bytes` 一定可用——
                        // 原来的 iOS 13/14 delegate 降级路径已随最低版本上调删除。
                        try await self.streamWithBytes(request: request, continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - SSE streaming via URLSession.bytes

    private func streamWithBytes(
        request: URLRequest,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            continuation.finish(throwing: ModelError.invalidResponse)
            return
        }
        Logger.debug("Anthropic", "httpResponse: statusCode=\(httpResponse.statusCode)")

        if !(200..<300).contains(httpResponse.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            Logger.error("Anthropic", "httpError: statusCode=\(httpResponse.statusCode), body=\(body.prefix(500))")
            continuation.finish(throwing: ModelError.httpError(
                statusCode: httpResponse.statusCode, body: body))
            return
        }

        var parser = SSEParser()
        var anthropicToolCalls: [Int: (id: String, name: String, jsonAccumulator: String)] = [:]
        var openAIToolCalls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let sseEvent = parser.processLine(line) {
                // 响应侧的原始 SSE 也要落日志：请求体一直有记录、回来的东西却没有，
                // 于是「模型说 stop=tool_calls 但我们解析出 0 个调用」这种问题在诊断包里
                // 查不到根因（实测遇到过，只能靠猜端点的 tool_calls 格式）。截断防刷爆。
                Logger.debug("Anthropic", "sse<< \(sseEvent.data.prefix(800))")
                for providerEvent in parseProviderSSEEvent(
                    apiProtocol: apiProtocol,
                    sseEvent: sseEvent,
                    anthropicToolCalls: &anthropicToolCalls,
                    openAIToolCalls: &openAIToolCalls) {
                    continuation.yield(providerEvent)
                }
            }
        }

        // Flush remaining SSE data
        if let sseEvent = parser.flush() {
            for providerEvent in parseProviderSSEEvent(
                apiProtocol: apiProtocol,
                sseEvent: sseEvent,
                anthropicToolCalls: &anthropicToolCalls,
                openAIToolCalls: &openAIToolCalls) {
                continuation.yield(providerEvent)
            }
        }

        continuation.finish()
    }

    // MARK: - Private

    /// Build the URLRequest for the Anthropic Messages API.
    ///
    /// Constructs the URL, sets HTTP headers (x-api-key, anthropic-version, Content-Type,
    /// custom headers), and serializes the JSON body using the provided `model` configuration
    /// for model ID and max tokens.
    private func buildRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int
    ) throws -> URLRequest {
        switch apiProtocol {
        case .anthropicMessages:
            return try buildAnthropicMessagesRequest(
                messages: messages,
                system: system,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens
            )
        case .openaiCompletions:
            return try buildOpenAIChatCompletionsRequest(
                messages: messages,
                system: system,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens
            )
        case .openaiResponses:
            return try buildOpenAIResponsesRequest(
                messages: messages,
                system: system,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens
            )
        default:
            throw ModelError.providerError("API protocol '\(apiProtocol.rawValue)' is not implemented")
        }
    }

    private func buildAnthropicMessagesRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int
    ) throws -> URLRequest {
        let effectiveBaseURL = baseURL.isEmpty
            ? "https://api.anthropic.com"
            : baseURL
        let base = effectiveBaseURL.hasSuffix("/")
            ? String(effectiveBaseURL.dropLast())
            : effectiveBaseURL

        // Gateways (OneAPI etc.) are usually configured with a base that already ends in /v1 —
        // don't append a second one.
        let endpoint = base.hasSuffix("/v1/messages")
            ? base
            : (base.hasSuffix("/v1") ? "\(base)/messages" : "\(base)/v1/messages")

        guard let url = URL(string: endpoint) else {
            throw ModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Build request body manually to support cache_control in system/tools
        let anthropicMessages = AnthropicMapper.toAnthropicMessages(messages)
        let systemBlocks = AnthropicMapper.toAnthropicSystem(system)
        let toolsArray = AnthropicMapper.toAnthropicTools(tools)

        let messagesEncoder = JSONEncoder()
        let messagesData = try messagesEncoder.encode(anthropicMessages)
        let messagesJSON = try JSONSerialization.jsonObject(with: messagesData)

        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messagesJSON
        ]

        if !systemBlocks.isEmpty {
            body["system"] = systemBlocks
        }

        // Anthropic API rejects empty tools array
        if !toolsArray.isEmpty {
            body["tools"] = toolsArray
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Log the full request details
        Logger.debug("Anthropic", "buildRequest: url=\(url.absoluteString), model=\(modelId), maxTokens=\(maxTokens), messageCount=\(messages.count), systemSegments=\(system.count), toolCount=\(tools.count)")
        if Logger.isEnabled {
            if let bodyData = request.httpBody,
               let jsonObj = try? JSONSerialization.jsonObject(with: bodyData),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: prettyData, encoding: .utf8) {
                Logger.debug("Anthropic", "buildRequest body:\n\(prettyStr)")
            }
        }

        return request
    }

    private func buildOpenAIChatCompletionsRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int
    ) throws -> URLRequest {
        let effectiveBaseURL = baseURL.isEmpty
            ? "https://api.openai.com/v1"
            : baseURL
        let base = effectiveBaseURL.hasSuffix("/")
            ? String(effectiveBaseURL.dropLast())
            : effectiveBaseURL

        let endpoint = base.hasSuffix("/chat/completions")
            ? base
            : "\(base)/chat/completions"

        guard let url = URL(string: endpoint) else {
            throw ModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let toolDefinitions = OpenAIChatCompletionsMapper.toTools(tools)
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": OpenAIChatCompletionsMapper.toMessages(messages, system: system)
        ]

        if !toolDefinitions.isEmpty {
            body["tools"] = toolDefinitions
            body["tool_choice"] = "auto"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.debug("Anthropic", "buildOpenAIChatCompletionsRequest: url=\(url.absoluteString), model=\(modelId), maxTokens=\(maxTokens), messageCount=\(messages.count), systemSegments=\(system.count), toolCount=\(tools.count)")
        if Logger.isEnabled {
            if let bodyData = request.httpBody,
               let jsonObj = try? JSONSerialization.jsonObject(with: bodyData),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: prettyData, encoding: .utf8) {
                Logger.debug("Anthropic", "buildOpenAIChatCompletionsRequest body:\n\(prettyStr)")
            }
        }

        return request
    }

    private func buildOpenAIResponsesRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int
    ) throws -> URLRequest {
        let effectiveBaseURL = baseURL.isEmpty
            ? "https://api.openai.com/v1"
            : baseURL
        let base = effectiveBaseURL.hasSuffix("/")
            ? String(effectiveBaseURL.dropLast())
            : effectiveBaseURL

        let endpoint = base.hasSuffix("/responses")
            ? base
            : "\(base)/responses"

        guard let url = URL(string: endpoint) else {
            throw ModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        var body: [String: Any] = [
            "model": modelId,
            "max_output_tokens": maxTokens,
            "stream": true,
            "input": OpenAIResponsesMapper.toInput(messages)
        ]

        let instructions = OpenAIResponsesMapper.toInstructions(system)
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }

        let toolDefinitions = OpenAIResponsesMapper.toTools(tools)
        if !toolDefinitions.isEmpty {
            body["tools"] = toolDefinitions
            body["tool_choice"] = "auto"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.debug("Anthropic", "buildOpenAIResponsesRequest: url=\(url.absoluteString), model=\(modelId), maxTokens=\(maxTokens), messageCount=\(messages.count), systemSegments=\(system.count), toolCount=\(tools.count)")
        if Logger.isEnabled {
            if let bodyData = request.httpBody,
               let jsonObj = try? JSONSerialization.jsonObject(with: bodyData),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: prettyData, encoding: .utf8) {
                Logger.debug("Anthropic", "buildOpenAIResponsesRequest body:\n\(prettyStr)")
            }
        }

        return request
    }
}

private func parseProviderSSEEvent(
    apiProtocol: APIProtocol,
    sseEvent: SSEEvent,
    anthropicToolCalls: inout [Int: (id: String, name: String, jsonAccumulator: String)],
    openAIToolCalls: inout [Int: OpenAIChatCompletionsMapper.ActiveToolCall]
) -> [ProviderStreamEvent] {
    switch apiProtocol {
    case .anthropicMessages:
        return AnthropicMapper.parseSSEEvent(sseEvent, activeToolCalls: &anthropicToolCalls)
    case .openaiCompletions:
        return OpenAIChatCompletionsMapper.parseSSEEvent(sseEvent, activeToolCalls: &openAIToolCalls)
    case .openaiResponses:
        return OpenAIResponsesMapper.parseSSEEvent(sseEvent, activeToolCalls: &openAIToolCalls)
    default:
        return []
    }
}
