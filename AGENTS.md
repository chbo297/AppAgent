# AppAgent SDK

iOS/macOS AIAgent SDK，为应用提供嵌入式 AI AIAgent 能力。Core 零第三方依赖；完整 UIKit UI 支持 iOS 15+ / Mac Catalyst 15+，原生 macOS 12+ 提供 Core；iOS/Catalyst ChatPanel 使用 BODragScroll。

> **命名约定（长期生效）**：本工程 **AppAgent 即「app agent」**。任何文档/对话/代码注释中提到「app agent」都指本工程。
> **边界（长期生效）**：AppAgent 只做**通用机制与协议**。任何业务/领域能力（某个 App 的后台服务客户端、
> 地图能力、业务面板等）都由**宿主**实现并经 `ToolCentral.register(_:)` / `ModelProviderCentral.register`
> / `DecisionResponderCentral` / Skills 注册进来；AppAgent 不感知、不引用、不依赖具体宿主。
> `Sources/Core/HostCapability/` 放的是宿主能力的**协议 + 默认实现 + 装配**（运行时内省 / 热修复 / 消息捕获），
> 通用；`Sources/Core/Model/EndpointProviderFactory.swift` 按端点参数造 Provider，也不绑定任何宿主配置类型。

## 构建 & 测试

```bash
swift build
swift test        # 原生 macOS Core（数量随开发变化，以实际输出为准）
xcodebuild -project Examples/iOS/AppAgentDemo.xcodeproj -scheme AppAgentDemo -configuration Debug -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AppAgent -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst,name=My Mac' test  # Core + UIKit 全量
Scripts/simulator-selfcheck.sh   # iOS 模拟器上把全部工具跑一遍（见 docs/Diagnostics.md）
```

Demo App 在 `Examples/iOS/AppAgentDemo.xcodeproj`，支持 iOS 和 Mac Catalyst；需要先复制 `Resources/config.json.example` 为 `Resources/config.json` 并填入配置。

## 架构概览

```
AIAgent (facade)
  ├── AIAgentProfile         promptBuilders(核心)、identity、memory 配置、工具开关
  ├── modelPolicy: ModelPolicy?  "providerName/modelId" 格式，primary + fallbacks
  ├── toolCentral          ToolCentral (.default 或注入)
  ├── providerCentral      ModelProviderCentral (.default 或注入)
  ├── memoryStore          MemoryStore (长期 + 热记忆)
  ├── sessionManager       AISessionManager → [AISession]
  └── skillsManager        SkillsManager (技能发现与生命周期)

AISession (单次对话)
  ├── provider: ModelProvider?  创建时 resolve 的 provider 实例
  ├── modelId: String?         创建时 resolve 的 model id
  ├── agentMask: AIAgentMask?  配置快照 + 弱引用来源 AIAgent（agentMask.agent）
  ├── messages: [AIAgentMessage]
  ├── installedTools       从 toolCentral 创建的 per-session 工具实例
  ├── uiState              SessionUIState (流式文本、错误状态，UI 层通过 onChange 观察)
  └── sendMessage(text) → AsyncStream<AIAgentEvent>
        └── LLMExecutor (provider ↔ tool 循环)
              ├── 组装 system prompt + tools
              ├── provider.streamCompletion(modelId:)
              ├── 工具执行 (检查 safetyLevel + delegate 授权)
              └── 循环直到 endTurn 或 maxIterations
```

## 两个 Central — `.default` 模式

类似 `NotificationCenter.default`，允许创建新实例但一般使用默认实例。

- **`ToolCentral`** — 工具注册中心。存储共享工具实例 + ToolFactory（按 session 创建实例）。
- **`ModelProviderCentral`** — Provider 注册中心。通过 `"providerName/modelId"` 复合引用解析 provider+model。

AIAgent.init 接收两者作为参数（默认 `.default`），AISession 通过 `agentMask?.toolCentral` 访问工具注册中心。Session 直接持有 `provider` 和 `modelId`，创建时由 AIAgent resolve。

## 核心类型速查

| 类型 | 文件 | 说明 |
|------|------|------|
| `ModelProvider` (protocol) | `Core/Model/ModelProvider.swift` | LLM provider 抽象，唯一实现: `AnthropicProvider`。提供 `modelSpec(for:)` 查询 |
| `ModelSpec` | `Core/Model/ModelProvider.swift` | 模型配置 (id, reasoning, inputModalities, contextWindow, maxTokens) |
| `ModelPolicy` | `Core/Model/ModelProviderCentral.swift` | 模型选择策略 (primary + fallbacks，"providerName/modelId" 格式) |
| `ToolProtocol` (protocol) | `Core/Tool/ToolTypes.swift` | 工具协议 (name, description, parameters, execute) |
| `Tool` (enum namespace) | `Core/Tool/ToolTypes.swift` | 命名空间，包含 Schema、SafetyLevel、Output |
| `Tool.Schema` | `Core/Tool/ToolTypes.swift` | 工具输入参数 schema (properties + required) |
| `Tool.SafetyLevel` | `Core/Tool/ToolTypes.swift` | 安全级别 (safe/moderate/sensitive/dangerous) |
| `Tool.Output` | `Core/Tool/ToolTypes.swift` | 工具执行结果 (text/json/error/image) |
| `JSONSchema` (indirect enum) | `Core/Foundation/JSONSchema.swift` | 通用 JSON Schema 描述（递归，按类型分 case） |
| `ToolCentral.ToolFactory` | `Core/Tool/ToolCentral.swift` | 按 session 创建工具实例的工厂 |
| `ToolCentral.ClosureToolFactory` | `Core/Tool/ToolCentral.swift` | 闭包方式创建工具的便捷工厂 |
| `AIAgentMessage` | `Core/Message/AIAgentMessage.swift` | 消息 (role, content: text/toolUse/toolResult) |
| `AIAgentEvent` | `Core/Message/AIAgentEvent.swift` | 流式事件 (streamingContent, toolCall*, completed, error) |
| `AIAgentError` / `ModelError` | `Core/Message/AIAgentError.swift` | 错误类型 |
| `SystemPrompt` | `Core/Model/SystemPrompt.swift` | 简单 text wrapper |
| `ContentOrCacheControl<T>` | `Core/Model/ModelProvider.swift` | .content(T) \| .cacheControl 缓存标记 |
| `JSONValue` | `Core/Foundation/JSONValue.swift` | 类型安全 JSON (string/number/bool/null/array/object) |

## System Prompt 组装顺序

`AIAgent.assembleFullSystemPrompt(for:)`:
1. PromptBuilders (identity 作为 [0]，静态文本或动态闭包)
2. Memory (热记忆 "# Current Context" + 长期记忆 "# Memory") + `.cacheControl`
3. Tool prompts ("# Using your tools" — 内置 + 宿主 app toolPrompts 合并)
4. `.cacheControl`
5. AISession 级 promptParts

## 内置工具

**自动注册（`AIAgent.registerBuiltInTools()`，21 个）**：clarify, memory, todo, file_read, file_write,
file_search, skills_list, skill_view, skill_manage, text_to_speech, delegate_task, session_search,
session_manage, clipboard, haptic, web_fetch, app_user_defaults, app_sandbox_file, app_device_info,
app_runtime_inspect, screenshot（最后两个仅在 `canImport(UIKit)` 时注册）。

**需宿主注入 Provider / 自行注册**：app_action, app_navigate, app_state, web_search。

**宿主能力工具（`Core/HostCapability/HostToolset.swift` 按可用 provider 装配，4 个）**：
`app_runtime_inspect`（看：view_tree / view_info；改：view_set；模拟用户操作：view_activate /
page_navigate / page_scroll；反射：view_invoke）、`app_hotfix`、
`app_hook_capture`、`app_web_inspect`。协议与默认实现都在 `Core/HostCapability/`。

「让界面动起来」优先用 `page_navigate` / `view_activate`，不要用反射硬凑：真机上一次
「切到 profile 页」因为没有这两个 op，模型绕着 `view_invoke` 试了 9 轮、烧掉 231 秒。

通过 `AIAgentProfile.disabledBuiltInTools` 禁用指定工具；工具按 `group` 归类
（core / session / host-storage / host-runtime），可用 `ToolPolicy` 的 allowedGroups / excludedGroups
整组开关。安全模型与输出预算见 `docs/ToolSafety.md`。

## 子系统

### Memory
- `MemoryStore` actor: 协调 `MemoryStorage`(长期) + `HotMemory`(热，键值对)
- 长期记忆: `MemoryEntry` (content, tags, source)，搜索为 case-insensitive substring 匹配
- 存储: `FileMemoryStorage` (JSON 文件) / `InMemoryMemoryStorage`

### Skills
- `SkillsManager` actor: 从 Bundle + Documents 加载技能 (markdown + YAML frontmatter)
- 三个工具暴露给 LLM: skills_list → skill_view → skill_manage

### Provider (Anthropic)
- `AnthropicProvider`: 唯一实现。SSE 流式统一走 `URLSession.bytes`（最低 iOS 15 / macOS 12，原来的 iOS 13/14 `URLSessionDataDelegate` 降级路径已删除）
- `AnthropicMapper`: 双向映射 (AIAgentMessage ↔ Anthropic wire format)
- `SSEParser`: 逐行 SSE 解析
- `ConcurrencyLimiter`: actor FIFO 并发控制 (默认 limit=5)

### UI
- `ChatViewController` (UIKit): 即插即用聊天界面，通过 `session.uiState.onChange` 响应式更新
- `ChatMessage` / `ChatMessageCell`: 气泡样式消息

## 怎么汇报

- **先讲人话，再讲细节。** 任何清单、排查结论、方案选项，开头先用「没碰过这块代码的人也能看懂」的话
  说清**是什么问题、影响什么、需要谁做什么决定**；类名、行号、参数、时序一律往后放。
- 自检标准：把开头那段单独拿给一个没读过这段代码的人看，他应该能判断「这事要不要做、该谁做」。
  凡是必须翻代码才能看懂的内容，都不属于开头。
- 每条结论要能追到证据（日志行、实测数字、`文件:行号`）。**没验证过的明确写「未验证」**，
  不要和已验证的结论混在一起说 —— 「编译过了」不等于「跑通了」。

## 代码规范

- 当前项目仍处于本地开发、未发布阶段：不需要为了兼容旧 API 而保守。若重构能显著提升结构清晰度、命名一致性或长期可维护性，可以直接调整 public/internal API，并同步更新本仓库调用点。
- 最低支持 iOS 15，不使用 iOS 16+ only API（除非有 `#available` 守卫）。升到 15 是为了 agent 回复的 markdown 渲染直接用系统 `AttributedString(markdown:)`，不必自研解析器或引入第三方依赖。
- Sendable 严格，actor 隔离所有并发状态
- 所有 provider/storage 通过协议抽象，可替换
- AIAgent.init 所有参数有默认值，宿主 app 零配置可启动

## 按需加载的模块文档

AGENTS.md 只留**跨模块、违反就出事**的约定和导航。下面每份文档都是「改到对应模块时才读」，
平时不进上下文；动这些模块之前**必须先读对应那份**，里面每条都来自真机踩过的坑。

- `docs/UILayer.md` — 对话列表两层消息 / 过程区 / 行高与身份缓存 / 输入栏动作槽 / 面板几何与键盘联动。
  改 `Sources/UI/` 就读它。
- `docs/TurnLifecycle.md` — `AIAgentTurnRecord`、阶段推进、「每轮恰好一个终止事件」契约。
  改 `LLMExecutor` / 排查「一直转圈」就读它。
- `docs/ToolSafety.md` — 工具输出预算、op 级授权、范围判定、运行时内省 / 热修复 / 抓包 / `web_fetch`。
  加改工具就读它。
- `docs/Decisions.md` — `requestDecision` 责任链与决策卡片，continuation 不许漏。
- `docs/Diagnostics.md` — 落盘日志、诊断包、模拟器能力自检（工具回归的主力手段）。
- `docs/Dependencies.md` — BODragScroll / BOUIKit 两个兄弟仓的联合开发与发版顺序。
- `docs/FileMap.md` — 「我要做 X 就去看 Y」+ 完整文件清单。
- `docs/SessionHistory.md` / `docs/Providers.md` / `docs/Tools.md` / `docs/Architecture.md` /
  `docs/GettingStarted.md` / `docs/UICustomization.md` / `docs/HostInspectionExamples.md` — 既有专题文档。

## 不读文档也不许破的几条

违反这几条会直接变成用户可见的故障，细节各见上面对应文档：

- **每轮恰好一个终止事件**（`.completed` / `.error`）。漏发 = 界面一直转圈，重复发 = 一轮被收两次。
  终止只走 `TurnJournal` 这一个出口，别自己 yield。→ `docs/TurnLifecycle.md`
- **一轮的状态只有一个真相来源：`AIAgentTurnRecord`**。不许再从 `uiState` 另读一份拼状态。
  → `docs/TurnLifecycle.md`
- **wire 层（`AIAgentMessage`）≠ 展示层（`ChatMessage`）**，归属只认 Core 打的 `turnID`，不靠位置猜；
  组装入口只有 `ChatMessageAssembler.assemble(...)` 一个。→ `docs/UILayer.md`
- **跨重建的 UI 状态（行高、展开态、过程阅读位置）只能挂在稳定身份上**（`turnID` + role，
  见 `ChatRowIdentity`），不能用每次组装都新生成的 `ChatMessage.id`。→ `docs/UILayer.md`
- **AppAgent 不感知具体宿主**：业务能力一律由宿主注册进来（见文件头「边界」）。
- **授权是 op 级的，缺参数不降级为 safe**；`toolMutationPolicy = .readOnly` 时直接失败而不是问人。
  → `docs/ToolSafety.md`
- **改 BODragScroll / BOUIKit 必须先发版再升 AppAgent**，提交里不许出现本地 path 依赖。
  → `docs/Dependencies.md`
