//
//  AnthropicProvider.swift
//  AppAgent
//

import Foundation

/// ModelProvider implementation for the Anthropic Messages API.
public final class AnthropicProvider: ModelProvider, @unchecked Sendable {
    private struct Configuration: Sendable {
        var baseURL: String
        var apiKey: String
        var apiProtocol: APIProtocol
        var customHeaders: [String: String]
        var models: [ModelSpec]
        var requestTimeout: TimeInterval
        var defaultRequestMaxTokens: Int
    }

    public let name = "anthropic"
    @Locked
    private var configuration: Configuration
    public var baseURL: String {
        configuration.baseURL
    }

    public var apiKey: String {
        configuration.apiKey
    }

    public var apiProtocol: APIProtocol {
        configuration.apiProtocol
    }

    public var customHeaders: [String: String] {
        configuration.customHeaders
    }

    public var models: [ModelSpec] {
        configuration.models
    }

    public var requestTimeout: TimeInterval {
        configuration.requestTimeout
    }

    public var defaultRequestMaxTokens: Int {
        configuration.defaultRequestMaxTokens
    }
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
        self._configuration = Locked(
            wrappedValue: Configuration(
                baseURL: baseURL,
                apiKey: apiKey,
                apiProtocol: apiProtocol,
                customHeaders: customHeaders,
                models: models,
                requestTimeout: requestTimeout,
                defaultRequestMaxTokens: defaultRequestMaxTokens
            )
        )
        self.concurrencyLimiter = ConcurrencyLimiter(limit: maxConcurrency)
        self.session = Self.makeSession(requestTimeout: requestTimeout)
    }

    /// Update the request configuration in place.
    ///
    /// Existing sessions may retain this provider instance. Updating the
    /// configuration in place lets those sessions use the new endpoint,
    /// credentials, protocol, headers, and model specs on their next run.
    /// A request already building or streaming keeps its captured snapshot.
    public func updateConfiguration(
        baseURL: String,
        apiKey: String,
        apiProtocol: APIProtocol,
        customHeaders: [String: String],
        models: [ModelSpec],
        requestTimeout: TimeInterval? = nil,
        defaultRequestMaxTokens: Int? = nil
    ) {
        precondition(!models.isEmpty, "AnthropicProvider requires at least one model")
        let current = configuration
        let next = Configuration(
            baseURL: baseURL,
            apiKey: apiKey,
            apiProtocol: apiProtocol,
            customHeaders: customHeaders,
            models: models,
            requestTimeout: requestTimeout ?? current.requestTimeout,
            defaultRequestMaxTokens: defaultRequestMaxTokens ?? current.defaultRequestMaxTokens
        )
        precondition(next.defaultRequestMaxTokens > 0, "defaultRequestMaxTokens must be positive")
        configuration = next
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
                        let configuration = self.configuration
                        guard let spec = configuration.models.first(where: { model in
                            model.id == modelId
                        }) else {
                            throw ModelError.providerError("Model '\(modelId)' not found in provider '\(self.name)'")
                        }
                        try Task.checkCancellation()
                        let requestMaxTokens = min(spec.maxTokens, configuration.defaultRequestMaxTokens)
                        let request = try self.buildRequest(
                            messages: messages,
                            system: system,
                            tools: tools,
                            modelId: modelId,
                            maxTokens: requestMaxTokens,
                            configuration: configuration
                        )
                        let trace = ProviderWireTrace(
                            requestID: ModelRequestLogContext.requestID ?? UUID().uuidString,
                            apiProtocol: configuration.apiProtocol,
                            secrets: [configuration.apiKey] + Array(configuration.customHeaders.values)
                        )
                        trace.record(
                            phase: "request",
                            payload: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                        )

                        // 最低支持 iOS 15 / macOS 12，`URLSession.bytes` 一定可用——
                        // 原来的 iOS 13/14 delegate 降级路径已随最低版本上调删除。
                        try await self.streamWithBytes(
                            request: request,
                            apiProtocol: configuration.apiProtocol,
                            trace: trace,
                            continuation: continuation
                        )
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
        apiProtocol: APIProtocol,
        trace: ProviderWireTrace,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        do {
            try await receiveResponse(
                request: request,
                apiProtocol: apiProtocol,
                trace: trace,
                continuation: continuation
            )
        } catch {
            trace.record(phase: "stream_error", payload: String(describing: error))
            throw error
        }
    }

    private func receiveResponse(
        request: URLRequest,
        apiProtocol: APIProtocol,
        trace: ProviderWireTrace,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            continuation.finish(throwing: ModelError.invalidResponse)
            return
        }
        // 只记录用于排查的响应元信息，认证头、Cookie 和 URL query 不进入日志。
        trace.record(
            phase: "http_response",
            payload: "status=\(httpResponse.statusCode) contentType=\(httpResponse.mimeType ?? "-") requestID=\(httpResponse.value(forHTTPHeaderField: "x-request-id") ?? "-")"
        )

        if !(200..<300).contains(httpResponse.statusCode) {
            var body = ""
            var sequence = 0
            for try await line in bytes.lines {
                sequence += 1
                trace.record(phase: "http_error_body", sequence: sequence, payload: line)
                body += line
            }
            continuation.finish(throwing: ModelError.httpError(
                statusCode: httpResponse.statusCode, body: body))
            return
        }

        var decoder = ProviderSSEStreamDecoder(apiProtocol: apiProtocol, trace: trace)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try decoder.processLine(line) {
                continuation.yield(event)
            }
        }
        for event in try decoder.finish() {
            continuation.yield(event)
        }
        trace.record(phase: "eof", payload: "lines=\(decoder.lineCount)")
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
        maxTokens: Int,
        configuration: Configuration
    ) throws -> URLRequest {
        switch configuration.apiProtocol {
        case .anthropicMessages:
            return try buildAnthropicMessagesRequest(
                messages: messages,
                system: system,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens,
                configuration: configuration
            )
        case .openaiCompletions:
            return try buildOpenAIChatCompletionsRequest(
                messages: messages,
                system: system,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens,
                configuration: configuration
            )
        case .openaiResponses:
            return try buildOpenAIResponsesRequest(
                messages: messages,
                system: system,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens,
                configuration: configuration
            )
        default:
            throw ModelError.providerError("API protocol '\(configuration.apiProtocol.rawValue)' is not implemented")
        }
    }

    private func buildAnthropicMessagesRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int,
        configuration: Configuration
    ) throws -> URLRequest {
        let effectiveBaseURL = configuration.baseURL.isEmpty
            ? "https://api.anthropic.com"
            : configuration.baseURL
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
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        for (key, value) in configuration.customHeaders {
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

        return request
    }

    private func buildOpenAIChatCompletionsRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int,
        configuration: Configuration
    ) throws -> URLRequest {
        let effectiveBaseURL = configuration.baseURL.isEmpty
            ? "https://api.openai.com/v1"
            : configuration.baseURL
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
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in configuration.customHeaders {
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

        return request
    }

    private func buildOpenAIResponsesRequest(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String,
        maxTokens: Int,
        configuration: Configuration
    ) throws -> URLRequest {
        let effectiveBaseURL = configuration.baseURL.isEmpty
            ? "https://api.openai.com/v1"
            : configuration.baseURL
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
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in configuration.customHeaders {
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

        return request
    }
}

/// 记录应用层报文；不记录认证头。完整 payload 分块后仍走既有日志轮转与导出。
struct ProviderWireTrace: Sendable {
    let requestID: String
    let apiProtocol: APIProtocol
    let secrets: [String]

    func record(phase: String, sequence: Int = 0, payload: @autoclosure () -> String) {
        guard Logger.isEnabled, Logger.minimumLevel <= .debug else {
            return
        }
        Logger.diagnosticPayload(
            "Anthropic",
            metadata: "wire request=\(requestID) protocol=\(apiProtocol.rawValue) phase=\(phase) seq=\(sequence) time=\(AppAgentRunLog.stamp(Date()))",
            payload: payload(),
            secrets: secrets
        )
    }
}

/// 先记录每条收到的文本，再解析；未知格式、解码失败和 EOF 尾帧也有原文可查。
struct ProviderSSEStreamDecoder {
    let apiProtocol: APIProtocol
    let trace: ProviderWireTrace
    private var parser = SSEParser()
    private var anthropicToolCalls: [Int: (id: String, name: String, jsonAccumulator: String)] = [:]
    private var openAIToolCalls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
    private(set) var lineCount = 0

    init(apiProtocol: APIProtocol, trace: ProviderWireTrace) {
        self.apiProtocol = apiProtocol
        self.trace = trace
    }

    mutating func processLine(_ line: String) throws -> [ProviderStreamEvent] {
        lineCount += 1
        trace.record(phase: "response_line", sequence: lineCount, payload: line)
        guard let event = parser.processLine(line) else {
            return []
        }
        return try decode(event, source: "sse")
    }

    mutating func finish() throws -> [ProviderStreamEvent] {
        guard let event = parser.flush() else {
            return []
        }
        return try decode(event, source: "sse_flush")
    }

    private mutating func decode(_ event: SSEEvent, source: String) throws -> [ProviderStreamEvent] {
        // 原文已在 response_line 中；这里仅标明实际采用的解析路径。
        trace.record(phase: source, sequence: lineCount, payload: "event=\(event.event)")
        if let error = parseProviderSSEErrorPayload(event.data, eventType: event.event) {
            anthropicToolCalls.removeAll()
            openAIToolCalls.removeAll()
            trace.record(phase: "sse_error", sequence: lineCount, payload: error.localizedDescription)
            throw error
        }
        return try parseProviderSSEEvent(
            apiProtocol: apiProtocol,
            sseEvent: event,
            anthropicToolCalls: &anthropicToolCalls,
            openAIToolCalls: &openAIToolCalls
        )
    }
}

private func parseProviderSSEEvent(
    apiProtocol: APIProtocol,
    sseEvent: SSEEvent,
    anthropicToolCalls: inout [Int: (id: String, name: String, jsonAccumulator: String)],
    openAIToolCalls: inout [Int: OpenAIChatCompletionsMapper.ActiveToolCall]
) throws -> [ProviderStreamEvent] {
    switch apiProtocol {
    case .anthropicMessages:
        return AnthropicMapper.parseSSEEvent(sseEvent, activeToolCalls: &anthropicToolCalls)
    case .openaiCompletions:
        return OpenAIChatCompletionsMapper.parseSSEEvent(sseEvent, activeToolCalls: &openAIToolCalls)
    case .openaiResponses:
        return try OpenAIResponsesMapper.parseSSEEvent(sseEvent, activeToolCalls: &openAIToolCalls)
    default:
        return []
    }
}

func parseProviderSSEErrorPayload(_ payload: String, eventType: String? = nil) -> ModelError? {
    guard let data = payload.data(using: .utf8),
          let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        if eventType == "error" || eventType == "response.failed" {
            return .upstreamError(type: eventType, message: payload)
        }
        return nil
    }
    let kind = envelope["type"] as? String ?? eventType
    let response = envelope["response"] as? [String: Any]
    let error = response?["error"] as? [String: Any] ?? envelope["error"] as? [String: Any]
    let isFailure = kind == "response.failed" || kind == "error" || response?["status"] as? String == "failed"
    guard error != nil || isFailure else {
        return nil
    }
    // Anthropic/Chat Completions 使用 error；Responses 还使用 response.error 或顶层 code/message。
    let details = error ?? envelope
    let type = error?["type"] as? String ?? (isFailure ? kind : nil)
    let code = details["code"] as? String
    let message = details["message"] as? String ?? "上游模型服务返回未命名错误"
    return .upstreamError(type: type, code: code, message: message)
}
