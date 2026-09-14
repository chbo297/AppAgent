---
description: Scaffold a new built-in tool with all 3 registration sites
argument-hint: <ToolName> [一句话用途]
---

为 `$ARGUMENTS` 创建新内置工具，严格按 CLAUDE.md "加新内置工具" 三步路径。

## 前置检查

1. 解析参数：第一个 token 是工具名（PascalCase，无 "Tool" 后缀，例如 `Reminder`）；剩余是用途。
2. 如果没给参数，反问用户："工具名（如 `Reminder`）？用途？输入参数？SafetyLevel（safe/moderate/sensitive/dangerous）？"
3. 读 `Sources/Core/Tools/ClipboardTool.swift` 和 `HapticTool.swift` 作为极简模式参考。
4. 读 `Sources/Core/Agent/AIAgent.swift` 找到 `registerBuiltInTools()` 方法。
5. 读 `Sources/Core/Agent/AIAgentProfile.swift` 找到 `defaultBuiltInToolPrompts`。

## 三步实现

### 步骤 1 — 创建 `Sources/Core/Tools/<Name>Tool.swift`

模板（最小骨架）：

```swift
import Foundation

public final class <Name>Tool: ToolProtocol {
    public static let toolName = "<snake_case_name>"  // LLM 看到的名字
    public let name: String = <Name>Tool.toolName
    public let description: String = "<一句话描述给 LLM 看>"
    public let safetyLevel: Tool.SafetyLevel = .<safe|moderate|sensitive|dangerous>

    public let parameters: Tool.Schema = Tool.Schema(
        properties: [
            "param1": .string(description: "..."),
        ],
        required: ["param1"]
    )

    public init() {}

    public func execute(input: JSONValue) async throws -> Tool.Output {
        // 解析 input、做业务、返回 .text/.json/.error
        return .text("...")
    }
}
```

要点：
- 类型是 `final class` + `public`；如果工具持有 actor 状态，加 `@unchecked Sendable` + `@Locked`。
- iOS 13 兼容：用到 iOS 14+ API 的代码用 `if #available(iOS 14, *) { ... } else { ... }` 双路径，参考 `AnthropicProvider.swift`。
- 输入解析失败抛 `AIAgentError.invalidToolInput(...)`，业务失败返回 `.error(...)`。

### 步骤 2 — 在 `AIAgent.registerBuiltInTools()` 注册

在 `Sources/Core/Agent/AIAgent.swift` 的 `registerBuiltInTools()` 中追加：

```swift
toolCentral.register(
    factory: ToolCentral.ClosureToolFactory(name: <Name>Tool.toolName) { _ in <Name>Tool() }
)
```

参考已有同类工具的注册位置（按字母或功能分组）。

### 步骤 3 — 在 `defaultBuiltInToolPrompts` 加 prompt

在 `Sources/Core/Agent/AIAgentProfile.swift` 的 `defaultBuiltInToolPrompts` 字典加：

```swift
<Name>Tool.toolName: """
## <Name>
<给 LLM 看的工具使用提示，包括何时该用、参数细节、注意事项>
""",
```

## 验证

1. 跑 `/build` 确认编译通过。
2. 检查 `Tests/Core/AppAgentCoreTests.swift` 是否需要加测试（早期阶段非强制）。
3. 提醒用户：如果工具属于"宿主 app 注入 Provider"类（如 `WebSearchTool`），还需要同步定义 Provider 协议，参考 `Sources/Core/Tools/Protocols/`。

## 输出

最后简洁列出：
- 创建的文件
- 修改的文件 + 行号
- 是否需要后续动作（Provider 协议、文档更新）
