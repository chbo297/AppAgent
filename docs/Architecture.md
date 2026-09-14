# Architecture

AppAgent currently ships as one Swift package product and one Swift module named `AppAgent`.

The repository still separates implementation files by responsibility:

```text
Sources/
  Core/   Agent loop, sessions, providers, tools, memory, skills
  UI/     UIKit overlay and chat view controller pieces
```

Those directories are organizational boundaries inside the same target, not separate importable modules.

## Package Layout

```text
Package.swift
  product: AppAgent
  target:  AppAgent
  path:    Sources
```

Use:

```swift
import AppAgent
```

Do not import `AppAgentCore` or `AppAgentUI`; those products do not exist in the current package.

## Runtime Layers

```text
AIAgent
  AIAgentProfile
  ModelPolicy
  ToolCentral
  ModelProviderCentral
  MemoryStore
  SkillsManager
  AISessionManager
    AISession
      LLMExecutor
        ModelProvider
        ToolProtocol
```

## Agent Layer

`AIAgent` is the facade used by host apps. It owns:

- `AIAgentProfile`: identity, prompt builders, tool prompts, memory config, tool timeout, max iterations
- `ModelPolicy`: primary and fallback model references in `"provider/model"` format
- `ToolCentral`: shared tool registry and per-session tool factories
- `ModelProviderCentral`: provider registry and model resolution
- `MemoryStore`: long-term and hot memory
- `SkillsManager`: markdown skill discovery and lifecycle
- `AISessionManager`: session creation, lookup, persistence, deletion

Create agents through `AIAgentCentral`:

```swift
let agent = await AIAgentCentral.default.create(
    name: "main",
    profile: AIAgentProfile(identity: "You are helpful."),
    providerCentral: providerCentral,
    modelPolicy: ModelPolicy(primary: "anthropic/claude-sonnet-4-6")
)
```

## Session Layer

`AISession` represents one conversation. It stores:

- `messages: [AIAgentMessage]`
- resolved `provider` and `modelId`
- installed per-session tools
- prompt parts
- session-level tool policy
- `SessionUIState`
- mounted `LLMExecutor`

`sendMessage(_:)` returns `AsyncStream<AIAgentEvent>` and starts the executor.

## Execution Flow

```text
User text
  -> AISession.sendMessage
  -> LLMExecutor.run
  -> assemble system prompt
  -> resolve tools
  -> provider.streamCompletion
  -> stream text/tool events
  -> execute requested tools
  -> append tool results
  -> loop until end turn or max iterations
  -> update AISession.messages
```

`LLMExecutor` handles provider retries, tool safety authorization, tool loop detection, context compression, cancellation, and `SessionUIState` updates.

## Provider Layer

Providers conform to `ModelProvider`:

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

The built-in provider is `AnthropicProvider`.

## Tool Layer

Tools conform to `ToolProtocol`:

```swift
public protocol ToolProtocol: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: Tool.Schema { get }
    var enabled: Bool { get }
    var group: String { get }
    var safetyLevel: Tool.SafetyLevel { get }

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output
}
```

`ToolCentral` stores shared tools and factories. When a session is created, the session receives a filtered snapshot of available tools.

## UI Layer

UIKit files live in `Sources/UI` and are compiled when UIKit is available.

Key public types:

- `AppAgentOverlay`: creates a passthrough overlay window and binds it to an agent/session
- `AppAgentWindow`: lets taps outside AppAgent UI pass through to the host app
- `AppAgentViewController`: chat UI backed by `AISession.uiState`
- `AppAgentInputBar`, `AppAgentTextField`, `AppAgentMenuButton`: input controls
- `ChatMessage`, `ChatMessageCell`: UI message model and table cell

The UI layer is optional at runtime. Apps can ignore it and build directly against `AISession`.

## Persistence

`SessionStorage` abstracts session persistence. The SDK includes:

- `InMemorySessionStorage`
- `FileSessionStorage`

Memory storage is separate and uses `MemoryStorage`, with in-memory and file-backed implementations.
