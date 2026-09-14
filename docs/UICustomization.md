# UI Customization

AppAgent currently exposes UIKit UI types from the single `AppAgent` module on iOS and Mac Catalyst. The UI source lives under `Sources/UI`, but there is no separate `AppAgentUI` product. Native AppKit targets can use AppAgent Core but do not compile these UIKit overlay types.

## Overlay Window

The recommended iOS and Mac Catalyst entry point is `AppAgentOverlay`. It creates a passthrough `AppAgentWindow` above the host app and hosts an `AppAgentViewController`.

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

Taps on empty overlay areas pass through to the app below. The overlay only handles touches on its own visible controls.

## Attach First, Bind Later

If you already have a session:

```swift
let overlay = AppAgentOverlay.attach(in: windowScene)
overlay.bind(agent: agent, sessionId: session.id)
overlay.show()
```

## Direct View Controller Embedding

You can embed `AppAgentViewController` inside your own navigation stack:

```swift
let session = await agent.createSession(title: "Support")

let viewController = AppAgentViewController()
viewController.agent = agent
viewController.switchSession(to: session.id)

navigationController?.pushViewController(viewController, animated: true)
```

The controller reads from `AISession.messages` and observes `session.uiState.onChange` for streaming text, errors, and completion.

## Custom UI with AISession

For a fully custom UI, use `AISession` directly:

```swift
let stream = session.sendMessage("Hello")

for await event in stream {
    switch event {
    case .streamingContent(let delta):
        await MainActor.run {
            appendAssistantText(delta)
        }

    case .toolCallStarted(let call):
        await MainActor.run {
            showToolStatus(call.name)
        }

    case .toolCallCompleted:
        await MainActor.run {
            hideToolStatus()
        }

    case .completed(let result):
        await MainActor.run {
            finalizeAssistantMessage(result.text)
        }

    case .error(let error):
        await MainActor.run {
            showError(error.localizedDescription)
        }

    default:
        break
    }
}
```

You can also observe `session.uiState`:

```swift
session.uiState.onChange = { key in
    Task { @MainActor in
        switch key {
        case "streamingText":
            renderStreamingText(session.uiState.streamingText)
        case "isStreaming":
            setSendButtonEnabled(!session.uiState.isStreaming)
        case "lastError":
            if let error = session.uiState.lastError {
                showError(error.localizedDescription)
            }
        default:
            break
        }
    }
}
```

## SwiftUI Wrapper

Wrap `AppAgentViewController` with `UIViewControllerRepresentable`:

```swift
import SwiftUI
import AppAgent

struct AppAgentChatView: UIViewControllerRepresentable {
    let agent: AIAgent
    let session: AISession

    func makeUIViewController(context: Context) -> AppAgentViewController {
        let viewController = AppAgentViewController()
        viewController.agent = agent
        viewController.switchSession(to: session.id)
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: AppAgentViewController,
        context: Context
    ) {}
}
```

## Input Bar and Message Types

The UIKit layer is intentionally small:

- `AppAgentViewController`: table view plus input bar binding
- `AppAgentInputBar`: text field, send button, collapsed menu behavior
- `AppAgentTextField`: custom text field used by the input bar
- `AppAgentMenuButton`: compact menu button
- `ChatMessage`: UI-facing message model
- `ChatMessageCell`: table cell for user, assistant, streaming, error, and tool-info display

For deeper customization, build your own UI against `AISession` and `AIAgentEvent`.
