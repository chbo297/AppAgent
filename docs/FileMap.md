# 文件职责导航

> **什么时候读这份**：不确定某个能力落在哪个文件时。文件数会随开发变化，以实际目录为准，
> 本清单只保证「职责描述」有效。

## 文件导航快速索引

"我要做 X 就去看 Y"：

| 场景 | 关键文件（Sources/ 下） |
|------|----------------------|
| **加新内置工具** | `Core/Tools/` 新建文件 → `Core/Agent/AIAgent.swift` registerBuiltInTools() 注册 → `Core/Agent/AIAgentProfile.swift` defaultBuiltInToolPrompts 加提示词 |
| **加宿主 app 注入工具** | 同上 + `Core/Tools/Protocols/` 新建 Provider 协议 |
| **改 session 管理** | `Core/Session/AISession.swift` + `Core/Session/AISessionManager.swift` |
| **改 prompt 组装** | `Core/Agent/AIAgent.swift` assembleFullSystemPrompt() → `Core/Agent/PromptBuilder.swift` → `Core/Memory/MemoryStore.swift` assembleMemoryPrompts() |
| **改执行循环** | `Core/Session/LLMExecutor.swift` runLoop() + `Core/Agent/ToolLoopDetector.swift` + `Core/Agent/ContextCompressor.swift` |
| **查「切后台回来不动 / 一直转圈」** | `Core/Foundation/StreamIdleGuard.swift` + `Core/Foundation/BackgroundActivity.swift` + `Core/Session/LLMExecutor.swift` 流消费段（先读 `docs/TurnLifecycle.md` → 打断与恢复） |
| **改 provider/模型** | `Core/Model/ModelProvider.swift` 协议 + `Core/Providers/Anthropic/` 参考实现 + `Core/Model/ModelProviderCentral.swift` |
| **改 UI** | `UI/AppAgentOverlay.swift` + `UI/AppAgentViewController/` + `Core/Session/SessionUIState.swift`（先读 `docs/UILayer.md`） |
| **改 memory 系统** | `Core/Memory/MemoryStore.swift` 协调 + `Core/Memory/MemoryStorage.swift` 协议 + `Core/Tools/MemoryTool.swift` LLM 接口 |
| **加测试** | `Tests/Core/AppAgentCoreTests.swift`（用 InMemorySessionStorage / InMemoryMemoryStorage 隔离） |

## 主要文件职责

### Core/Agent/ — 核心编排

| 文件 | 职责 |
|------|------|
| `AIAgent.swift` | 顶层 facade：持有 session/memory/skills，组装 system prompt，注册内置工具 |
| `AIAgentProfile.swift` | Agent 配置：promptBuilders、identity、maxIterations、toolPrompts、memoryConfig |
| `AIAgentDelegate.swift` | 宿主 app 回调协议：session 生命周期 + `policyFor(request:)` 策略钩子（非交互；呈现由 AppAgent 面板负责） |
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

### Core/Session/ — Session 生命周期

| 文件 | 职责 |
|------|------|
| `AISession.swift` | 单次对话：持有 provider、modelId、messages、tools、uiState；sendMessage 创建 Executor 驱动对话；`requestDecision` 是「等用户拍板」的唯一入口 |
| `AISessionManager.swift` | Session 生命周期管理：创建、删除、持久化、恢复 |
| `AISession+Permission.swift` | 会话级权限授予（「在本会话中允许」）与撤销，随 `SessionSnapshot.permissionGrants` 落盘 |
| `LLMExecutor.swift` | LLM ↔ tool 执行循环引擎：流式调用、工具执行、重试、上下文压缩 |
| `SessionDecisionCenter.swift` | `DecisionRequest` / `DecisionOption` / `DecisionOutcome` / `DecisionResponder` + 进程级 `DecisionResponderCentral` 注册表 |
| `SessionStorage.swift` | SessionStorage 协议 + InMemory/File 实现 + SessionSnapshot Codable |
| `SessionUIState.swift` | 线程安全 UI 中间状态：流式文本、错误、`pendingDecision`（等用户决定的阻塞态）、自定义状态；通过 onChange 回调观察 |

### Core/Model/ — LLM Provider 抽象

| 文件 | 职责 |
|------|------|
| `ModelProvider.swift` | ModelProvider 协议、ModelSpec、ProviderStreamEvent、ContentOrCacheControl、APIProtocol |
| `ModelProviderCentral.swift` | Provider 注册中心 actor：注册、解析 "providerName/modelId"、resolveDefault；定义 ModelPolicy |
| `SystemPrompt.swift` | 简单 text wrapper |
| `ErrorClassifier.swift` | API 错误分类 → 恢复策略（重试、回退、压缩等） |

### Core/Providers/Anthropic/ — Anthropic + OpenAI 兼容实现

| 文件 | 职责 |
|------|------|
| `AnthropicProvider.swift` | ModelProvider 实现：构建 HTTP 请求，SSE 流式（`URLSession.bytes`） |
| `AnthropicMapper.swift` | 双向映射：AIAgentMessage ↔ Anthropic wire format；SSE 事件解析；图片内嵌为 `tool_result.content` image block |
| `AnthropicTypes.swift` | Anthropic API Codable 类型（含 `AnthropicImageBlock`、`AnthropicToolResultContentBlock` 等多模态支持） |
| `OpenAIChatCompletionsMapper.swift` | `toMessages(_:system:)`：映射到 chat/completions；图片以追加的 user 消息 + `image_url` data URL 投递 |
| `OpenAIResponsesMapper.swift` | `toInput(_:)`：映射到 Responses API input items；图片以追加的 user item + `input_image` 投递 |
| `SSEParser.swift` | 逐行 SSE 解析器 |

三种协议的工具输入 Schema 共用 `Core/Providers/ToolSchemaMapper.swift`，避免新增 Schema 字段时三处漂移。

### Core/Tool/ — 工具注册与协议

| 文件 | 职责 |
|------|------|
| `ToolCentral.swift` | 工具注册中心 actor：共享实例 + ToolFactory；ToolPolicy 过滤；resolveTools |
| `ToolTypes.swift` | Tool 命名空间 (Schema/SafetyLevel/Output) + ToolProtocol |
| `ToolPermission.swift` | 按类别授权：`AppAgentPermission`、`ToolPermissionPolicy`、设备级「始终允许」`AppAgentPermissionStore` |
| `ToolArgumentValues.swift` | 工具参数取值与校验（整数有限值、溢出、区间等） |

### Core/Tools/ — 内置工具实现

| 文件 | 职责 |
|------|------|
| `ClarifyTool.swift` | 暂停执行向用户提问 |
| `MemoryTool.swift` | 暴露持久记忆 (add/search/remove) 给 LLM |
| `TodoTool.swift` | Session 级任务列表，存储在 uiState |
| `FileTool.swift` | 通过 agent:// / host:// 逻辑 URI 统一列目录、读写、搜索、删除和真实地址解析；host 资源的目标和每个列出/搜到的条目都过 `HostStoragePolicy` |
| `FileResourceRegistry.swift` | 注册 AppAgent 内部资源和宿主资源目录，声明摘要、归属和允许的操作 |
| `SkillsTool.swift` | 统一 Skill Tool：目录、分类展开、正文/资源加载和用户 Skill 管理 |
| `TextToSpeechTool.swift` | AVSpeechSynthesizer 文字转语音 |
| `DelegateTaskTool.swift` | 生成子 session 处理子任务 |
| `SessionTool.swift` | 统一会话搜索、浏览、读取、创建、切换、归档、恢复和合并 |
| `ClipboardTool.swift` | 系统剪贴板读写 |
| `HapticTool.swift` | 触觉反馈 |
| `AppActionTool.swift` | 通过 AppActionProvider 执行宿主 app 业务动作 |
| `AppNavigateTool.swift` | 通过 AppNavigationProvider 执行应用内导航 |
| `AppStateTool.swift` | 现读会话装上的 `HostStateProvider`（`app_state` 工具） |
| `WebSearchTool.swift` | 通过 WebSearchProvider 执行网络搜索 |
| `WebFetchTool.swift` | 抓任意 http(s) URL：HTML→文本 / raw / head，可 save_as 落盘；SSRF 拦截 + 不可信栅栏 |
| `ScreenshotTool.swift` | 截当前 window 或指定 path 视图：默认以 `Tool.Output.image` 内联给模型，`save_as_file` 才落盘（取代原 vision_analyze） |
| `SandboxPathResolver.swift` | 安全路径解析，防止目录遍历攻击 |
| `SessionLifecycleExecutor.swift` | `session` 的生命周期分支：list/read/create/switch/rename/models/set_model；archive/delete 可恢复归档、archived/restore/merge；clear 禁用，模型无永久删除（见 `docs/SessionHistory.md`） |
| `SessionSearchExecutor.swift` | `session` 的历史搜索分支 |
| `AppUserDefaultsTool.swift` | UserDefaults read/write/remove/list（group host-storage） |
| `DeviceInfoTool.swift` | `device_info`：设备、系统、App、存储、内存、地区、电量分节读取 |
| `HostInfoTool.swift` | 宿主 Bundle、版本、构建信息和宿主补充元数据（group host-runtime） |

> 宿主能力工具（同在 `Core/Tools/`，协议与默认实现在 `Core/HostCapability/`）：`RuntimeInspectTool`（一个类型两种实例：`app_ui` 看界面和模拟操作，`app_runtime_inspect` 读内存对象与反射，后者在 debug 组）、`HotfixTool`、`WebInspectTool`。宿主工具命名与注册见 `Core/Tool/HostTools.swift`，按需加载见 `Core/Tools/LoadToolsTool.swift`，宿主页面名与用途（`app_ui` 怎么称呼页面）见 `Core/HostCapability/HostPageCatalog.swift`。

### Core/Tools/Protocols/ — 宿主 App Provider 协议

| 文件 | 职责 |
|------|------|
| `AppActionProvider.swift` | AppActionProvider 协议 + AppAction 数据结构 |
| `AppNavigationProvider.swift` | AppNavigationProvider 协议 + AppRoute 数据结构 |

> **注**: `WebSearchProvider` 协议直接定义在 `WebSearchTool.swift` 内，不在此目录。

### Core/Memory/ — 记忆子系统

| 文件 | 职责 |
|------|------|
| `MemoryStore.swift` | 协调 actor：管理长期 + 热记忆，组装 memory prompt，输入消毒 |
| `MemoryStorage.swift` | MemoryStorage 协议 + InMemoryMemoryStorage（测试用） |
| `FileMemoryStorage.swift` | 文件持久化（单 JSON 文件） |
| `MemoryConfig.swift` | 配置：longTerm/hot 开关、最大条目数、最大条目长度 |
| `MemoryEntry.swift` | 单条记忆条目：content、tags、source (user/aiAgent/system)、timestamp |
| `HotMemory.swift` | 临时进程内 key-value 记忆 actor（不持久化） |

### Core/Skills/ — 技能子系统

| 文件 | 职责 |
|------|------|
| `SkillsManager.swift` | 技能发现 actor：从 Bundle/Documents 加载，YAML frontmatter 解析，创建/删除 |
| `Skill.swift` | 技能数据结构：name、description、category、markdown content |

### Core/Message/ — 消息与事件

| 文件 | 职责 |
|------|------|
| `AIAgentMessage.swift` | Provider 无关的消息类型，Content enum (text/toolUse/toolResult)，ToolCallResult 可带 ImageAttachment，Codable（`images` / `turnID` 键向后兼容旧快照）；`turnID` 是「这轮提问」的归属，`isGenuineUserInput` 区分「用户真的说了话」与工具结果 |
| `AIAgentEvent.swift` | 流式事件枚举 + AIAgentFinish 结果类型 |
| `AIAgentError.swift` | AIAgentError + ModelError 错误枚举 |
| `AIAgentTurnRecord.swift` | 一轮的持久状态：stage + outcome(.answered/.empty/.failed/.cancelled/.interrupted) + modelRef，随快照落盘，UI 的唯一状态来源 |
| `AIAgentMessageAttachment.swift` | 用户附件（图片 / 文件）类型与 `AttachmentFileStaging`：拷进 `agent://workspace/attachments/<UUID>/`、移除时删除、启动清扫无引用目录 |

### Core/HostContext/ — 宿主状态

| 文件 | 职责 |
|------|------|
| `HostContextTypes.swift` | `HostState` / `HostStateChange` / `HostEvent`、`HostStateProvider` 协议、发给模型的帧格式 |
| `HostStateStore.swift` | 宿主写字段与说明、发事件的现成存放处（OC 可用） |
| `HostStateReporter.swift` | 每会话一个：请求模型前读宿主状态、按字段比对，产出完整 / 变化 / 事件帧 |

### Core/Foundation/ — 共享基础设施

| 文件 | 职责 |
|------|------|
| `JSONValue.swift` | 类型安全 JSON enum + Codable + 便捷访问器 |
| `JSONSchema.swift` | 递归 indirect enum 描述 JSON Schema（工具参数定义用） |
| `Logger.swift` | 集中日志：级别过滤、自定义 handler、敏感数据自动脱敏 |
| `Locked.swift` | 属性包装器：@Locked / @WeakLocked / @TrackedLocked + ReadersWriterLock（os_unfair_lock） |
| `ConcurrencyLimiter.swift` | Actor FIFO 并发限制器（API 请求限流），只暴露 `withPermit`，取消安全 |
| `RetryPolicy.swift` | 指数退避 + 抖动重试配置 |
| `StreamIdleGuard.swift` | 给流加「相邻事件间隔上界」，静默超限抛 `streamStalled` 并取消上游（切后台回来不动的闸门） |
| `BackgroundActivity.swift` | 进程级后台执行断言，一轮运行期间持有；UIKit 平台默认真实实现，可 `install` 替换 |
| `ReadySignal.swift` | 一次性 actor 就绪信号，支持多等待者 |
| `StableSort.swift` | 按名称稳定排序工具函数 |
| `AsyncStreamCompat.swift` | AsyncStream / AsyncThrowingStream 的 makePair() iOS < 17 兼容垫片 |

### UI/ — UIKit 界面（按目录看）

| 目录 / 文件 | 职责 |
|------|------|
| `UI/AppAgentOverlay.swift` + `AppAgentWindow.swift` | 宿主集成入口：穿透 overlay window（`windowLevel = .normal + 1`）+ 门面 |
| `UI/AppAgentViewController/` | 主控制器与其分片：ChatPanel、输入栏布局/委托、键盘、session 绑定与侧栏、语音输入 |
| `UI/AppAgentInputBar.swift` + `AppAgentInputBarFramePolicy.swift` + `AppAgentMenuButton` + `AppAgentTextView` | 底部胶囊输入栏：多行草稿、布局压缩阶段、pan 手势、扩大后的输入命中区、右侧动作槽（加号/发送/停止） |
| `UI/AppAgentAttachmentPicker.swift` + `AppAgentAttachmentViews.swift` | 输入栏加号面板：图片 / 文件选择、附件缩略图行 |
| `UI/AppAgentPageToggleButton.swift` | 公开的配套页面开关控件（顶栏与宿主页面共用） |
| `UI/Workspace/` | 会话工作区：`AppAgentWorkspace`（唯一入口）、宿主协议 `AppAgentWorkspaceHost` / 插槽视图、容器与页面 VC、状态落盘、`workspace` 工具、H5 内容/触摸/scheme/桥脚本（见 `docs/Workspace.md`） |
| `UI/ChatPanel/` | BODragScroll 面板：coordinator、几何/detent、消息列表、导航栏、过程区（timeline + view）、决策卡片（`AppAgentDecisionCardView` + `AppAgentDecisionOptionRow` + `AppAgentDecisionPresenter`） |
| `UI/ChatMessage.swift` + `ChatMessageCell.swift` | 展示层消息模型与气泡 cell（正文为可选中 UITextView，附过程区） |
| `UI/ChatMessageAssembler.swift` | 把 wire 记录组装成用户视角的对话列表（按 turnID 归属，工具往返收进过程区） |
| `UI/AppAgentMarkdown.swift` | agent 回复的 markdown 渲染（块级规整 + 系统解析器 + 字号派生） |
| `UI/SessionSidebar/` | 会话列表与废纸篓 |
| `UI/Settings/AppAgentSettingsViewController.swift` | 模型设置：探查、拖拽优先级、可用性实测 |
| `UI/Settings/AppAgentSessionPermissionsViewController.swift` | 会话设置：列出当前会话的权限状态，可修改或撤销 |
| `UI/Debug/` | 模型调用调试窗口 + 响应区域调试窗口（👻 悬浮按钮） |
| `UI/VoiceInputOverlay/` + `AppAgentVoiceRecognitionManager.swift` | 按住说话浮层与识别 |
| `UI/VoiceInput/AppAgentVoiceRecognitionCentral.swift` + `UI/Settings/AppAgentVoiceRecognitionSettingsViewController.swift` | 识别引擎注册 / 选择与设置页切换 |

### Tests/

`Tests/Core/` 与 `Tests/UI/` 下的文件数随开发变化，**不在这里维护清单**，直接看目录。
分工是固定的：纯逻辑 / Core 契约放 `Tests/Core/`，需要 UIKit 运行时的放 `Tests/UI/`。

原生 macOS `swift test` 只跑 Core 部分；UIKit 用例需 Mac Catalyst destination。
Catalyst 的 xctest 里创建 `UIWindow` 会抛 `NSApplication has not been created yet`，
需要窗口的断言请改写成纯几何 / 纯视图层级的形式。
