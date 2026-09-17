# AppAgent SDK

iOS/macOS AIAgent SDK，为应用提供嵌入式 AI AIAgent 能力。Core 零第三方依赖；完整 UIKit UI 支持 iOS 13+ / Mac Catalyst 13.1+，原生 macOS 12+ 提供 Core；iOS/Catalyst ChatPanel 使用 BODragScroll。

> **命名约定（长期生效）**：本工程 **AppAgent 即「app agent」**。任何文档/对话/代码注释中提到「app agent」都指本工程。
> `liji` 分支新增 `Sources/Core/Liji/`：OneAPI 多协议 Provider 工厂、liji_server 客户端、运行时内省 / 热修复的宿主 provider 协议与工具。集成说明见 [`docs/Liji.md`](docs/Liji.md)。
> 关联：后台服务 liji_server（`/Users/bdmap/Baidu/baidu/personal-code/liji_server`）、百度地图壳工程 liji_pub（分支 `feature_liji`）。

## 构建 & 测试

```bash
swift build
swift test        # 原生 macOS Core：68 tests
xcodebuild -project Examples/iOS/AppAgentDemo.xcodeproj -scheme AppAgentDemo -configuration Debug -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AppAgent -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst,name=My Mac' test  # Core + UIKit：102 tests
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
| `Tool.Output` | `Core/Tool/ToolTypes.swift` | 工具执行结果 (text/json/error) |
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

## 内置工具 (18个)

**自动注册 (13个):** clarify, memory, todo, file_read, file_write, file_search, skills_list, skill_view, skill_manage, text_to_speech, delegate_task, session_search, clipboard, haptic

**需宿主 app 注入 Provider (5个):** app_action, app_navigate, app_state, web_search, vision_analyze

通过 `AIAgentProfile.disabledBuiltInTools` 禁用指定工具。

## 子系统

### Memory
- `MemoryStore` actor: 协调 `MemoryStorage`(长期) + `HotMemory`(热，键值对)
- 长期记忆: `MemoryEntry` (content, tags, source)，搜索为 case-insensitive substring 匹配
- 存储: `FileMemoryStorage` (JSON 文件) / `InMemoryMemoryStorage`

### Skills
- `SkillsManager` actor: 从 Bundle + Documents 加载技能 (markdown + YAML frontmatter)
- 三个工具暴露给 LLM: skills_list → skill_view → skill_manage

### Provider (Anthropic)
- `AnthropicProvider`: 唯一实现。iOS 15+ 用 URLSession.bytes，iOS 13/14 降级到 URLSessionDataDelegate
- `AnthropicMapper`: 双向映射 (AIAgentMessage ↔ Anthropic wire format)
- `SSEParser`: 逐行 SSE 解析
- `ConcurrencyLimiter`: actor FIFO 并发控制 (默认 limit=5)

### UI
- `ChatViewController` (UIKit): 即插即用聊天界面，通过 `session.uiState.onChange` 响应式更新
- `ChatMessage` / `ChatMessageCell`: 气泡样式消息

## 代码规范

- 当前项目仍处于本地开发、未发布阶段：不需要为了兼容旧 API 而保守。若重构能显著提升结构清晰度、命名一致性或长期可维护性，可以直接调整 public/internal API，并同步更新本仓库调用点。
- 最低支持 iOS 13，不使用 iOS 14+ only API（除非有 `#available` 守卫）
- Sendable 严格，actor 隔离所有并发状态
- 所有 provider/storage 通过协议抽象，可替换
- AIAgent.init 所有参数有默认值，宿主 app 零配置可启动

## BODragScroll 联合开发与发布

- AppAgent 仓库位于当前目录；BODragScroll 是同级、独立的 Git 仓库 `../BODragScroll`。涉及面板拖拽或嵌套滚动时，可以直接修改该源码仓并与 AppAgent 联调。
- Demo 工程直接引用 `../BODragScroll`；根 Swift Package 本地联调时运行 `Scripts/Dependencies/use-local-bodragscroll.sh` 进入 editable checkout，结束后可运行 `Scripts/Dependencies/use-released-bodragscroll.sh` 恢复正式依赖。
- 两个仓库的改动、测试、提交和版本发布必须分别管理；不要把 BODragScroll 源码混入 AppAgent 提交。若 AppAgent 依赖尚未发布的 BODragScroll API，先提交并发布/打标 BODragScroll，再更新 AppAgent 的 SwiftPM/CocoaPods 版本声明并发布 AppAgent。
- AppAgent 正式发布必须通过 SwiftPM/CocoaPods 引入 BODragScroll，不能依赖本机兄弟目录；禁止提交 `Packages/` 中的本地符号链接或其他机器相关路径。

## BOUIKit（UIView hit-testing 便利层）

- 依赖 [`chbo297/BOUIKit`](https://github.com/chbo297/BOUIKit)（SwiftPM `from: "0.1.1"`，源码仓在同级 `../BOUIKit`），提供 `bo_hitAreaOutsets`、`bo_skipsSelfInHitTest`、`bo_pointInsideJudge`、`bo_hitTestHook`。同一个包也被 BWTimeGallery 使用。
- 它通过 `method_exchangeImplementations` 换掉 `UIView.point(inside:with:)` 与 `hitTest(_:with:)`，首次设置有效配置时惰性安装，作用域是整个进程；集成文档需向宿主 app 说明这一点。
- 在 macOS 上编译为空模块，因此 AppAgent target 无条件依赖即可；`Sources/UI` 里使用时照常放在 `#if canImport(UIKit)` 内。
- 已接入点：`AppAgentChatPanelContainerView` 的「命中自己就穿透」用 `bo_skipsSelfInHitTest`。其余手写 hit-testing（`AppAgentWindow`、`AppAgentInputBar` 输入区扩大、语音面板路径命中、调试窗口）暂未迁移。

## 文件导航快速索引

"我要做 X 就去看 Y"：

| 场景 | 关键文件（Sources/ 下） |
|------|----------------------|
| **加新内置工具** | `Core/Tools/` 新建文件 → `Core/Agent/AIAgent.swift` registerBuiltInTools() 注册 → `Core/Agent/AIAgentProfile.swift` defaultBuiltInToolPrompts 加提示词 |
| **加宿主 app 注入工具** | 同上 + `Core/Tools/Protocols/` 新建 Provider 协议 |
| **改 session 管理** | `Core/Session/AISession.swift` + `Core/Session/AISessionManager.swift` |
| **改 prompt 组装** | `Core/Agent/AIAgent.swift` assembleFullSystemPrompt() → `Core/Agent/PromptBuilder.swift` → `Core/Memory/MemoryStore.swift` assembleMemoryPrompts() |
| **改执行循环** | `Core/Session/LLMExecutor.swift` runLoop() + `Core/Agent/ToolLoopDetector.swift` + `Core/Agent/ContextCompressor.swift` |
| **改 provider/模型** | `Core/Model/ModelProvider.swift` 协议 + `Core/Providers/Anthropic/` 参考实现 + `Core/Model/ModelProviderCentral.swift` |
| **改 UI** | `UI/ChatViewController.swift` + `Core/Session/SessionUIState.swift` |
| **改 memory 系统** | `Core/Memory/MemoryStore.swift` 协调 + `Core/Memory/MemoryStorage.swift` 协议 + `Core/Tools/MemoryTool.swift` LLM 接口 |
| **加测试** | `Tests/Core/AppAgentCoreTests.swift`（用 InMemorySessionStorage / InMemoryMemoryStorage 隔离） |

## 完整文件清单

### Core/Agent/ — 核心编排 (13 files)

| 文件 | 职责 |
|------|------|
| `AIAgent.swift` | 顶层 facade：持有 session/memory/skills，组装 system prompt，注册内置工具 |
| `AIAgentProfile.swift` | Agent 配置：promptBuilders、identity、maxIterations、toolPrompts、memoryConfig |
| `AIAgentDelegate.swift` | 宿主 app 回调协议：session 生命周期、工具授权、澄清请求 |
| `AIAgentMask.swift` | session 创建时的不可变配置快照（profile、toolPolicy、toolCentral），解耦 session 与 Agent 运行时变更 |
| `AIAgentCentral.swift` | 全局 Agent 注册中心 actor，提供懒加载 "main" agent |
| `PromptBuilder.swift` | 静态文本 / 动态闭包的 system prompt 片段 |
| `ToolLoopDetector.swift` | 检测工具调用循环（精确重复 + A-B 乒乓），防止无限执行 |
| `ContextCompressor.swift` | 上下文压缩协议 |
| `SimpleContextCompressor.swift` | 默认压缩实现：裁剪旧 tool result，保护首尾，摘要中间 |
| `MessageContextProvider.swift` | 每条消息的易变上下文注入协议（如当前时间、GPS） |
| `MessageContextEntry.swift` | 单条上下文条目数据结构 (label + value) |
| `MessageContextFormatter.swift` | 将上下文条目 + 用户文本格式化为 fenced wire format |
| `BuiltInMessageContext.swift` | 内置 provider：始终注入当前日期时间 + 时区 |

### Core/Session/ — Session 生命周期 (5 files)

| 文件 | 职责 |
|------|------|
| `AISession.swift` | 单次对话：持有 provider、modelId、messages、tools、uiState；sendMessage 创建 Executor 驱动对话 |
| `AISessionManager.swift` | Session 生命周期管理：创建、删除、持久化、恢复 |
| `LLMExecutor.swift` | LLM ↔ tool 执行循环引擎：流式调用、工具执行、重试、上下文压缩 |
| `SessionStorage.swift` | SessionStorage 协议 + InMemory/File 实现 + SessionSnapshot Codable |
| `SessionUIState.swift` | 线程安全 UI 中间状态：流式文本、错误、自定义状态；通过 onChange 回调观察 |

### Core/Model/ — LLM Provider 抽象 (4 files)

| 文件 | 职责 |
|------|------|
| `ModelProvider.swift` | ModelProvider 协议、ModelSpec、ProviderStreamEvent、ContentOrCacheControl、APIProtocol |
| `ModelProviderCentral.swift` | Provider 注册中心 actor：注册、解析 "providerName/modelId"、resolveDefault；定义 ModelPolicy |
| `SystemPrompt.swift` | 简单 text wrapper |
| `ErrorClassifier.swift` | API 错误分类 → 恢复策略（重试、回退、压缩等） |

### Core/Providers/Anthropic/ — Anthropic 实现 (4 files)

| 文件 | 职责 |
|------|------|
| `AnthropicProvider.swift` | ModelProvider 实现：构建 HTTP 请求，SSE 流式（iOS 15+ bytes / iOS 13 delegate 降级） |
| `AnthropicMapper.swift` | 双向映射：AIAgentMessage ↔ Anthropic wire format；SSE 事件解析 |
| `AnthropicTypes.swift` | Anthropic API Codable 类型 |
| `SSEParser.swift` | 逐行 SSE 解析器 |

### Core/Tool/ — 工具注册与协议 (2 files)

| 文件 | 职责 |
|------|------|
| `ToolCentral.swift` | 工具注册中心 actor：共享实例 + ToolFactory；ToolPolicy 过滤；resolveTools |
| `ToolTypes.swift` | Tool 命名空间 (Schema/SafetyLevel/Output) + ToolProtocol |

### Core/Tools/ — 内置工具实现 (18 files)

| 文件 | 职责 |
|------|------|
| `ClarifyTool.swift` | 暂停执行向用户提问 |
| `MemoryTool.swift` | 暴露持久记忆 (add/search/remove) 给 LLM |
| `TodoTool.swift` | Session 级任务列表，存储在 uiState |
| `FileReadTool.swift` | 沙箱内读取文本文件 |
| `FileWriteTool.swift` | 沙箱内写入文本文件 |
| `FileSearchTool.swift` | 沙箱内搜索文件内容或按名查找 |
| `SkillsTool.swift` | 三合一：SkillsListTool / SkillViewTool / SkillManageTool |
| `TextToSpeechTool.swift` | AVSpeechSynthesizer 文字转语音 |
| `DelegateTaskTool.swift` | 生成子 session 处理子任务 |
| `SessionSearchTool.swift` | 搜索历史对话 |
| `ClipboardTool.swift` | 系统剪贴板读写 |
| `HapticTool.swift` | 触觉反馈 |
| `AppActionTool.swift` | 通过 AppActionProvider 执行宿主 app 业务动作 |
| `AppNavigateTool.swift` | 通过 AppNavigationProvider 执行应用内导航 |
| `AppStateTool.swift` | 通过 AppStateProvider 读取当前 app 状态 |
| `WebSearchTool.swift` | 通过 WebSearchProvider 执行网络搜索 |
| `VisionAnalyzeTool.swift` | 通过 VisionAnalyzeProvider 执行图片分析 |
| `SandboxPathResolver.swift` | 安全路径解析，防止目录遍历攻击 |

### Core/Tools/Protocols/ — 宿主 App Provider 协议 (3 files)

| 文件 | 职责 |
|------|------|
| `AppActionProvider.swift` | AppActionProvider 协议 + AppAction 数据结构 |
| `AppNavigationProvider.swift` | AppNavigationProvider 协议 + AppRoute 数据结构 |
| `AppStateProvider.swift` | AppStateProvider 协议 |

> **注**: `WebSearchProvider` 和 `VisionAnalyzeProvider` 协议直接定义在各自的工具文件内（`WebSearchTool.swift`、`VisionAnalyzeTool.swift`），不在此目录。

### Core/Memory/ — 记忆子系统 (6 files)

| 文件 | 职责 |
|------|------|
| `MemoryStore.swift` | 协调 actor：管理长期 + 热记忆，组装 memory prompt，输入消毒 |
| `MemoryStorage.swift` | MemoryStorage 协议 + InMemoryMemoryStorage（测试用） |
| `FileMemoryStorage.swift` | 文件持久化（单 JSON 文件） |
| `MemoryConfig.swift` | 配置：longTerm/hot 开关、最大条目数、最大条目长度 |
| `MemoryEntry.swift` | 单条记忆条目：content、tags、source (user/aiAgent/system)、timestamp |
| `HotMemory.swift` | 临时进程内 key-value 记忆 actor（不持久化） |

### Core/Skills/ — 技能子系统 (2 files)

| 文件 | 职责 |
|------|------|
| `SkillsManager.swift` | 技能发现 actor：从 Bundle/Documents 加载，YAML frontmatter 解析，创建/删除 |
| `Skill.swift` | 技能数据结构：name、description、category、markdown content |

### Core/Message/ — 消息与事件 (3 files)

| 文件 | 职责 |
|------|------|
| `AIAgentMessage.swift` | Provider 无关的消息类型，Content enum (text/toolUse/toolResult)，Codable |
| `AIAgentEvent.swift` | 流式事件枚举 + AIAgentFinish 结果类型 |
| `AIAgentError.swift` | AIAgentError + ModelError 错误枚举 |

### Core/Foundation/ — 共享基础设施 (9 files)

| 文件 | 职责 |
|------|------|
| `JSONValue.swift` | 类型安全 JSON enum + Codable + 便捷访问器 |
| `JSONSchema.swift` | 递归 indirect enum 描述 JSON Schema（工具参数定义用） |
| `Logger.swift` | 集中日志：级别过滤、自定义 handler、敏感数据自动脱敏 |
| `Locked.swift` | 属性包装器：@Locked / @WeakLocked / @TrackedLocked + ReadersWriterLock（os_unfair_lock） |
| `ConcurrencyLimiter.swift` | Actor FIFO 并发限制器（API 请求限流） |
| `RetryPolicy.swift` | 指数退避 + 抖动重试配置 |
| `ReadySignal.swift` | 一次性 actor 就绪信号，支持多等待者 |
| `StableSort.swift` | 按名称稳定排序工具函数 |
| `AsyncStreamCompat.swift` | AsyncStream.makePair() iOS < 17 兼容垫片 |

### UI/ — UIKit 聊天界面 (3 files)

| 文件 | 职责 |
|------|------|
| `ChatViewController.swift` | 即插即用聊天控制器：绑定 Agent+Session，处理流式显示、键盘、session 切换 |
| `ChatMessage.swift` | UI 层消息模型 (role, text, status, toolInfo) |
| `ChatMessageCell.swift` | 气泡样式 UITableViewCell |

### Tests/ (2 files)

| 文件 | 职责 |
|------|------|
| `Tests/Core/AppAgentCoreTests.swift` | 62 测试用例，覆盖 JSON、消息、Provider、SSE、存储、Agent、Memory、UIState、Prompt |
| `Tests/UI/AppAgentUITests.swift` | ChatMessage 创建 + 流式状态测试 |
