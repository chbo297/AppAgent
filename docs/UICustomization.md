# UI Customization

AppAgent currently exposes UIKit UI types from the single `AppAgent` module on iOS and Mac Catalyst. The UI source lives under `Sources/UI`, but there is no separate `AppAgentUI` product. Native AppKit targets can use AppAgent Core but do not compile these UIKit overlay types.

## Overlay Window — the only way to mount the chat UI

`AppAgentOverlay` is the single iOS / Mac Catalyst entry point. It creates a passthrough `AppAgentWindow` above the host app and hosts an `AppAgentViewController` as that window's `rootViewController`.

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

**Hosts do not embed `AppAgentViewController` into their own view-controller hierarchy.** Panel geometry, keyboard tracking and decision-card placement are all derived from owning one dedicated passthrough window; none of those premises hold inside a host container. If you need chat UI that lives inside a host screen, build it against `AISession` (see below) instead of reusing AppAgent's controller.

## Attach First, Bind Later

If you already have a session:

```swift
let overlay = AppAgentOverlay.attach(in: windowScene)
overlay.bind(agent: agent, sessionId: session.id)
overlay.show()
```

## Observing AppAgent's Presentation

Adopt `AppAgentPresentationDelegate` to learn where AppAgent currently sits and what of the host it covers:

```swift
overlay.viewController.presentationDelegate = self

func appAgentPresentationDidChange(_ state: AppAgentPresentationState) {
    // 输入栏（收起态就是悬浮球）位置、对话面板可见区的位置与高度
    let ball = state.inputBarFrame
    let panel = state.chatPanelFrame          // nil = 面板不可见
    // 所有盖住宿主的区域；opacity 低于阈值说明正在淡出、其实不再遮挡
    let blocking = state.areas.filter { $0.opacity > 0.5 }
    // 想跟着一起动就用同一份动画参数；duration == 0 表示手势跟手帧
    if state.animation.isAnimated {
        UIView.animate(withDuration: state.animation.duration,
                       delay: 0,
                       options: state.animation.options) { relayout(around: blocking) }
    } else {
        relayout(around: blocking)
    }
}
```

All rects are in host **window** coordinates. State is de-duplicated by geometry, so the same picture is never reported twice. `viewController.presentationState` gives the same snapshot on demand.

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

## Input Bar and Message Types

The UIKit layer is intentionally small:

- `AppAgentOverlay`: the host-facing entry point (passthrough window + chat controller)
- `AppAgentViewController`: chat panel plus input bar, only valid as `AppAgentWindow`'s root
- `AppAgentInputBar`: text field, send button, collapsed menu behavior
- `AppAgentTextField`: custom text field used by the input bar
- `AppAgentMenuButton`: compact menu button
- `ChatMessage`: UI-facing message model
- `ChatMessageCell`: table cell for user, assistant, streaming, error, and tool-info display

For deeper customization, build your own UI against `AISession` and `AIAgentEvent`.
