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
                await self.concurrencyLimiter.wait()
                do {
                    guard let spec = self.modelSpec(for: modelId) else {
                        throw ModelError.providerError("Model '\(modelId)' not found in provider '\(self.name)'")
                    }
                    try Task.checkCancellation()
                    let requestMaxTokens = min(spec.maxTokens, self.defaultRequestMaxTokens)
                    let request = try self.buildRequest(messages: messages, system: system, tools: tools, modelId: modelId, maxTokens: requestMaxTokens)
                    Logger.info("Anthropic", "streamCompletion: starting, model=\(modelId)")

                    if #available(iOS 15.0, macOS 12.0, *) {
                        Logger.debug("Anthropic", "streamCompletion: using bytes streaming (iOS 15+)")
                        try await self.streamWithBytes(request: request, continuation: continuation)
                    } else {
                        Logger.debug("Anthropic", "streamCompletion: using delegate streaming (iOS 13/14)")
                        await self.streamWithDelegate(request: request, continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
                await self.concurrencyLimiter.signal()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - iOS 15+ streaming via URLSession.bytes

    @available(iOS 15.0, macOS 12.0, *)
    private func streamWithBytes(
        request: URLRequest,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
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

    // MARK: - iOS 13+ fallback streaming via URLSessionDataDelegate

    private func streamWithDelegate(
        request: URLRequest,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async {
        let delegate = SSEStreamDelegate(apiProtocol: apiProtocol, continuation: continuation)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "appagent.sse-delegate"
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        delegate.task = task

        await withTaskCancellationHandler {
            task.resume()
            await delegate.waitUntilFinished()
            session.finishTasksAndInvalidate()
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
            delegate.cancel()
        }
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

// MARK: - SSEStreamDelegate (iOS 13/14 fallback for streaming)

/// URLSessionDataDelegate that receives streaming SSE data and feeds parsed events
/// into an `AsyncThrowingStream` continuation. Used on iOS 13/14 where `URLSession.bytes` is unavailable.
private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let apiProtocol: APIProtocol
    private let continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    private var parser = SSEParser()
    private var anthropicToolCalls: [Int: (id: String, name: String, jsonAccumulator: String)] = [:]
    private var openAIToolCalls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
    private var httpStatusCode: Int?
    private var errorBody = Data()
    private var isErrorResponse = false

    private let finishSignal = ReadySignal()

    var task: URLSessionDataTask?

    init(apiProtocol: APIProtocol, continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation) {
        self.apiProtocol = apiProtocol
        self.continuation = continuation
    }

    /// Awaitable gate — resolves when the delegate receives `didCompleteWithError`.
    func waitUntilFinished() async {
        await finishSignal.wait()
    }

    func cancel() {
        task?.cancel()
        continuation.finish(throwing: AIAgentError.cancelled)
        Task { await finishSignal.signal() }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatusCode = http.statusCode
            Logger.debug("Anthropic", "delegate httpResponse: statusCode=\(http.statusCode)")
            if !(200..<300).contains(http.statusCode) {
                isErrorResponse = true
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isErrorResponse {
            errorBody.append(data)
            return
        }

        // Split incoming data into lines and feed them to the SSE parser
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard dataTask.state != .canceling else { return }
            if let sseEvent = parser.processLine(line) {
                for providerEvent in parseProviderSSEEvent(
                    apiProtocol: apiProtocol,
                    sseEvent: sseEvent,
                    anthropicToolCalls: &anthropicToolCalls,
                    openAIToolCalls: &openAIToolCalls) {
                    continuation.yield(providerEvent)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Logger.error("Anthropic", "delegate connectionError: \(error)")
            continuation.finish(throwing: error)
        } else if isErrorResponse {
            let body = String(data: errorBody, encoding: .utf8) ?? ""
            Logger.error("Anthropic", "delegate httpError: statusCode=\(httpStatusCode ?? 0), body=\(body.prefix(500))")
            continuation.finish(throwing: ModelError.httpError(
                statusCode: httpStatusCode ?? 0, body: body))
        } else {
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
        Task { await finishSignal.signal() }
    }
}
