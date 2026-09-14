# AppAgent SDK

iOS/macOS AIAgent SDK，为移动应用提供嵌入式 AI AIAgent 能力。Core 零第三方依赖；iOS/Catalyst ChatPanel 使用 BODragScroll，iOS 13+ / macOS 12+。

## 构建 & 测试

```bash
swift build
swift test        # 68 macOS core tests；UIKit 可用时还会包含 AppAgentUITests + AppAgentVoiceInputCoordinatorTests
```

Demo App 在 `Examples/iOS/AppAgentDemo.xcodeproj`，需要先 `cp Examples/iOS/Resources/config.json.example Examples/iOS/config.json` 并填入配置。

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
- `AppAgentOverlay` / `AppAgentWindow`: 独立 overlay window，空白区域触摸穿透宿主 App
- `AppAgentViewController`: 聊天界面，通过 `session.uiState.onChange` 响应式更新
- `AppAgentInputBar` / `AppAgentTextField` / `AppAgentMenuButton`: 输入栏与折叠菜单控件
- `ChatMessage` / `ChatMessageCell`: 气泡样式消息

## 代码规范

- 最低支持 iOS 13，不使用 iOS 14+ only API（除非有 `#available` 守卫）
- Sendable 严格，actor 隔离所有并发状态
- 所有 provider/storage 通过协议抽象，可替换
- AIAgent.init 所有参数有默认值，宿主 app 零配置可启动

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
| **改 UI** | `UI/AppAgentViewController.swift` + `UI/AppAgentOverlay.swift` + `Core/Session/SessionUIState.swift` |
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

### UI/ — UIKit 聊天界面

分层约定：录音识别（Manager）→ 语音交互状态机（Coordinator）→ 视图（InputBar/Overlay）→ AppAgentViewController 只做接线。

| 文件 | 职责 |
|------|------|
| `AppAgentOverlay.swift` | overlay 入口：创建 AppAgentWindow + AppAgentViewController，绑定 Agent/Session |
| `AppAgentWindow.swift` | 触摸穿透 UIWindow，空白区域不拦截宿主 App |
| `AppAgentInputBar.swift` | 输入栏视图：布局、输入源切换、手势识别；对外只发值事件（含 `AppAgentInputBarVoiceGestureEvent`），不决定自身 frame |
| `AppAgentInputBarFramePolicy.swift` | inputBar frame 纯函数策略（可用区域/展开收起/拖拽约束/松手吸附）+ `AppAgentInputBarLayoutStoring` 持久化抽象 |
| `AppAgentTextField.swift` | 输入框控件 |
| `AppAgentMenuButton.swift` | 折叠菜单按钮 |
| `AppAgentGeometry.swift` | 共享几何工具：clamp、CGPoint/CGSize/CGRect/UIEdgeInsets 近似相等 |
| `AppAgentKeyboardObserver.swift` | 键盘高度观察助手（keyboardWillChangeFrame 解析统一在此） |
| `AppAgentVoiceRecognitionManager.swift` | 录音识别服务（AVAudioEngine + SFSpeechRecognizer，audioQueue 隔离，AsyncStream 事件流）；`preferredLocales` 语言优先级默认中文优先；`AppAgentVoiceRecognitionProviding` 协议缝 |
| `VoiceInput/AppAgentVoiceInputCoordinator.swift` | 语音输入状态机：一次语音输入（按下→移动→松手→编辑收尾）的唯一状态主人；依赖识别协议 + releaseActionResolver + 触觉反馈抽象，输出语义 delegate 回调 |
| `ChatMessage.swift` | UI 层消息模型 (role, text, status, toolInfo) |
| `ChatMessageCell.swift` | 气泡样式 UITableViewCell |

### UI/ChatPanel/ — 对话流面板

| 文件 | 职责 |
|------|------|
| `AppAgentChatPanelView.swift` | 固定最大尺寸的卡片视觉：顶部圆角/阴影/拖拽条/内容区；不持有手势和运动策略 |
| `AppAgentChatPanelGeometry.swift` | peek/half/full 业务档位和固定面板尺寸的纯几何结果 |
| `AppAgentChatPanelCoordinator.swift` | BODragScroll 唯一适配层：尺寸、detent、列表捕获、程序化移动和稳定落位同步 |
| `AppAgentChatMessageListView.swift` | 聊天内容区：复用 ChatMessage/ChatMessageCell，处理列表可见区补偿和条件式流式跟随 |
| `AppAgentMockChatResponder.swift` | 模拟回复源（UI 调试阶段）：began/partial/completed 事件形状对齐真实流式通路 |

### UI/AppAgentViewController/ — 控制器（组装根）

| 文件 | 职责 |
|------|------|
| `AppAgentViewController.swift` | 成员与生命周期；持有 coordinator/store/observer |
| `AppAgentViewController+InputBarDelegate.swift` | inputBar 事件路由 |
| `AppAgentViewController+InputBarLayout.swift` | frame 策略接线层（状态 + 视图应用，计算全部委托 FramePolicy） |
| `AppAgentViewController+Keyboard.swift` | 键盘高度 → inputBar 避让 |
| `AppAgentViewController+VoiceInput.swift` | 语音输入接线层：手势事件 → coordinator；coordinator 语义回调 → overlay/inputBar/session |
| `AppAgentViewController+SessionBinding.swift` | session ↔ UI、sendMessage |
| `AppAgentViewController+ChatPanel.swift` | 对话流面板接线：环境布局、程序化档位、键盘避让和统一消息分发；默认走真实 session |

### UI/VoiceInputOverlay/ — 语音输入浮层

| 文件 | 职责 |
|------|------|
| `AppAgentVoiceInputOverlayView.swift` | 浮层组合根：手势阶段状态渲染 + releaseAction 几何判定 + 编辑态形态切换 |
| `AppAgentVoiceEditModeSession.swift` | 编辑会话对象：textView/取消/发送按钮、键盘跟随、点/滑收放键盘；与手势态共享同一 bubbleView 保证形变连续 |
| `AppAgentVoiceBubbleView.swift` | 气泡视图：形状/位置全由 path 表达，状态切换是连续 path 形变；contentView 内容容器与 path 同节奏动画 |
| `AppAgentVoiceWaveformView.swift` | 波形视图（CAShapeLayer path，支持尺寸/颜色渐变动画） |
| `AppAgentVoiceActionZoneView.swift` | 取消/编辑弧形按钮 |
| `AppAgentVoiceBottomPanelView.swift` | 底部“语音”弧形面板 |
| `AppAgentVoiceArcMetrics.swift` | 弧形几何共享定义 |
| `AppAgentVoiceInputOverlayState.swift` | 识别可视状态 + 松手行为枚举 |

### Tests/ (3 files)

| 文件 | 职责 |
|------|------|
| `Tests/Core/AppAgentCoreTests.swift` | 68 测试用例，覆盖 JSON、消息、Provider、SSE、存储、Agent、Memory、UIState、Prompt、LLMExecutor |
| `Tests/UI/AppAgentUITests.swift` | UIKit 可用时覆盖 ChatMessage 创建 + 流式状态测试 |
| `Tests/UI/AppAgentVoiceInputCoordinatorTests.swift` | 语音输入状态机测试：手势转移、震动 diff、发送回填顺序、编辑交接（识别/触觉均为替身） |
| `Tests/UI/AppAgentChatPanelGeometryTests.swift` | 对话流面板测试：几何档位、紧凑窗口去重、列表补偿和 BODragScroll 首次/程序化落位 |
