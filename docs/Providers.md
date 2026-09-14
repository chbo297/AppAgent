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

`LLMExecutor` uses `ErrorClassifier` to decide whether an error is retryable, whether context compression should be attempted, and whether fallback is appropriate.

Fallback policy exists in `ModelPolicy`, but full runtime fallback execution is still a planned enhancement.
