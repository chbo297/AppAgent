# Tools

AppAgent tools conform to `ToolProtocol`. Tools are registered in `ToolCentral` and copied into each `AISession` when the session is created.

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
