# AppAgent

[![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%20%7C%20macOS%2012%20%7C%20Mac%20Catalyst%2013.1-blue.svg)](https://developer.apple.com)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![CocoaPods Compatible](https://img.shields.io/badge/CocoaPods-Compatible-brightgreen.svg)](https://cocoapods.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

AppAgent is an iOS/macOS AI agent SDK for embedding conversational agents into an app. It includes a provider abstraction, Anthropic streaming provider, tool loop, memory, skills, session persistence, built-in tools, and an optional UIKit overlay UI. The Core implementation has no third-party dependencies; the UIKit ChatPanel uses `BODragScroll` for panel and nested-list interaction.

## Package Shape

The current Swift package exposes one library product:

```swift
.product(name: "AppAgent", package: "AppAgent")
```

All public types are imported from the single Swift module:

```swift
import AppAgent
```

The repository keeps implementation files under `Sources/Core` and `Sources/UI` for organization, but these are directories inside the same `AppAgent` target. There are not separate `AppAgentCore` or `AppAgentUI` products in the current package.

## Requirements

| Integration | Minimum OS | Notes |
|---|---:|---|
| Swift Package Manager | iOS 13, macOS 12, Mac Catalyst 13.1 | Single `AppAgent` product |
| CocoaPods | iOS 13, macOS 12, Mac Catalyst 13.1 | Single `AppAgent` pod |
| UIKit overlay UI | iOS 13, Mac Catalyst 13.1 | Shared UIKit implementation on mobile and desktop |

- Swift tools version: 5.10
- Core has no third-party package dependencies
- The iOS/Catalyst ChatPanel depends on `BODragScroll` 1.0.1 or later

## Installation

### Swift Package Manager

Add the package to your app and depend on the single product:

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

In Xcode, use **File > Add Package Dependencies...** and select the `AppAgent` product.

### Local BODragScroll Development

The Demo project directly references the sibling checkout at `../BODragScroll`. The committed root manifest still keeps the released requirement; to make `swift build` and `swift test` use that editable checkout too, run:

```bash
Scripts/Dependencies/use-local-bodragscroll.sh
```

The default source path is `../BODragScroll`; set `BODRAGSCROLL_PATH` to use another checkout. Restore the released dependency with:

```bash
Scripts/Dependencies/use-released-bodragscroll.sh
```

### CocoaPods

Add AppAgent to your `Podfile`:

```ruby
pod 'AppAgent', '~> 0.1'
```

Then run:

```bash
pod install
```

## Quick Start

```swift
import AppAgent

let providerCentral = ModelProviderCentral()
await providerCentral.register(
    name: "anthropic",
    provider: AnthropicProvider(
        baseURL: "https://api.anthropic.com",
        apiKey: "sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx",
        models: [
            ModelSpec(id: "claude-sonnet-4-6")
        ]
    )
)

let agent = await AIAgentCentral.default.create(
    name: "main",
    profile: AIAgentProfile(identity: "You are a helpful assistant."),
    providerCentral: providerCentral,
    modelPolicy: ModelPolicy(primary: "anthropic/claude-sonnet-4-6")
)

let session = await agent.createSession(title: "Chat")
let stream = session.sendMessage("What is the capital of France?")

for await event in stream {
    switch event {
    case .streamingContent(let delta):
        print(delta, terminator: "")
    case .toolCallStarted(let call):
        print("\nCalling tool: \(call.name)")
    case .completed(let result):
        print("\nDone: \(result.text)")
    case .error(let error):
        print("Error: \(error.localizedDescription)")
    default:
        break
    }
}
```

Native macOS apps can use the complete Core API. The overlay UI is UIKit-based and is available on Mac through Mac Catalyst; AppAgent does not currently ship a separate AppKit overlay.

## UIKit Overlay

On iOS and Mac Catalyst, AppAgent can run as a passthrough overlay window above the host app:

```swift
import UIKit
import AppAgent

let overlay = await AppAgentOverlay.start(
    in: windowScene,
    agent: agent,
    sessionTitle: "Chat"
)

overlay.show()
```

For direct embedding, create an `AppAgentViewController`, assign an agent, and switch it to an existing session id.

## Documentation

| Guide | Description |
|---|---|
| [Getting Started](docs/GettingStarted.md) | Installation, provider registration, first session |
| [Architecture](docs/Architecture.md) | Current single-module architecture and runtime flow |
| [Providers](docs/Providers.md) | `ModelProvider`, `ModelSpec`, provider stream events |
| [Tools](docs/Tools.md) | `ToolProtocol`, schemas, outputs, tool registration |
| [UI Customization](docs/UICustomization.md) | Overlay UI, direct controller use, custom UI |

## Example App

The shared UIKit demo lives in `Examples/iOS/AppAgentDemo.xcodeproj` and runs on iOS as well as Mac Catalyst.

```bash
cp Examples/iOS/Resources/config.json.example Examples/iOS/Resources/config.json
```

Fill in `Examples/iOS/Resources/config.json`, open the demo project, then choose an iOS destination or **My Mac (Mac Catalyst)** and run.

To verify the Mac build from the command line:

```bash
xcodebuild \
  -project Examples/iOS/AppAgentDemo.xcodeproj \
  -scheme AppAgentDemo \
  -configuration Debug \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## License

AppAgent is released under the Apache 2.0 License. See [LICENSE](LICENSE) for details.
