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

`ModelProviderCentral` registers providers by name and resolves compound model references
(provider and model components must both be nonempty; model IDs can contain `/`):

```swift
await providerCentral.register(name: "anthropic", provider: provider)

let resolved = await providerCentral.resolve(
    modelReference: "anthropic/claude-sonnet-4-6"
)
```

## Endpoint settings

`AppAgentEndpointSettings()` starts unconfigured: URL, API key, headers and enabled models are empty.
`AppAgentSettingsStore.loadOrDefault()` returns that empty value when no saved settings exist.
Hosts own service URLs, authentication headers and model defaults, and pass them explicitly:

```swift
let settings = AppAgentEndpointSettings(
    baseURL: endpointURL,
    apiKey: apiKeyFromSecureStorage,
    customHeaders: endpointHeaders,
    enabledModels: [
        AppAgentModelRef(modelId: selectedModelID, apiProtocol: .openaiCompletions)
    ]
)
await agent.applyEndpointSettings(settings)
```

The settings UI, discovery and provider construction share validation: an absolute HTTP(S) base URL
with a host and no embedded credentials, query or fragment; a nonblank API key; and at least one
enabled model, with every model ID nonblank. Leading/trailing whitespace is removed for requests
and model references. Context and output token limits must both be positive. Discovery of the
model list only requires the URL and key; availability probes also validate token limits and timeout.

Invalid settings yield no providers, model references or policy. Both `applyEndpointSettings` and
`ModelProviderCentral.register(settings:)` remove stale settings registrations, including when the
new invalid configuration uses the same protocol. Only the exact `appagent-<APIProtocol.rawValue>`
names belong to settings; other host registrations remain intact. Applying invalid or empty settings
clears the agent policy, cancels all current session runs and revokes their provider/model selection
and active model reference. Selection generations reject late fallback publication. New and restored
sessions remain unconfigured, even when other host providers are registered, until valid endpoint
settings are applied again. Chat histories and non-model mask configuration are preserved; masks
do not hold a separate model policy. Registration and session publication share one uninterrupted
provider actor operation, so an earlier apply cannot resume after clear to revive its provider.
Run snapshots carry a revocable provider lease: a loop suspended during preparation cannot begin
a request with its captured credentials after clear, even if valid settings are saved again.
Ordinary valid updates preserve existing runs; clear cancels them, including streams already active.
`AppAgentSettingsStore` remains a persistence layer; callers must use `isUsable` before treating
loaded settings as ready for requests.

The SDK store owns endpoint persistence. `save(_:)` and `clear()` return `Bool`; a false result
must not be treated as a successful configuration change. Clear deletes the stored key and saves
an empty configuration marker, leaving UI preferences untouched. `hasSavedConfiguration` includes
that marker: hosts may import legacy defaults only when it is false, never merely because the saved
configuration is unusable. Successful changes emit `didChangeNotification` without credentials or
other `userInfo`; observers should reload the store.

The settings page displays the saved URL, masked API key and selected models. “Clear model
configuration” requires confirmation and invalidates discovery and availability probes. Its existing
`onSave` callback fires only after successful persistence, including an **empty** settings value for
clear. Always apply that value; filtering the callback by `isUsable` would leave the runtime configured:

```swift
settingsController.onSave = { settings in
    Task {
        await agent.applyEndpointSettings(settings)
    }
}
```

For a custom UI, call `AppAgentSettingsStore.clear()` and apply `AppAgentEndpointSettings()` only
when it returns true. Choose either the callback or a store notification observer to apply changes;
an observer should reload current settings when its task executes instead of capturing an older value.
The built-in overlay applies save and clear to existing sessions without replacing the current chat.

Discovery and retesting put selected models first without changing their primary/fallback order.
After all results arrive, unselected models sort by measured first-token latency, fastest first;
ties retain their order and failures or unknown timings follow. Discovery does not auto-select a model.

`session(op: models)` reports `current_endpoint` from the session's current provider configuration,
with `base_url`, `request_url`, `api_protocol` and `credentials_exposed: false`. URLs strip user
information, query and fragment; URLs containing configured secrets are omitted. Built-in providers
share the actual request URL builder; custom providers return a null request URL when unknown.
This is current configuration metadata, not a historical request or a redirect's final destination.

`AppAgentSettingsTests` covers invalid primary/fallback entries, normalized provider/policy
agreement, stale registration cleanup, preservation of host providers and discovery rejection
before network access.

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

`AnthropicProvider` dispatches Anthropic Messages, OpenAI Chat Completions and OpenAI
Responses according to `apiProtocol`, mapping each SSE stream into `ProviderStreamEvent`.
Other `APIProtocol` cases are reserved and are not implemented by this provider.

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
    case reasoningDelta(String)
    case toolCall(AIAgentMessage.ToolCall)
    case discardedToolCall(name: String)   // cut off by the output limit, never executed
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

`LLMExecutor` uses `ErrorClassifier.retryable` to decide whether to retry a failed model request. Transport errors such as non-cancelled `URLError`, HTTP 429, and server errors are retryable; authentication errors such as HTTP 401/403 are not retried on the same model.

Model request network failures retain the failing URL's **Host**, the actual `localizedDescription`,
and `NSURLErrorDomain` / code (including DNS `-1003` and connection loss `-1005`). If the error
has no usable failing URL, the running provider's `baseURL` supplies the Host. URLs in descriptions
are reduced to Hosts; credentials, paths, queries and fragments are omitted, and configured API keys
and header values are redacted. The full `NSError.userInfo` is never displayed. The final message
ends with `网络错误，请稍后重试。` and enters the existing `TurnJournal.failed` outlet, so the terminal
event, UI and persisted turn record share the same message. Successful retries leave no terminal failure.
This conversion applies only at the model stream boundary; tool network failures remain tool failures.

`CancellationError`, `AIAgentError.cancelled` and URLSession cancellation (`-999`, including native
`NSError`) stop the turn as cancelled without network wording, retries or fallback.

HTTP 200 SSE failures throw `ModelError.upstreamError(type:code:message:)`, preserving Anthropic
and Chat Completions `error` fields, Responses `response.error`, and flat Responses `error` events.
Responses `response.failed` never becomes `.done(.unknown)`. Only recognized transient stream
errors (server, overload, rate limit, timeout) retry; unknown, authentication, quota and request
errors do not. Stream failures can use the configured model fallback after this retry decision.

Responses releases tool calls only on `response.completed`, with complete JSON object arguments.
Failed/incomplete responses and proxy `[DONE]` markers cannot release pending calls.
`max_output_tokens` maps to `.maxTokens` and discards pending calls (they may be half-written).

Anthropic and Chat Completions also reject malformed or non-object tool arguments instead of
substituting `{}`. Anthropic permits tools with no argument deltas. An Anthropic tool block whose
arguments are not complete JSON is held until `message_delta`: with `stop_reason=max_tokens` it is
discarded and the stream ends with `.maxTokens`; any other stop reason throws `malformedToolCall`.
Chat Completions releases calls only on `finish_reason=tool_calls/function_call`; `[DONE]` and
other finish reasons (including `length` → `.maxTokens`) discard pending calls. See
`ProviderToolArgumentTests`.

### Retry and turn limits

- `RetryPolicy.maxRetries` defaults to **3 retries**, excluding the initial request: up to **4 attempts** for consecutive failures on the current model. The counter resets after a successful stream or a model fallback. Retry delays use exponential backoff (normally about 1, 2, and 4 seconds, with ±25% jitter).
- **A stalled stream is a retryable transport error, not a dead model.** `ModelError.streamStalled(idleSeconds:)` (raised by the executor's idle watchdog) and non-cancelled, non-timeout URL errors classify as `FailoverReason.transport` with `retryable = true` and `shouldFallback = false`. URL timeouts use `.timeout` with the same recovery hints. URL errors do not trigger model fallback even after partial output; the existing bounded retry policy handles them without another retry layer.
- `AIAgentProfile.maxIterations` defaults to **70 iterations per user turn**. Requests after tool execution, retry requests, and fallback requests all consume this same budget; retries are not an extra allowance on top of the 70 iterations. A successful final answer on the last allowed iteration completes normally.
- When an error is not retryable, or retries are exhausted, the executor tries the next available, untried model in `ModelPolicy` if `shouldFallback` is true or a non-URL failure produced partial output. If none is available, it returns the last provider error (URL errors use the safe network diagnostic described above). There is no separate “retry limit exceeded” error.
- When the loop budget runs out before a final answer, the error is `AIAgentError.maxIterationsReached(limit:)`, displayed as `AIAgent loop exceeded maximum(70) iterations` with the actual configured limit. This can also happen before all retries or fallback models have been attempted.

Context compression has two triggers, both compressing only the provider view (persisted history
stays complete) down to **40% of the context window**:

- Proactive: before each request, when the estimated size exceeds **85%** of `contextWindow`.
- Reactive: when the provider rejects a request as too long (`shouldCompress`). The executor
  compresses once and resends; a second overflow in the same turn ends the turn with the error
  instead of resending the same oversized request.

Both paths post a user-visible notice on the turn (`AIAgentEvent.notice`, persisted in
`AIAgentTurnRecord.notices`). Retry and fallback discard the failed attempt's partial text and
unexecuted calls before sending the next request.

### Output limit (`max_tokens`)

`max_tokens` caps one response, not the conversation. When a response stops with `.maxTokens`:

- Complete tool calls received before the cut are executed normally; half-written ones are
  discarded by the mapper and reported as `.discardedToolCall(name:)`, so the resume note can
  name the dropped call and ask for smaller arguments.
- With no tool calls, the partial text is kept and a hidden agent note
  (`AIAgentMessage.agentNote`, role user, source agent, display hidden) asks the model to resume
  mid-thought without apology or recap, and to re-issue any discarded tool call in smaller pieces.
  This follows Claude Code's recovery prompt. Up to **3 continuations per turn**; two consecutive
  cut-offs with neither text nor a discarded call (a reasoning model spent the whole budget
  thinking) stop early. The turn then finishes with the text so far and a notice. Continuations
  are joined directly, dropping a 2–40 character overlap at the seam.

Measured through an OpenAI-compatible gateway (2026-11): `gpt-5.6-sol` and the Claude models ignore `max_tokens`; GLM, Kimi,
MiniMax and DeepSeek honor it.
