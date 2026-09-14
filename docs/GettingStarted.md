# Getting Started

This guide follows the current package shape: one SwiftPM product, one Swift module, imported as `AppAgent`.

## Prerequisites

- Xcode 15 or later
- Swift 5.10 or later
- iOS 13+, native macOS 12+, or Mac Catalyst 13.1+
- An LLM API key if you use the built-in `AnthropicProvider`

## Installation

### Swift Package Manager

Add the package and depend on the `AppAgent` product:

```swift
dependencies: [
    .package(url: "https://github.com/chbo297/AppAgent.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AppAgent", package: "AppAgent")
        ]
    )
]
```

Then import:

```swift
import AppAgent
```

### CocoaPods

```ruby
pod 'AppAgent', '~> 0.1'
```

CocoaPods supports the native macOS Core and the UIKit implementation on iOS/Mac Catalyst. Swift Package Manager remains the recommended integration path for new projects.

## Register a Provider

`ModelProviderCentral` stores providers by name. Model references use the `"providerName/modelId"` format.

```swift
import AppAgent

let providerCentral = ModelProviderCentral()

await providerCentral.register(
    name: "anthropic",
    provider: AnthropicProvider(
        baseURL: "https://api.anthropic.com",
        apiKey: "sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx",
        models: [
            ModelSpec(
                id: "claude-sonnet-4-6",
                contextWindow: 200_000,
                maxTokens: 64_000
            )
        ]
    )
)
```

Never hard-code production API keys in source. Load them from Keychain, your server, or a local config file excluded from Git.

## Create an Agent and Session

`AIAgent` is created through `AIAgentCentral`. The agent owns provider selection, tool registration, memory, skills, and session lifecycle.

```swift
let agent = await AIAgentCentral.default.create(
    name: "main",
    profile: AIAgentProfile(
        identity: "You are a helpful assistant.",
        additionalPromptBuilders: [
            PromptBuilder("Be concise and honest when uncertain.")
        ]
    ),
    providerCentral: providerCentral,
    modelPolicy: ModelPolicy(primary: "anthropic/claude-sonnet-4-6"),
    sessionStorage: InMemorySessionStorage()
)

let session = await agent.createSession(title: "First chat")
```

## Send a Message

```swift
let events = session.sendMessage("Explain Swift actors in one paragraph.")

for await event in events {
    switch event {
    case .started(let turn):
        print("Turn \(turn) started")

    case .streamingContent(let delta):
        print(delta, terminator: "")

    case .toolCallStarted(let call):
        print("\nTool call: \(call.name)")

    case .toolCallCompleted(let toolCallId, _):
        print("\nTool completed: \(toolCallId)")

    case .toolCallFailed(_, let name, let error):
        print("\nTool failed: \(name): \(error.localizedDescription)")

    case .usage(let inputTokens, let outputTokens):
        print("\nUsage: \(inputTokens) in, \(outputTokens) out")

    case .completed(let result):
        print("\nFinal text: \(result.text)")

    case .error(let error):
        print("\nError: \(error.localizedDescription)")
    }
}
```

The same state is also reflected on `session.uiState`, including `isStreaming`, `streamingText`, and `lastError`.

## Cancellation

Cancel through the session or by cancelling the task consuming the stream:

```swift
let task = Task {
    for await event in session.sendMessage("Tell me a long story.") {
        // Update UI.
    }
}

task.cancel()
// or:
session.cancel()
```

## Running the iOS and Mac Demo

The shared UIKit demo is an Xcode project at `Examples/iOS/AppAgentDemo.xcodeproj`.

```bash
cp Examples/iOS/Resources/config.json.example Examples/iOS/Resources/config.json
```

Fill in `Examples/iOS/Resources/config.json`, open the Xcode project, then choose an iOS Simulator/device or **My Mac (Mac Catalyst)** and run.

AppAgent Core also compiles for native macOS 12+. The complete overlay UI uses UIKit, so desktop apps that need the built-in AppAgent interface should use Mac Catalyst rather than an AppKit target.

## Next Steps

- [Architecture](Architecture.md)
- [Providers](Providers.md)
- [Tools](Tools.md)
- [UI Customization](UICustomization.md)
