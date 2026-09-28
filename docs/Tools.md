# Tools

AppAgent tools conform to `ToolProtocol`. Tools are registered in `ToolCentral` and copied into each `AISession` when the session is created.

## Host inspection boundary

`app_runtime_inspect`, `screenshot`, `app_hotfix`, `app_user_defaults` and
`app_sandbox_file` default to `scope: "host"`. Omit the parameter for normal work.
`detail: "full"` expands detail, not scope.

- `host`: inspect and operate on the host, excluding AppAgent-owned UI/runtime
  targets and internal settings/storage.
- `appagent`: inspect the SDK itself, only when explicitly requested and approved.
- `all`: both ownership domains, also requiring explicit approval.

An SDK-scope request uses `AISession.requestDecision(.appAgentInspection(...))`.
No responder means denial. Approvals and denials are coalesced within the current
turn and discarded when it ends or is cancelled; they are never persisted.
Read approval does not authorize writes or replace sensitive/dangerous operation
approval. `toolMutationPolicy = .readOnly` still rejects mutations.
Hosts can set `session.allowsAppAgentInspection = false` to disable SDK access.
No new model call, injected rule list, or confirmation is needed for host scope.

The overlay binds `session.inspectionSceneIdentifier` automatically. Headless or
custom UI integrations can bind a `UIWindowScene.session.persistentIdentifier`
themselves. Window paths are scoped to that scene; they do not follow the SDK
input window when it becomes key. Use the returned `W<n>:` handles rather than
assuming `n` is an index into a filtered window array. Subview indices retain their
actual UIKit positions, so paths must be refreshed after hierarchy changes.
For embedded/custom SDK UI, use `HostInspectionUIKit.markAppAgentOwned(_:)`
on its root; ordinary UIKit descendants inherit that ownership. Shared helper
libraries such as BOUIKit are not excluded wholesale.

Screenshots capture one target, not a composite of every window. Limited scopes
reject mixed-ownership subtrees and backdrop effects whose pixels cannot be
isolated; choose a safe subtree instead. Hotfix slots retain their original scope
and scene constraints when re-enabled, but never retain approval from an old turn.

Default storage filtering protects SDK preferences, raw sessions, memory/skills
storage, logs, message-capture caches and diagnostic exports. The normal
`Documents/AppAgent/files` workspace and screenshot artifacts remain available.
Dedicated `memory`, `todo`, `skills_*` and `session_*` tools retain their intended
functionality. Mixed `Library/Preferences` files require `all`; use
`app_user_defaults` for host-only key access.
The pathname checks cover the standard SDK locations and their resolved aliases.
Custom storage locations and deliberately broad host-configured workspaces remain
the host's responsibility. These checks do not track copied data/hard links or
prevent another thread replacing a file between validation and I/O.

`RuntimeInspectProvider` and `HotfixProvider` receive an immutable
`HostInspectionContext` on every call. Custom providers must enforce it before
enumeration, target resolution, mutation and patch re-enabling. Do not store a
mutable global scope on a shared provider. `AppStateProvider`,
`AppActionProvider` and `AppNavigationProvider` are host-only contracts; the SDK
cannot safely infer ownership from opaque host strings.

This is an inspection boundary, **not an in-process security sandbox**. Arbitrary
host getters, selectors or custom providers may have global effects; avoid
exposing them to untrusted callers. The whole-process memory footprint reported
by `app_device_info` still includes AppAgent and other SDKs—there is no fabricated
“SDK-subtracted” value. Public native provider APIs are trusted integration APIs,
not substitutes for the tool authorization path.

## ToolProtocol

```swift
public protocol ToolProtocol: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: Tool.Schema { get }
    var enabled: Bool { get }
    var group: String { get }
    var safetyLevel: Tool.SafetyLevel { get }

    func execute(
        arguments: [String: JSONValue],
        session: AISession
    ) async throws -> Tool.Output
}
```

The SDK provides defaults for `enabled`, `group`, and `safetyLevel`.

## Schemas

Tool input is described with `Tool.Schema` and `JSONSchema`:

```swift
let schema = Tool.Schema(
    properties: [
        "city": .string(description: "City name, for example San Francisco"),
        "unit": .string(
            description: "Temperature unit",
            enumValues: ["celsius", "fahrenheit"],
            defaultValue: .string("celsius")
        )
    ],
    required: ["city"]
)
```

Supported schema cases include string, number, integer, boolean, array, and object.

## Outputs

```swift
public enum Tool.Output: Sendable {
    case text(String)
    case json(JSONValue)
    case error(String)
}
```

The executor converts `Tool.Output` to a string tool result and feeds it back to the model.

## Registering Tools

Register shared tools before creating sessions:

```swift
let toolCentral = ToolCentral()
await toolCentral.register(WeatherLookupTool())

let agent = await AIAgentCentral.default.create(
    name: "main",
    profile: AIAgentProfile(identity: "You are helpful."),
    toolCentral: toolCentral,
    providerCentral: providerCentral,
    modelPolicy: ModelPolicy(primary: "anthropic/claude-sonnet-4-6")
)

let session = await agent.createSession()
```

The default `AIAgentProfile` registers built-in tools automatically. Pass `registerBuiltInTools: false` if you want only the tools you register.

## Per-Session Tool Factories

Use a factory when every session needs a fresh tool instance:

```swift
await toolCentral.registerFactory(
    name: "scratchpad",
    description: "Store short notes for this session.",
    parameters: Tool.Schema()
) {
    ScratchpadTool()
}
```

Factory-created tools and shared tools are both resolved through `ToolCentral`.

## Tool Policies

Tool policies narrow the set of tools available to an agent or session:

```swift
let profile = AIAgentProfile(
    identity: "You are helpful.",
    disabledBuiltInTools: ["clipboard", "text_to_speech"]
)

let session = await agent.createSession(
    toolPolicy: ToolCentral.ToolPolicy(
        allowedNames: ["weather_lookup", "todo"],
        excludedNames: nil
    )
)
```

Agent-level and session-level policies are applied together.

## Safety Levels

```swift
public enum Tool.SafetyLevel: String, Sendable {
    case safe
    case moderate
    case sensitive
    case dangerous
}
```

Sensitive and dangerous tools call `AIAgentDelegate` before execution:

```swift
func aiAgent(
    _ aiAgent: AIAgent,
    session: AISession,
    shouldExecuteTool name: String,
    safetyLevel: Tool.SafetyLevel,
    arguments: [String: JSONValue]
) async -> Bool {
    // Show host app confirmation UI here.
    true
}
```

## Complete Example

```swift
import Foundation
import AppAgent

public struct WeatherLookupTool: ToolProtocol {
    public let name = "weather_lookup"
    public let description = "Look up current weather for a city."
    public let parameters = Tool.Schema(
        properties: [
            "city": .string(description: "City name"),
            "unit": .string(
                description: "Temperature unit",
                enumValues: ["celsius", "fahrenheit"],
                defaultValue: .string("celsius")
            )
        ],
        required: ["city"]
    )
    public let group = "web"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(
        arguments: [String: JSONValue],
        session: AISession
    ) async throws -> Tool.Output {
        guard let city = arguments["city"]?.stringValue else {
            return .error("Missing required parameter: city")
        }

        let unit = arguments["unit"]?.stringValue ?? "celsius"

        return .json(.object([
            "city": .string(city),
            "unit": .string(unit),
            "temperature": .number(22),
            "condition": .string("clear")
        ]))
    }
}
```

Use it:

```swift
let toolCentral = ToolCentral()
await toolCentral.register(WeatherLookupTool())

let agent = await AIAgentCentral.default.create(
    name: "main",
    profile: AIAgentProfile(identity: "You can answer weather questions."),
    toolCentral: toolCentral,
    providerCentral: providerCentral,
    modelPolicy: ModelPolicy(primary: "anthropic/claude-sonnet-4-6")
)

let session = await agent.createSession()

for await event in session.sendMessage("What is the weather in Tokyo?") {
    switch event {
    case .streamingContent(let delta):
        print(delta, terminator: "")
    case .toolCallStarted(let call):
        print("\nCalling \(call.name)")
    case .completed(let result):
        print("\n\(result.text)")
    case .error(let error):
        print(error.localizedDescription)
    default:
        break
    }
}
```

## Built-In Tools

The SDK includes tools for clarification, memory, todos, sandboxed file access, skills, text-to-speech, delegation, session search, clipboard, haptics, app actions/navigation/state, web search, and vision analysis.

Host app tools such as app actions, app state, web search, and vision analysis require provider implementations supplied by the host app.
