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
swift test        # 原生 macOS Core：161 tests
xcodebuild -project Examples/iOS/AppAgentDemo.xcodeproj -scheme AppAgentDemo -configuration Debug -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AppAgent -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst,name=My Mac' test  # Core + UIKit：278 tests
Scripts/simulator-selfcheck.sh   # iOS 模拟器上把全部工具跑一遍（见下）
```

Demo App 在 `Examples/iOS/AppAgentDemo.xcodeproj`，支持 iOS 和 Mac Catalyst；需要先复制 `Resources/config.json.example` 为 `Resources/config.json` 并填入配置。

## 模拟器能力自检（工具回归的主力手段）

`Examples/iOS/Sources/CapabilitySelfCheck.swift` 在真机/模拟器运行时里**直连每个工具的 `execute`**（不经过 LLM），逐项判定通过与否。单元测试拿不到 UIKit 运行时，这里能，所以验证工具改动优先走它。

```bash
Scripts/simulator-selfcheck.sh                 # 自动挑一个已启动的 iPhone 模拟器
Scripts/simulator-selfcheck.sh <device-udid>
SKIP_BUILD=1 Scripts/simulator-selfcheck.sh    # 复用上次构建
```

- 脚本每一步都套了 `gtimeout`（需 `brew install coreutils`）：卡住会直接失败并打印最近日志，不会挂住终端。app 内部每个检查项另有 8s 预算，超时记为失败后继续跑完剩余项。
- 产物：`Documents/selfcheck-report.txt`（逐项 ✓/✗ + `total=/ok=/fail=` 汇总，脚本拷到 `/tmp/selfcheck-report.txt`）、`Documents/selfcheck-ui-hierarchy.txt`（未截断的全窗口 `ui_hierarchy` + `view_tree`，看布局/样式用）。脚本以 `fail=0` 决定退出码。
- 自检在 overlay 挂载**之后**才跑，所以层级里能看到宿主 window + `AppAgentWindow` + `AppAgentRegionDebugWindow` 三层；`-run-selfcheck` 同时抑制「尚未配置 API Key」弹窗，避免污染 dump。
- 首页「能力自检」按钮在 app 内弹出同一份报告。
- 加新工具时**一并在 `CapabilitySelfCheck` 加一条检查**，用三种期望之一：`.ok`（必须成功）、`.errorContains(...)`（必须以某个错误拒绝）、`.completes`（只要求不挂死，用于依赖真实模型或宿主 UI 的项）。
- **自检必须跑完不留痕**：变更类内省（`view_set` / `view_invoke` / JS `uiSet`）只打在 `installScratchView()` 挂上去的一次性隐藏视图上，绝不改真实 UIKit 视图；改了全局观感的（深浅色、当前 tab）要复位；剪贴板只清掉自己写的内容。报告里有「临时视图已移除 / 深浅色已复位 / tab 已复位 / 剪贴板已清理」几条守着这个约定。
- **别在 `withBudget` 之外写可能阻塞的调用**。踩过：直接 `UIPasteboard.general.string` 读别的来源写入的剪贴板会触发系统粘贴授权，无人确认时整轮自检卡死（脚本 60s 超时才发现）。所以不去「读旧值再还原」剪贴板，且所有清理动作也一律包在 `withBudget` 里。

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

**自动注册 (21个):** clarify, memory, todo, file_read, file_write, file_search, skills_list, skill_view, skill_manage, text_to_speech, delegate_task, session_search, session_manage, clipboard, haptic, web_fetch, app_user_defaults, app_sandbox_file, app_device_info, app_runtime_inspect, screenshot（最后两个仅在 `canImport(UIKit)` 时注册）

**需宿主 app 注入 Provider / 自行注册 (6个):** app_action, app_navigate, app_state, web_search, app_hotfix, app_hook_capture

通过 `AIAgentProfile.disabledBuiltInTools` 禁用指定工具；工具按 `group` 归类（core / session / host-storage / host-runtime），可用 `ToolPolicy` 的 allowedGroups / excludedGroups 整组开关。

### 工具输出与安全模型（对标 Codex，但按 iOS 场景调整）

- **输出有预算**：`AIAgentProfile.toolOutputMaxBytes`（默认 8KB）在 `LLMExecutor` 统一裁剪，按 UTF-8 字节切、回退到行边界、附「收窄查询」指引。单个工具可用 `ToolProtocol.outputMaxBytes` 抬高上限。起因：空壳 demo 的全量 `ui_hierarchy` 就 19KB，`class_list` 无过滤会返回进程里全部 78747 个 ObjC 类。
- **`ui_hierarchy` 默认只给摘要**：VC 页面栈为骨架 + 语义锚点视图 + 大子树折叠成 `⊞ N views` 并附可二次调用的 path，实测 2.8KB vs 19KB。要全量得显式 `detail:"full"`。细节走 `view_tree(path:)` 钻取。
- **路径可跨 window**：`0/2/1` 相对 keyWindow，`W1:0/2/1` 指定第 1 个 window。overlay 窗口里的视图只能用后者寻址。
- **授权是 op 级的**：`ToolProtocol.safetyLevel(for:)` 按参数判定，`app_sandbox_file` 的 `list` 是 safe 而 `delete` 是 sensitive，`app_hotfix` 的 `apply` 是 dangerous。缺 op 时**不降级为 safe**（否则模型省掉参数就绕过闸门）。
- **只读边界**：`AIAgentProfile.toolMutationPolicy = .readOnly` 时所有 `> .safe` 的调用**直接失败**而不是弹窗问人——这是 Codex `sandbox_mode` 的 iOS 对应物（iOS 沙箱运行时收不紧，只能工具层自律）。
- **并发按级别分流**：`safe` 并发执行，`moderate` 及以上串行。两个并发的写没有互斥，快那点不值当。
- **变更可回滚**：`view_set` 返回改前原值，把它写回同一个 key 即撤销。
- **文件工具边界**：`file_read/write/search` 只管 Documents（agent 自己的工作区），`app_sandbox_file` 管整个 app home（Library/tmp/Caches）。两边描述里互相点名，避免模型随机挑。

### 运行时内省 / 热修复 / 抓包（`app_runtime_inspect`、`app_hotfix`、`app_hook_capture`）

这三个工具直接改运行时，「失败被报成成功」比功能缺失更危险——模型会拿着没生效的结果继续往下推。约定都在模拟器自检里有对应检查项（`checkKVCOps` / `checkReflectionGuards` / `checkHookCapture`）：

- **反射只能传/收对象**。`perform(_:with:)` 按对象指针传参、按对象指针读返回值，碰上原始类型就是 ABI 不匹配：`setTag:` 会把 NSNumber 的**指针**当整数写进 tag（实测不是传进去的 7），`isHidden` 返回 BOOL、按对象 `takeUnretainedValue()` 会崩，返回结构体（`frame`）走 sret 更是必崩。所以 `DefaultRuntimeInspectProvider.selectorRejection` 先按 ObjC 类型编码筛一遍（参数全对象 + 返回 void/对象才放行，顺带校验参数个数），`view_invoke` / `invoke` / JS 桥 `appagent.uiInvoke` **三个入口都要过这道闸**。原始类型的属性让模型改走 `view_set` / `property_set`（KVC 会正确装箱）/ `property_value`。
- **写类操作的成功判定是「以 `OK.` 起头」，不是「不在失败清单里」**。provider 的失败文案形态一堆（`Invalid rect '…'`、`Invalid alpha '…'`、`UIView has no text/title to set.`…），靠失败前缀清单漏一个就把没生效的修改当成功。所以 `view_set` / `property_set` 走 `mutationOutput`，provider 侧所有成功分支（含 KVC 兜底）统一以 `OK.` 开头。
- **读也要判失败**：`property_value` 以前绕过判定直接 `.text(...)`，于是 `Failed to read …` / `(no target object for KVC…)` 被模型当成读到的值。
- **`app_hotfix` 的失败一律 `.error`**：`apply` 的 JS 报错、`toggle`/`remove` 指了不存在的槽位，都不能包成 `success:false` 的「成功调用」。`DefaultHotfixProvider.setEnabled` 要区分「槽位不存在」与「关掉了」（原来两者同走一条路，`!enabled` 恒真导致 toggle 未知补丁报成功）。
- **`app_hook_capture` 的写入方在仓库外**（宿主侧写入方，如百度地图的 LijiMsgTap），所以自检自己按磁盘契约往 `Caches/AppAgentMsgCapture/cap_<channel>_*.jsonl` 造两条乱序 `seq` 记录，再验 seq 升序 / `limit` 取尾 / `sinceSeq` 过滤 / 按 channel 删干净；跑完把 `NSUserDefaults` 里的抓包开关和目录一起复位。


`Tool.Output.image(Tool.ImageOutput)` 让工具直接把图片交给模型看，不必先落盘再让模型猜文件里是什么。`screenshot` 默认走这条路（`save_as_file: true` 才落盘）。链路：

- `Tool.ImageOutput`（data + mediaType + caption）→ `LLMExecutor` 把它转成 `AIAgentMessage.ToolCallResult.images`，**文本预算只裁 `caption`，不碰图片字节**（截断一张 PNG 只会得到坏图）。
- `caption` 同时写进纯文本通道（`stringValue` = `"<caption> [image/png, N bytes attached]"`），这样即便走到不支持图片的模型/协议，模型也知道自己拿到了什么。
- 两种协议对「工具结果里放图」的支持不对称，mapper 各自绕开：
  - **Anthropic**：`tool_result.content` 支持 block 数组，图片直接塞进同一条 `tool_result`（无图时仍编码为纯字符串，保持 wire 干净）。
  - **OpenAI Chat Completions / Responses**：`role:"tool"` 的 content 和 `function_call_output.output` 都只收字符串，所以图片以**紧跟其后的一条 `user` 消息**投递（`image_url` data URL / `input_image`）。
- `ToolCallResult.images` 是后加的键，`init(from:)` 手写成 `decodeIfPresent ?? []`，旧 session 快照照常能解开。
- `ScreenshotTool.maxAttachmentBytes = 3MB`，`maxWidth` 按**像素**算（UIKit 会把 `format.scale` 向整数靠，实际可能比上限更小，但不会超）。

### 等用户拍板（授权 / 澄清 / 方案选择走同一条链路）

需要用户拍板的事只有一个入口：`AISession.requestDecision(_:)`。工具和 `LLMExecutor` 都不关心谁来回答。

- **责任链**：① 宿主策略 `AIAgentDelegate.policyFor(request:)`（**非交互**，返回 `nil` = 无意见；企业要「内网一律禁止，别问用户」在这里拦）→ ② 已注册的 `DecisionResponder`（正常就是 AppAgent 自己的对话面板）→ ③ 兜底：授权类 `.deny`，澄清类 `.answer(nil)`。**没人能回答不等于放行。**
- **卡片是 AppAgent 自己的**：`AppAgentViewController` 在 `viewDidLoad` 里造一个 `AppAgentDecisionPresenter` 注册进 `DecisionResponderCentral.default`，卡片渲染在**对话面板内部**（`AppAgentChatPanelView.decisionCard`，贴消息列表底部），不新建 window、不遮宿主界面、不影响别的 session。宿主 app 零代码。
- **阻塞态是个栈不是单槽**：`requestDecision` 期间 `uiState.setPendingDecision` 入栈、答复后按同一个 request 出栈（`pendingDecision` 给**队首那个**——和面板上正在展示的那张卡一致；`pendingDecisionCount` 给个数）。单槽的话两个并发请求里先答完的会把「还有人在等」直接清掉，宿主据此判断就错了。显式传了 request 却没命中时 `clearPendingDecision` 什么都不做，宁可漏摘也不摘掉别人还在等的那条。UI 通过 `onChange("pendingDecision")` 观察。await 发生在 executor 的 Task 里，不占主线程——用户可以切到别的 session 聊天，切回来卡片还在等。
- **卡片一张、请求按会话排队**：`DecisionResponder.respond` 拿得到发起请求的 session，`AppAgentDecisionPresenter` 把 sessionId + requestId 一并交给呈现闭包；VC 存进 `pendingDecisions[sessionId]`（**数组**，同会话并发的第二个请求排在后面而不是覆盖——覆盖会把它的 continuation 永久挂住）。不属于当前会话的请求**也要收下并返回 true**（返回 false 会让责任链兜底拒绝，等于替用户做了决定），`switchSession` 时先 `dismissDecision()` 再把新会话队首那张贴出来。
- **等待是可取消的**：`respond` 外面套 `withTaskCancellationHandler`。用户按停止 / 切走 run 之后，等在卡片上的 Task 会被取消——这时必须立刻恢复 continuation（返回 `nil` = 交回责任链兜底，**不是**替用户点「允许」）并通过 `dismiss(requestId:)` 把卡片撤掉、换上队列里的下一张。少了这一层，卡片会一直挂着等一个已经死掉的回合，executor 的 Task 也永远回不来。`Tests/UI/AppAgentUITests.swift` 有用例锁住「取消后不挂死且撤卡片」。
- **continuation 一个都不许漏**：三条出口都要堵住——① 取消可能落在「检查完没取消」与「贴出卡片」之间，`present` 返回 true 后要再查一次 `isSettled`，是就立刻 `dismiss`（否则留一张点了没用的僵尸卡）；② 呈现失败 `settle(nil)` 走责任链兜底；③ **VC `deinit` 要 `drainPendingDecisions()`**，把还排队的按兜底语义答复掉，不然那些 `CheckedContinuation` 带着未恢复状态析构（运行时报 "leaked its continuation"），发起它们的那一轮永远回不来。
- **一个请求三种形态**：`DecisionRequest` = `.privateNetworkAccess` / `.toolAuthorization` / `.clarification`，`title` / `message` / `options` 由它自己给出，卡片不 switch 业务。`clarify` 工具也走这条路，不再需要宿主实现回调。
- **Sendable 边界**：`DecisionResponder` 要求 Sendable，UIViewController 不是，所以用 `AppAgentDecisionPresenter`（`@unchecked Sendable` 薄壳 + 弱引用 + 内部跳 MainActor）把 async 语义接到 UIKit 点击上，`withCheckedContinuation` 只允许恢复一次。
- **自检必须换掉 responder**：真机上卡片会一直等真人点按钮，无人值守时整轮自检会挂死。`CapabilitySelfCheck.run` 开头把 `session.decisionResponders` 换成自动应答的假 responder（`SelfCheckDecisionResponder`），这条约定别破。
- **卡片布局两个坑**（都实测踩过）：① 别拿 `layout.messageListFrame` 定位——消息列表按完整 contentArea 布局、由 viewport 裁切，它的底边在可见区外面，卡片会被裁掉完全看不见；应贴 `viewportView.bounds` 底边。② viewport 会延伸到 inputBar 底下，所以还要减 `decisionCardBottomInset`（由 `applyChatPanelContainerLayout` 用 inputBar 几何写入），否则最下面的按钮被输入栏压住点不到。
- **人工验观感**：demo 支持 `xcrun simctl launch <udid> com.appagent.demo -show-decision-card`（仅 DEBUG）——展开面板、真的发一次私网授权请求走完整责任链，30s 后自动点「拒绝」，配 `simctl io ... screenshot` 看实际效果。
  - 验对话列表分层与 markdown 用 `-show-sample-conversation`：往当前会话灌一段样例对话（一轮里两次失败的工具往返 + markdown 答案），展开面板并抑制「未配置 API Key」弹窗，不需要真的连模型。

### 对话列表：两层消息，别混为一谈

**wire 层 ≠ 展示层**，这是这个 UI 最容易踩错的地方：

- **wire 层**（`AIAgentMessage`）：一次提问会展开成多轮 assistant ↔ tool 往返，而且工具结果在协议上必须是 `user` 角色（两家协议都这么要求）。这是给模型看的。
- **展示层**（`ChatMessage`）：一次提问 = 一个用户气泡 + 一个 agent 气泡。agent 内部的多轮往返属于它自己的处理过程，收进那个气泡的**过程区**，结束后折叠成「已思考 x 秒 · N 步」一行，点开才看全过程。

归属关系由 Core 打好的 `AIAgentMessage.turnID` 决定，**不靠位置猜**：`AISession.addUserMessage` 递增 `currentTurnID`，executor 产出的 assistant / 工具结果消息都打上同一个号。上下文压缩改写过消息列表也不会错挂。

- **只有 `isGenuineUserInput` 才配当用户气泡**：`role == .user` 且不含 `toolResult`。曾经直接把 wire role 当气泡归属，于是「Result: Error: Tool 'web_fetch' not found」这种工具错误以蓝色用户气泡的身份出现在对话里。
- **组装入口只有一个**：`ChatMessageAssembler.assemble(_:streamingText:isRunning:errorText:expandedTurnIDs:)`。`AppAgentViewController.reloadFromSession` 调它，别在别处再写一套 role → 气泡的映射。
- **错误也必须走组装器**：`uiState.lastError` 不在 wire 记录里，靠 `errorText:` 参数挂到最后一轮上。踩过：executor 先 `setStreaming(false)` 触发 `reloadFromSession`，而组装器会丢掉「既无正文又无过程」的空轮，于是「尚未配置 API Key / No provider configured」这类失败在界面上**完全没有反馈**。`handleUIStateChange` 的 `lastError` 分支只负责再 reload 一遍；已有半截正文时错误接在后面，不覆盖。
- **过程区归属「最后一条 assistant 气泡」，不是最后一行**：本轮还没吐正文时列表末尾是刚插入的用户气泡，写上去过程区就挂到蓝色气泡上了。`applyActivity` 用 `lastIndex(where: { $0.role == .assistant })`，列表侧是按 id 定位的 `updateActivity(_:expanded:messageID:)`；`ChatMessageCell.configure` 也要判 `role == .assistant` 才显示过程区。**流式正文走同一套口径**（`handleUIStateChange("streamingText")` + `updateMessage(text:status:messageID:)`），两条路径别再一个按行一个按角色。
- **展开态记在 turnID 上**：`ChatMessage.id` 每次组装都是新 UUID，所以「用户点开了哪一轮」存在 VC 的 `expandedActivityTurnIDs`，再通过 `assemble(expandedTurnIDs:)` 生效；列表点击用 `listView.onActivityToggled` 回传。换会话时清空。
- **每轮结束的重建不许把人拽回底部**：`listView.setMessages(_:forceScrollToBottom:)` 默认只在「本来就贴着底」时滚；只有换会话 / 首次装载 / 灌样例对话传 `true`。
- **流消费 Task 必须认会话**：`sendMessage` 先 `currentStreamTask?.cancel()`，Task 内每个事件前 `guard !Task.isCancelled, currentSessionId == boundSessionId`，流断掉后的补收尾也过同一道闸——否则切走再切回来时旧 Task 会把上一个会话的时间线写到新列表上。
- **工具失败只看 `ToolCallResult.isError`**，不嗅 `Error:` 前缀：那串文案是给模型看的，工具正常返回的正文（比如读出来的日志）也可能这么开头。
- **过程区从记录推导**，不是运行时快照：所以切换会话、重启 App 之后历史里每一轮的过程都还在（旧的 `lastTurnActivity` 快照机制已删除）。时间线起止取自消息时间戳，不然恢复出来的历史会显示「已思考 0.0 秒」。
- **旧快照兼容**：`turnID` 是后加的键，Optional 的合成 Decodable 用 `decodeIfPresent`，缺键即 nil；nil 时按「真的用户发言开新一轮」回退。
- **整体替换消息列表也要带上编号**：`AISession.updateMessages` 把 `currentTurnID` 抬到新列表里的最大号（只往前走）。否则恢复快照 / 压缩回写 / 灌样例对话之后，下一条提问会复用旧号并被并进历史里的某一轮。

### agent 回复的 markdown 渲染

`ChatMessageCell` 里 assistant 正文走 `AppAgentMarkdown.attributed(...)`，用户自己的话保持纯文本。三个坑都实测踩过，改这个文件前先读注释：

- **`NSAttributedString(AttributedString)` 不认块级结构**：`AttributedString` 把标题/列表/段落记在 `presentationIntent` 里，转成 NSAttributedString 后这些元数据不产生换行，整篇会糊成一段。必须按块边界自己补换行。
- **只有空行分隔的块才算不同块**：`- 甲\n- 乙` 会被并进同一个块，光看 intent 分不开。所以解析前先做一遍块级规整（`normalizeBlocks`）：块之间补空行，列表项/表格行自带字面量前缀。前缀刻意用不成 markdown 标记的形式（无序用「• 」，有序序号后跟不换行空格），否则会被解析器当列表标记吃掉、列表项又并回一块。
- **属性一律用 `NSAttributedString.Key` 写**，不要用 `attributed[range].strikethroughStyle` 这类动态查找：同名属性在 UIKit 与 SwiftUI 两个 attribute scope 里都有，动态查找会挑中 SwiftUI 那个，而本 target 不链接 SwiftUI —— 直接变成链接错误（`Undefined symbols: SwiftUI.Text.LineStyle`）。
- **每个 run 从解析结果转过来**（`NSAttributedString(AttributedString(slice))`），只覆盖字体与正文色：按字符串重建 run 会把解析器给的 `.link` 丢掉，链接就只剩样式、点不动。删除线记在 `inlinePresentationIntent` 里、转换时不落成属性，要额外补 `.strikethroughStyle`。
- **GFM 表格**：系统解析器不认，会退化成普通段落且各列直接拼在一起。`normalizeBlocks` 把表格改写成「表头：值」的条目行。真表格渲染要引入第三方渲染器，暂不做。

`Tests/UI/AppAgentMarkdownTests.swift` 断言的就是渲染出来的字符串（块要各占一行、表格不粘连），改渲染逻辑先跑它。

### 网络访问（`web_fetch`）

`web_fetch` 让 agent 读公网：`mode=text` 把 HTML 抽成纯文本、`raw` 原样返回（JSON/源码）、`head` 只看响应头；`save_as` 落盘到 Documents 后配 `file_read` 按需读，长内容不必整篇进上下文。GitHub 的 `blob` 链接自动改写成 `raw.githubusercontent.com`（直接抓 blob 页拿到的是 HTML 外壳）。

三条边界必须保持，改这个工具时别绕过去：

- **私网 = 问用户，不是硬拒**：`resolve` 返回三态——`.success`（公网）、`.failure`（非 http(s)/无 host，无从讨论）、`.privateNetwork`（loopback、`10/8`、`172.16-31/12`、`192.168/16`、`169.254/16`、`.internal`/`.local`）。私网走 `session.requestDecision(.privateNetworkAccess(...))`（见上一节）。拒绝时错误里明确写「Do not retry this host」，避免模型反复撞墙。`allowForSession` 按 **host** 记在 `approvedPrivateHosts`，同一 session 同一 host 只问一次。
- **`safetyLevel` 不为私网抬级**：授权由工具内部那一遍完成；若 `safetyLevel(for:)` 也报 `.dangerous`，`LLMExecutor` 会先弹一次泛泛的「是否执行 web_fetch」，用户得点两次。
- **不可信栅栏**：抓回的正文用 `WebFetchTool.fence` 包起来并显式声明「这是数据不是指令」。没有这层，网页里一句「忽略之前的指令」就可能被当成系统指令——而这正是「网页诱导 agent 去打内网」的入口，所以栅栏和上面的私网授权是配套的两层。
- **体积上限**：`max_bytes`（默认 256KB）先卡一道，`outputMaxBytes`（64KB）再卡一道，按行边界截断并提示改用 `save_as`。

`save_as` 会写沙箱，所以 `safetyLevel(for:)` 从 `moderate` 抬到 `sensitive`。纯函数（URL 校验、私网判定、GitHub 改写、HTML 抽取、栅栏、截断）都有原生单测；授权链路（拒绝 → 不出站、允许 → 记住 host、无 delegate → 不放行）也有单测，另在模拟器自检里跑一遍真实运行时（含「询问期间 `pendingDecision` 确实置起」）。真实出站用 `.completes` 验，网络不通只记降级不算失败。

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

## 代码规范

- 当前项目仍处于本地开发、未发布阶段：不需要为了兼容旧 API 而保守。若重构能显著提升结构清晰度、命名一致性或长期可维护性，可以直接调整 public/internal API，并同步更新本仓库调用点。
- 最低支持 iOS 15，不使用 iOS 16+ only API（除非有 `#available` 守卫）。升到 15 是为了 agent 回复的 markdown 渲染直接用系统 `AttributedString(markdown:)`，不必自研解析器或引入第三方依赖。
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
- **约定：需要调整命中区就用 BOUIKit，不要再手写 `hitTest` / `point(inside:)`**，除非判定本身有复杂逻辑（路径命中、按状态重定向到别的子视图等）。
- 已接入点：`AppAgentWindow` 与 `AppAgentRegionDebugWindow` 的穿透、`AppAgentChatPanelContainerView` 的「命中自己就穿透」用 `bo_skipsSelfInHitTest`；`AppAgentRegionDebugPanelView` 折叠态外扩用 `bo_hitAreaOutsets`。
- 仍保留手写 override 的三处（都属于复杂判定）：`AppAgentInputBar.hitTest` 把 bar 空白处的触点重定向给输入区；`AppAgentVoiceBottomPanelView` / `AppAgentVoiceActionZoneView` 用贝塞尔路径判定命中。
- 输入区命中：`AppAgentInputBar.extendedInputAreaHitRect` 是「点击弹键盘」和「上滑唤键盘」**共用**的同一块矩形（横向为输入区、纵向撑满 bar 白色背景）。改一处即两者同步，`Tests/UI/AppAgentRegionDebugTests.swift` 有用例锁住这一点。

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

### Core/Session/ — Session 生命周期 (6 files)

| 文件 | 职责 |
|------|------|
| `AISession.swift` | 单次对话：持有 provider、modelId、messages、tools、uiState；sendMessage 创建 Executor 驱动对话；`requestDecision` 是「等用户拍板」的唯一入口 |
| `AISessionManager.swift` | Session 生命周期管理：创建、删除、持久化、恢复 |
| `LLMExecutor.swift` | LLM ↔ tool 执行循环引擎：流式调用、工具执行、重试、上下文压缩 |
| `SessionDecisionCenter.swift` | `DecisionRequest` / `DecisionOption` / `DecisionOutcome` / `DecisionResponder` + 进程级 `DecisionResponderCentral` 注册表 |
| `SessionStorage.swift` | SessionStorage 协议 + InMemory/File 实现 + SessionSnapshot Codable |
| `SessionUIState.swift` | 线程安全 UI 中间状态：流式文本、错误、`pendingDecision`（等用户决定的阻塞态）、自定义状态；通过 onChange 回调观察 |

### Core/Model/ — LLM Provider 抽象 (4 files)

| 文件 | 职责 |
|------|------|
| `ModelProvider.swift` | ModelProvider 协议、ModelSpec、ProviderStreamEvent、ContentOrCacheControl、APIProtocol |
| `ModelProviderCentral.swift` | Provider 注册中心 actor：注册、解析 "providerName/modelId"、resolveDefault；定义 ModelPolicy |
| `SystemPrompt.swift` | 简单 text wrapper |
| `ErrorClassifier.swift` | API 错误分类 → 恢复策略（重试、回退、压缩等） |

### Core/Providers/Anthropic/ — Anthropic + OpenAI 兼容实现 (6 files)

| 文件 | 职责 |
|------|------|
| `AnthropicProvider.swift` | ModelProvider 实现：构建 HTTP 请求，SSE 流式（`URLSession.bytes`） |
| `AnthropicMapper.swift` | 双向映射：AIAgentMessage ↔ Anthropic wire format；SSE 事件解析；图片内嵌为 `tool_result.content` image block |
| `AnthropicTypes.swift` | Anthropic API Codable 类型（含 `AnthropicImageBlock`、`AnthropicToolResultContentBlock` 等多模态支持） |
| `OpenAIChatCompletionsMapper.swift` | `toMessages(_:system:)`：映射到 chat/completions；图片以追加的 user 消息 + `image_url` data URL 投递 |
| `OpenAIResponsesMapper.swift` | `toInput(_:)`：映射到 Responses API input items；图片以追加的 user item + `input_image` 投递 |
| `SSEParser.swift` | 逐行 SSE 解析器 |

### Core/Tool/ — 工具注册与协议 (2 files)

| 文件 | 职责 |
|------|------|
| `ToolCentral.swift` | 工具注册中心 actor：共享实例 + ToolFactory；ToolPolicy 过滤；resolveTools |
| `ToolTypes.swift` | Tool 命名空间 (Schema/SafetyLevel/Output) + ToolProtocol |

### Core/Tools/ — 内置工具实现 (22 files)

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
| `WebFetchTool.swift` | 抓任意 http(s) URL：HTML→文本 / raw / head，可 save_as 落盘；SSRF 拦截 + 不可信栅栏 |
| `ScreenshotTool.swift` | 截当前 window 或指定 path 视图：默认以 `Tool.Output.image` 内联给模型，`save_as_file` 才落盘（取代原 vision_analyze） |
| `SandboxPathResolver.swift` | 安全路径解析，防止目录遍历攻击 |
| `SessionManageTool.swift` | 会话管理 9 op：list/read/rename/delete/create/switch/set_model/models/clear |
| `AppSandboxFileTool.swift` | 沙箱文件 list/read/write/delete（group host-storage） |
| `AppUserDefaultsTool.swift` | UserDefaults read/write/remove/list（group host-storage） |
| `AppDeviceInfoTool.swift` | 设备与运行环境：机型/系统/存储/内存/语言时区/电量（group host-runtime） |

> 宿主能力工具另有 3 个（同在 `Core/Tools/`，协议与默认实现在 `Core/HostCapability/`）：`RuntimeInspectTool`（含 view_tree/view_info/view_set/view_invoke）、`HotfixTool`、`HookCaptureTool`。

### Core/Tools/Protocols/ — 宿主 App Provider 协议 (3 files)

| 文件 | 职责 |
|------|------|
| `AppActionProvider.swift` | AppActionProvider 协议 + AppAction 数据结构 |
| `AppNavigationProvider.swift` | AppNavigationProvider 协议 + AppRoute 数据结构 |
| `AppStateProvider.swift` | AppStateProvider 协议 |

> **注**: `WebSearchProvider` 协议直接定义在 `WebSearchTool.swift` 内，不在此目录。

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
| `AIAgentMessage.swift` | Provider 无关的消息类型，Content enum (text/toolUse/toolResult)，ToolCallResult 可带 ImageAttachment，Codable（`images` / `turnID` 键向后兼容旧快照）；`turnID` 是「这轮提问」的归属，`isGenuineUserInput` 区分「用户真的说了话」与工具结果 |
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

### UI/ — UIKit 界面（53 files，按目录看）

| 目录 / 文件 | 职责 |
|------|------|
| `UI/AppAgentOverlay.swift` + `AppAgentWindow.swift` | 宿主集成入口：穿透 overlay window（`windowLevel = .normal + 1`）+ 门面 |
| `UI/AppAgentViewController/` (8 files) | 主控制器与其分片：ChatPanel、输入栏布局/委托、键盘、session 绑定与侧栏、语音输入 |
| `UI/AppAgentInputBar.swift` + `AppAgentInputBarFramePolicy.swift` + `AppAgentMenuButton/TextField` | 底部胶囊输入栏：布局压缩阶段、pan 手势、扩大后的输入命中区 |
| `UI/ChatPanel/` (11 files) | BODragScroll 面板：coordinator、几何/detent、消息列表、导航栏、过程区（timeline + view）、决策卡片（`AppAgentDecisionCardView` + `AppAgentDecisionPresenter`） |
| `UI/ChatMessage.swift` + `ChatMessageCell.swift` | 展示层消息模型与气泡 cell（正文为可选中 UITextView，附过程区） |
| `UI/ChatMessageAssembler.swift` | 把 wire 记录组装成用户视角的对话列表（按 turnID 归属，工具往返收进过程区） |
| `UI/AppAgentMarkdown.swift` | agent 回复的 markdown 渲染（块级规整 + 系统解析器 + 字号派生） |
| `UI/SessionSidebar/` (3 files) | 会话列表侧栏 |
| `UI/Settings/AppAgentSettingsViewController.swift` | 模型设置：探查、拖拽优先级、可用性实测 |
| `UI/Debug/` (4 files) | 模型调用调试窗口 + 响应区域调试窗口（👻 悬浮按钮） |
| `UI/VoiceInputOverlay/` + `AppAgentVoiceRecognitionManager.swift` | 按住说话浮层与识别 |

### Tests/

`Tests/Core/`：AppAgentCoreTests、AppAgentSettingsTests、AppAgentDebugLogTests、ModelFallbackTests、ReasoningStreamTests、SessionManageTests、HostToolsTests、HookCaptureTests

`Tests/UI/`：AppAgentUITests、AppAgentChatPanelGeometryTests、AppAgentActivityTimelineTests、AppAgentRegionDebugTests、AppAgentInputBarFramePolicyTests、AppAgentVoiceInputCoordinatorTests、RuntimeInspectViewTests、ChatMessageAssemblerTests、AppAgentMarkdownTests

原生 macOS `swift test` 只跑 Core 部分；UIKit 用例需 Mac Catalyst destination。Catalyst 的 xctest 里创建 `UIWindow` 会抛 `NSApplication has not been created yet`，需要窗口的断言请改写成纯几何/纯视图层级的形式。
