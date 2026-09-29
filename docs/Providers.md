# Providers

Providers connect AppAgent to model backends. The current provider protocol is `ModelProvider`.

## ModelProvider

```swift
public protocol ModelProvider: Sendable {
    var name: String { get }
    var baseURL: String { get }
    var apiKey: String { get }
    var apiProtocol: APIProtocol { get }
    var customHeaders: [String: String] { get }
    var models: [ModelSpec] { get }
    var requestTimeout: TimeInterval { get }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error>
}
```

`ModelProviderCentral` registers providers by name and resolves compound model references:

```swift
await providerCentral.register(name: "anthropic", provider: provider)

let resolved = await providerCentral.resolve(
    modelReference: "anthropic/claude-sonnet-4-6"
)
```

## ModelSpec

```swift
public struct ModelSpec: Sendable, Codable {
    public var id: String
    public var reasoning: Bool
    public var inputModalities: [String]
    public var contextWindow: Int
    public var maxTokens: Int
}
```

`maxTokens` describes the provider or model upper bound. Providers can choose a lower request default when building API requests.

## AnthropicProvider

```swift
let provider = AnthropicProvider(
    baseURL: "https://api.anthropic.com",
    apiKey: "sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx",
    apiProtocol: .anthropicMessages,
    customHeaders: [:],
    models: [
        ModelSpec(id: "claude-sonnet-4-6")
    ],
    requestTimeout: 300,
    defaultRequestMaxTokens: 4096,
    maxConcurrency: 5
)
```

`AnthropicProvider` streams Anthropic Messages API SSE responses and maps them into `ProviderStreamEvent`.

### Transport details worth copying into a custom provider

- **Own the `URLSession`; do not use `URLSession.shared`.** `AnthropicProvider` builds its session with
  `shouldUseExtendedBackgroundIdleMode = true`, which can only be set on the configuration. It asks the system
  to keep established TCP connections alive when the app moves to the background — the one knob that improves
  survival across a background/foreground round trip. `timeoutIntervalForRequest` is set from the same
  `requestTimeout` as `URLRequest.timeoutInterval`, because `URLRequest` carries its own 60s default that would
  otherwise silently override the configuration. Never let the two disagree.
- **Concurrency permits are paired by one function.** `ConcurrencyLimiter.withPermit { }` acquires and always
  releases, and a request cancelled while queued throws `CancellationError` without taking a permit. The
  previous `wait()` / `signal()` pair relied on the caller: any early return leaked a permit permanently, and
  once `maxConcurrency` permits leaked the agent stopped issuing requests — presenting as a hang, not an error.
- **Cancellation must reach the URLSession task.** Set `continuation.onTermination` and cancel the streaming
  task there (the skeleton below does). The executor wraps every provider stream in an idle watchdog that
  terminates the downstream on a stall; without `onTermination` the HTTP request keeps running and burning tokens.
  See `docs/TurnLifecycle.md` → 打断与恢复.

## ProviderStreamEvent

```swift
public enum ProviderStreamEvent: Sendable {
    case textDelta(String)
    case toolCall(AIAgentMessage.ToolCall)
    case done(stopReason: StopReason)
    case usage(inputTokens: Int, outputTokens: Int)
}
```

These events are provider-internal. `LLMExecutor` converts them into public `AIAgentEvent` values such as `.streamingContent`, `.toolCallStarted`, `.completed`, and `.error`.

## ContentOrCacheControl

System prompt segments and tool definitions are passed as arrays of:

```swift
public enum ContentOrCacheControl<T: Sendable>: Sendable {
    case content(T)
    case cacheControl
}
```

For Anthropic, `.cacheControl` attaches ephemeral cache control to the previous serializable segment.

## Custom Provider Skeleton

```swift
import Foundation
import AppAgent

public final class OpenAICompatibleProvider: ModelProvider, @unchecked Sendable {
    public let name = "openai-compatible"
    public let baseURL: String
    public let apiKey: String
    public let apiProtocol: APIProtocol = .openaiCompletions
    public let customHeaders: [String: String]
    public let models: [ModelSpec]
    public let requestTimeout: TimeInterval

    public init(
        baseURL: String,
        apiKey: String,
        customHeaders: [String: String] = [:],
        models: [ModelSpec],
        requestTimeout: TimeInterval = 300
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.customHeaders = customHeaders
        self.models = models
        self.requestTimeout = requestTimeout
    }

    public func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Build URLRequest from messages, system, tools, and modelId.
                    // Stream backend events and map them to ProviderStreamEvent.
                    continuation.yield(.textDelta("Hello"))
                    continuation.yield(.done(stopReason: .endTurn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
```

## Error Classification

`LLMExecutor` uses `ErrorClassifier.retryable` to decide whether to retry a failed model request. Transport errors such as `URLError`, HTTP 429, and server errors are retryable; authentication errors such as HTTP 401/403 are not retried on the same model.

### Retry and turn limits

- `RetryPolicy.maxRetries` defaults to **3 retries**, excluding the initial request: up to **4 attempts** for consecutive failures on the current model. The counter resets after a successful stream or a model fallback. Retry delays use exponential backoff (normally about 1, 2, and 4 seconds, with ±25% jitter).
- **A stalled stream is a retryable transport error, not a dead model.** `ModelError.streamStalled(idleSeconds:)` (raised by the executor's idle watchdog) and every non-timeout `URLError` classify as `FailoverReason.transport` with `retryable = true` and `shouldFallback = false`: the endpoint is fine, the connection died, so retrying the same model is the correct move and probing fallback candidates only wastes a round.
- `AIAgentProfile.maxIterations` defaults to **70 iterations per user turn**. Requests after tool execution, retry requests, and fallback requests all consume this same budget; retries are not an extra allowance on top of the 70 iterations. A successful final answer on the last allowed iteration completes normally.
- When an error is not retryable, or retries are exhausted, the executor tries the next available, untried model in `ModelPolicy`. If none is available, it returns the last original provider/transport error, such as `HTTP 503: ...` or the system's localized network error. There is no separate “retry limit exceeded” error.
- When the loop budget runs out before a final answer, the error is `AIAgentError.maxIterationsReached(limit:)`, displayed as `AIAgent loop exceeded maximum(70) iterations` with the actual configured limit. This can also happen before all retries or fallback models have been attempted.

The classifier's `shouldCompress` and `shouldFallback` fields are recommendations, not gates currently consumed by the executor. Context compression is checked separately before requests based on estimated context usage; runtime fallback follows `ModelPolicy` after the retry decision.
