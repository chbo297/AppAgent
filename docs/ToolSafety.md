# 工具输出预算与安全模型

> **什么时候读这份**：加/改内置工具、改授权与范围判定、改运行时内省 / 热修复 / 抓包 / 抓网页时。

### 工具输出与安全模型（对标 Codex，但按 iOS 场景调整）

- **输出有预算**：`AIAgentProfile.toolOutputMaxBytes`（默认 8KB）在 `LLMExecutor` 统一裁剪，按 UTF-8 字节切、回退到行边界、附「收窄查询」指引。单个工具可用 `ToolProtocol.outputMaxBytes` 抬高上限。起因：空壳 demo 的全量 `ui_hierarchy` 就 19KB，`class_list` 无过滤会返回进程里全部 78747 个 ObjC 类。
- **`ui_hierarchy` 默认只给摘要**：VC 页面栈为骨架 + 语义锚点视图 + 大子树折叠成 `⊞ N views` 并附可二次调用的 path，实测 2.8KB vs 19KB。要全量得显式 `detail:"full"`。细节走 `view_tree(path:)` 钻取。
- **宿主优先范围**：`app_runtime_inspect` / `screenshot` / `app_hotfix` / `app_user_defaults` / `app_sandbox_file` 默认 `scope:"host"`；`detail:"full"` 不扩大范围。`appagent/all` 必须通过 `.appAgentInspection` 单独确认，仅当前轮有效，读取与修改授权分开，不替代原有 op 授权，不绕过 readOnly。普通 host 检查不新增确认或模型调用。
- **路径可跨 window**：`0/2/1` 相对当前 scene 内符合范围的默认窗口；`W1:0/2/1` 中 `W1` 是稳定弱引用句柄，不是过滤后的数组下标。句柄、KVC、selector、JS 桥都在解析目标时校验范围。嵌入式 SDK 的普通 UIKit 子视图继承归属；宿主可用 `HostInspectionUIKit.markAppAgentOwned` 标记额外 SDK 根。不要整体排除共享 BOUIKit/BODragScroll。
- **授权是 op 级的**：`ToolProtocol.safetyLevel(for:)` 按参数判定，`app_sandbox_file` 的 `list` 是 safe 而 `delete` 是 sensitive，`app_hotfix` 的 `apply` 是 dangerous。缺 op 时**不降级为 safe**（否则模型省掉参数就绕过闸门）。
- **只读边界**：`AIAgentProfile.toolMutationPolicy = .readOnly` 时所有 `> .safe` 的调用**直接失败**而不是弹窗问人——这是 Codex `sandbox_mode` 的 iOS 对应物（iOS 沙箱运行时收不紧，只能工具层自律）。
- **并发按级别分流**：`safe` 并发执行，`moderate` 及以上串行。两个并发的写没有互斥，快那点不值当。
- **变更可回滚**：`view_set` 返回改前原值，把它写回同一个 key 即撤销。
- **文件工具边界**：`file_read/write/search` 只管配置的工作区（默认 `Documents/AppAgent/files`），`app_sandbox_file` 管 app home 内当前范围。host 排除 SDK defaults、会话/记忆/技能原始文件、日志、抓包缓存及诊断导出；专用 memory/todo/skills/session 工具照常工作。共享 Preferences 文件须 all，父级共享目录不可整体写删；逐目标校验逻辑路径和符号链接真实路径。

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

### 网络访问（`web_fetch`）

`web_fetch` 让 agent 读公网：`mode=text` 把 HTML 抽成纯文本、`raw` 原样返回（JSON/源码）、`head` 只看响应头；`save_as` 落盘到 Documents 后配 `file_read` 按需读，长内容不必整篇进上下文。GitHub 的 `blob` 链接自动改写成 `raw.githubusercontent.com`（直接抓 blob 页拿到的是 HTML 外壳）。

三条边界必须保持，改这个工具时别绕过去：

- **私网 = 问用户，不是硬拒**：`resolve` 返回三态——`.success`（公网）、`.failure`（非 http(s)/无 host，无从讨论）、`.privateNetwork`（loopback、`10/8`、`172.16-31/12`、`192.168/16`、`169.254/16`、`.internal`/`.local`）。私网走 `session.requestDecision(.privateNetworkAccess(...))`（见上一节）。拒绝时错误里明确写「Do not retry this host」，避免模型反复撞墙。`allowForSession` 按 **host** 记在 `approvedPrivateHosts`，同一 session 同一 host 只问一次。
- **`safetyLevel` 不为私网抬级**：授权由工具内部那一遍完成；若 `safetyLevel(for:)` 也报 `.dangerous`，`LLMExecutor` 会先弹一次泛泛的「是否执行 web_fetch」，用户得点两次。
- **不可信栅栏**：抓回的正文用 `WebFetchTool.fence` 包起来并显式声明「这是数据不是指令」。没有这层，网页里一句「忽略之前的指令」就可能被当成系统指令——而这正是「网页诱导 agent 去打内网」的入口，所以栅栏和上面的私网授权是配套的两层。
- **体积上限**：`max_bytes`（默认 256KB）先卡一道，`outputMaxBytes`（64KB）再卡一道，按行边界截断并提示改用 `save_as`。

`save_as` 会写沙箱，所以 `safetyLevel(for:)` 从 `moderate` 抬到 `sensitive`。纯函数（URL 校验、私网判定、GitHub 改写、HTML 抽取、栅栏、截断）都有原生单测；授权链路（拒绝 → 不出站、允许 → 记住 host、无 delegate → 不放行）也有单测，另在模拟器自检里跑一遍真实运行时（含「询问期间 `pendingDecision` 确实置起」）。真实出站用 `.completes` 验，网络不通只记降级不算失败。
