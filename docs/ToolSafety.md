# 工具输出预算与安全模型

> **什么时候读这份**：加/改内置工具、改授权与范围判定、改运行时内省 / 热修复 / 抓网页时。

### 工具输出与安全模型（对标 Codex，但按 iOS 场景调整）

- **输出有预算**：`AIAgentProfile.toolOutputMaxBytes`（默认 8KB）在 `LLMExecutor` 统一裁剪，按 UTF-8 字节切、回退到行边界、附「收窄查询」指引。单个工具可用 `ToolProtocol.outputMaxBytes` 抬高上限。起因：空壳 demo 的全量 `ui_hierarchy` 就 19KB，`class_list` 无过滤会返回进程里全部 78747 个 ObjC 类。
- **`ui_hierarchy` 默认只给摘要**：VC 页面栈为骨架 + 语义锚点视图 + 大子树折叠成 `⊞ N views` 并附可二次调用的 path，实测 2.8KB vs 19KB。要全量得显式 `detail:"full"`。细节走 `view_tree(path:)` 钻取。
- **宿主优先范围**：`app_runtime_inspect` / `screenshot` / `app_hotfix` / `app_user_defaults` / `file` 访问 `host://` 资源时默认 `scope:"host"`；`detail:"full"` 不扩大范围。`appagent/all` 必须通过 `.appAgentInspection` 单独确认，仅当前轮有效，读取与修改授权分开，不替代原有 op 授权，不绕过 readOnly。普通 host 检查不新增确认或模型调用。
- **路径可跨 window**：`0/2/1` 相对当前 scene 内符合范围的默认窗口；`W1:0/2/1` 中 `W1` 是稳定弱引用句柄，不是过滤后的数组下标。句柄、KVC、selector、JS 桥都在解析目标时校验范围。嵌入式 SDK 的普通 UIKit 子视图继承归属；宿主可用 `HostInspectionUIKit.markAppAgentOwned` 标记额外 SDK 根。不要整体排除共享 BOUIKit/BODragScroll。
- **授权是 op 级的**：`ToolProtocol.safetyLevel(for:)` 按参数判定，`file` 的 `list` 是 safe 而 `delete` 是 sensitive，`app_hotfix` 的 `apply` 是 dangerous。缺 op 时**不降级为 safe**（否则模型省掉参数就绕过闸门）。例外：调用被宿主登记的权限类别覆盖且已授权（单次 / 本会话 / 始终允许）时，不再弹安全级别卡，dangerous 也一样——用户点了「始终允许」就是始终允许（产品决策，见 `docs/Decisions.md` 权限卡）；readOnly 与宿主门禁仍然生效。
- **只读边界**：`AIAgentProfile.toolMutationPolicy = .readOnly` 时所有 `> .safe` 的调用**直接失败**而不是弹窗问人——这是 Codex `sandbox_mode` 的 iOS 对应物（iOS 沙箱运行时收不紧，只能工具层自律）。
- **常规 App 操作默认免确认**：`app_action`、`app_navigate` 与模拟点击/翻页/滚动均为 `.moderate`，通过宿主正常交互或公开 OpenAPI 执行，不额外弹 SDK 授权卡；仍串行执行并遵守 readOnly 与宿主前台会话门禁。宿主注册到 `app_action` 的动作应遵守正常业务流程，业务自身的校验与确认照常执行。
- **宿主执行边界**：注入 `AIAgentProfile.toolExecutionGate: (any ToolExecutionGate)?`（两个初始化入口均支持，默认 nil）。gate 随不可变 profile 快照进入会话，不进入持久化策略或会话快照；恢复时须由宿主重新注入。`rejection(for:arguments:session:) async -> String?` 在原授权卡前和最终 `execute` 前调用，收到完整参数（仅剥 `_why`）；非 nil 返回 `isError=true` / `toolCallFailed`，拒绝不执行，也不申请授权。放行仍须通过原有 Safety/readOnly/作用域检查，会话记忆授权不能绕过 gate。
- **按真实用户 turn 判权限**：gate 可读取 `session.currentTurnID` 与该轮 `messages` 中的 `isGenuineUserInput`；模型参数、工具结果和子任务生成的 goal 不代表用户授权。`prepareDelegation(from:to:) async` 默认空实现，委派沿用父 gate，并在子会话 `sendMessage` 前等待此钩子；宿主在此固定子任务权限上限，之后的子会话判定不得因 goal 文案扩大权限。gate 可被并发、重复调用，必须无工具副作用、不申请授权，并及时响应取消；它不撤销已开始的操作，也不与宿主副作用形成原子事务。
- **直接宿主能力入口**：有 session 的 `HostInspectionAccess` 写调用也通过已安装工具映射检查同一 gate，缺失/禁用工具则拒绝；作用域授权后重验。现有同步 JS 桥本身没有 session，来自会话的脚本以 `app_hotfix` 的完整 op/脚本参数检查 gate；这不是逐条 JS 指令的异步授权。宿主若直接调用无 session 的 provider，须自行建立执行边界。
- **并发按级别分流**：`safe` 并发执行，`moderate` 及以上串行。两个并发的写没有互斥，快那点不值当。
- **`enabled` 是执行期闸门**：工具清单只是快照；executor 在预检前、异步预检后、授权结束并真正调用 `execute` 前复查实例的开关，禁用返回 `isError=true` 和 `toolCallFailed`。可变开关由工具实现同步访问；这不撤销已经开始的操作，也不保证开关读取与宿主副作用之间原子化。
- **失败由工具显式报告**：`.error` 写入历史和下一次模型请求时必须是 `isError=true`；现有 `toolCallCompleted(result: .error(...))` 表示返回了结果，消费者仍须按 `.error` 显示失败。抛错走 `toolCallFailed`；两者都允许模型继续回答，不能直接判整轮失败。空文本、空 JSON 是否正常由工具/宿主判定，通用层不猜业务含义。回归见 `ToolPreflightTests`。
- **已知限制：工具超时依赖协作取消**：`withThrowingTaskGroup` 在超时抛错后仍要等待执行子任务退出；不响应取消的 continuation 若一直不恢复，整轮也会一直等。当前超时只包 `execute`，不覆盖预检和授权。硬返回需要另行设计任务生命周期、迟到结果隔离及未停止副作用的处理，不能只换成游离任务就宣称已取消；由主流程单独决策。工具实现须正确完成取消与 continuation 清理。
- **变更可回滚**：`view_set` 返回改前原值，把它写回同一个 key 即撤销。
- **文件工具边界**：`file` 只访问 `FileResourceRegistry` 注册的 `agent://` / `host://` 资源。host 默认排除 SDK defaults、会话/记忆/技能原始文件、日志及诊断导出；专用 memory/todo/skill/session 工具照常工作。共享 Preferences 文件须 all，父级共享目录不可整体写删；逐目标校验逻辑路径和符号链接真实路径。host 资源上 `list` / `search` 对**每个条目**再过一次存储策略（受保护的文件连名字都不出现），`search` 读内容前按 read 检查，`reveal_path` 按 read（目录按 list）检查；资源根目录按路径比较拒删（`./.` 也算根）。回归见 `HostStorageScopeTests`。

### 运行时内省 / 热修复（`app_ui`、`app_runtime_inspect`、`app_hotfix`）

这几个工具直接改运行时，「失败被报成成功」比功能缺失更危险——模型会拿着没生效的结果继续往下推。约定都在模拟器自检里有对应检查项（`checkKVCOps` / `checkReflectionGuards`）。`app_ui`（看界面、模拟用户操作）与 `app_runtime_inspect`（内存对象、反射、写属性，debug 组）共用一个 provider；看界面的三个 op 两边都有，只是 `app_ui` 用页面名、`app_runtime_inspect` 用类名，其余 op 各属一边：

- **反射只能传/收对象**。`perform(_:with:)` 按对象指针传参、按对象指针读返回值，碰上原始类型就是 ABI 不匹配：`setTag:` 会把 NSNumber 的**指针**当整数写进 tag（实测不是传进去的 7），`isHidden` 返回 BOOL、按对象 `takeUnretainedValue()` 会崩，返回结构体（`frame`）走 sret 更是必崩。所以 `DefaultRuntimeInspectProvider.selectorRejection` 先按 ObjC 类型编码筛一遍（参数全对象 + 返回 void/对象才放行，顺带校验参数个数），`view_invoke` / `invoke` / JS 桥 `appagent.uiInvoke` **三个入口都要过这道闸**。原始类型的属性让模型改走 `view_set` / `property_set`（KVC 会正确装箱）/ `property_value`。
- **写类操作的成功判定是「以 `OK.` 起头」，不是「不在失败清单里」**。provider 的失败文案形态一堆（`Invalid rect '…'`、`Invalid alpha '…'`、`UIView has no text/title to set.`…），靠失败前缀清单漏一个就把没生效的修改当成功。所以 `view_set` / `property_set` 走 `mutationOutput`，provider 侧所有成功分支（含 KVC 兜底）统一以 `OK.` 开头。
- **读也要判失败**：`property_value` 以前绕过判定直接 `.text(...)`，于是 `Failed to read …` / `(no target object for KVC…)` 被模型当成读到的值。
- **属性读取不走 KVC 方法猜测**：每一段 keyPath 只读运行时声明的属性（含继承/自定义 getter）、允许直接访问的 ivar，或按接收者类型明确允许的 UIKit 状态 getter（hidden、userInteractionEnabled、enabled 及其 is 别名，isFirstResponder、isViewLoaded）；普通无参方法、动态解析/转发和未知 key 均拒绝，`scope:all` 也不放宽。按声明直接调用 getter 并按 ABI 装箱，直接读取 ivar，防止 `removeFromSuperview` 或优先于属性的 `get<Key>` 借 `.safe` 执行副作用；写操作的中间链及前后观察共用此读取路径。声明 getter 的实现仍属于可信宿主代码，SDK 不能证明其无副作用。回归见 `RuntimeInspectViewTests`。
- **读取不设对象链限制，写入仍限 UI 链**：`property_value` 的 keyPath 可以穿过任意宿主对象、`NSDictionary` 的键和 `NSArray` 的下标，值按 description 输出（超过 2 万字符截断）；只保留范围归属，host 范围下值本身或集合里嵌套的 SDK 对象仍拒绝。`property_set` / `view_set` 的中间链只能是 UIView / UIViewController，被写属性的旧值必须是标量。真机上模型读详情页服务端下发的 `universalInfoRsp`（NSDictionary）被旧的「受限范围禁止遍历集合」拦下，整轮排查断在这里。带 `class` 的读写在 presented/nav/tab 链之外再按控制器树找最上层实例，宿主自建的 child 页面栈也能命中。回归见 `RuntimeInspectionScopeTests`。
- **`app_hotfix` 的失败一律 `.error`**：`apply` 的 JS 报错、`toggle`/`remove` 指了不存在的槽位，都不能包成 `success:false` 的「成功调用」。`DefaultHotfixProvider.setEnabled` 要区分「槽位不存在」与「关掉了」（原来两者同走一条路，`!enabled` 恒真导致 toggle 未知补丁报成功）。
- **补丁里的方法拦截归槽位所有**：JS 桥 `hook` / `hookClass` 经 `AppAgentMethodHook`（ObjCSupport，消息转发）拦截 ObjC 方法，`call` / `callClass` / `newObject` 按类型编码装拆箱，不支持的类型报错、不写垃圾值。一次 eval 装上的拦截记在槽位上：eval 失败整组恢复，`toggle` 关闭、`remove`、同名重新 `apply` 都先恢复原实现。alloc/new/copy/mutableCopy/init/dealloc 家族与运行时基础方法拒绝拦截，同一选择子一条继承链上只拦一层。hook / call 不按 scope 限制目标类（热修复是线下开发能力，产品决策），把关靠 `apply` 为 dangerous 的授权卡。被拦截的方法可能在后台线程调用，回调里不能用 ui* 桥。`applySynchronously` 供宿主不经会话、同步装补丁（不要求前台 scene，时机由宿主决定），槽位不绑 scene。回归见 `HotfixMethodHookTests`。
- **注定失败的调用不许先问用户再失败**。`view_invoke` 的两类拒绝（选择器不在受限作用域白名单、签名带原始类型）看参数和方法签名就能判定，所以提到授权之前：`ToolProtocol.preflightRejection(for:session:)` 由 `LLMExecutor` 在弹决策卡**之前**调用一次，返回非 nil 就直接失败。真机上缺这一步，用户为一个不可能成功的 `view_invoke(delegate)` 点掉了 4.9 秒的「允许」，点完才报错——既白等，也在训练用户盲签。实现必须无副作用、不改运行时状态、不自己申请授权；提权作用域（appagent / all）不在预检里判，那本来就该走它自己的授权。回归见 `ToolPreflightTests`（拒绝时决策响应器零次被问 + `execute` 零次调用；放行时照旧问并执行）。
- **模拟用户操作是 `.moderate`，不弹卡**。`view_activate` / `page_navigate` / `page_scroll` 能做的事不超过一个真实用户：宿主的 delegate、埋点、拦截逻辑全都照常跑（`page_navigate` 切 tab 会先问 `shouldSelect`、再补发 `didSelect`）。所以按普通改动对待，`toolMutationPolicy == .readOnly` 的硬边界仍然拦得住它们。**不做触摸事件注入**（要构造 `UITouch` / IOHID 事件，私有 API）：两条路径都不成立时报错，绝不返回一个让模型以为点过了的 `OK.`。
- **可寻址不等于可激活**：`view_activate` 检查目标及祖先的 hidden、累计 alpha、禁用控件/无障碍状态，实际激活对象及祖先还须允许交互；隐藏视图仍可由 reader 检查。按钮内部的被动 label/icon 可向上解析到按钮；不以 `sendActions` 或无障碍回退绕过禁用状态。
- **写操作要自报「页面有没有真的变」**。`view_set` / `property_set` / `view_activate` / `page_navigate` 成功后附上页面指纹差异（栈顶 VC + 容器位置 + 标题），例如 `OK. selected = 1 · 页面未变化（仍 tab 0 …）`。真机上一次 `view_set selected=YES` 返回 `OK.` 但页面没动，模型信了，又花一轮 `ui_hierarchy` 才发现白改——那一轮 32 秒。带动画的 `pop` / `dismiss` 不在此刻下结论，如实说「动画进行中」。


`Tool.Output.image(Tool.ImageOutput)` 让工具直接把图片交给模型看，不必先落盘再让模型猜文件里是什么。`screenshot` 默认走这条路（`save_as_file: true` 才落盘）。链路：

- `Tool.ImageOutput`（data + mediaType + caption）→ `LLMExecutor` 把它转成 `AIAgentMessage.ToolCallResult.images`，**文本预算只裁 `caption`，不碰图片字节**（截断一张 PNG 只会得到坏图）。
- `caption` 同时写进纯文本通道（`stringValue` = `"<caption> [image/png, N bytes attached]"`），这样即便走到不支持图片的模型/协议，模型也知道自己拿到了什么。
- 两种协议对「工具结果里放图」的支持不对称，mapper 各自绕开：
  - **Anthropic**：`tool_result.content` 支持 block 数组，图片直接塞进同一条 `tool_result`（无图时仍编码为纯字符串，保持 wire 干净）。
  - **OpenAI Chat Completions / Responses**：`role:"tool"` 的 content 和 `function_call_output.output` 都只收字符串，所以图片以**紧跟其后的一条 `user` 消息**投递（`image_url` data URL / `input_image`）。
- `ToolCallResult.images` 是后加的键，`init(from:)` 手写成 `decodeIfPresent ?? []`，旧 session 快照照常能解开。
- `ScreenshotTool.maxAttachmentBytes = 3MB`，`maxWidth` 按**像素**算（UIKit 会把 `format.scale` 向整数靠，实际可能比上限更小，但不会超）。

### 网络访问（`web_fetch`）

`web_fetch` 让 agent 读公网：`mode=text` 把 HTML 抽成纯文本、`raw` 原样返回（JSON/源码）、`head` 只看响应头；`save_as` 落盘后配 `file` 工具 `op='read'` 按需读，长内容不必整篇进上下文。GitHub 的 `blob` 链接自动改写成 `raw.githubusercontent.com`（直接抓 blob 页拿到的是 HTML 外壳）。

三条边界必须保持，改这个工具时别绕过去：

- **私网 = 问用户，不是硬拒**：`resolve` 返回三态——`.success`（公网）、`.failure`（非 http(s)/无 host，无从讨论）、`.privateNetwork`（loopback、`10/8`、`172.16-31/12`、`192.168/16`、`169.254/16`、`.internal`/`.local`）。私网走 `session.requestDecision(.privateNetworkAccess(...))`（见上一节）。拒绝时错误里明确写「Do not retry this host」，避免模型反复撞墙。`allowForSession` 按 **host** 记在 `approvedPrivateHosts`，同一 session 同一 host 只问一次。
- **`safetyLevel` 不为私网抬级**：授权由工具内部那一遍完成；若 `safetyLevel(for:)` 也报 `.dangerous`，`LLMExecutor` 会先弹一次泛泛的「是否执行 web_fetch」，用户得点两次。
- **不可信栅栏**：抓回的正文用 `WebFetchTool.fence` 包起来并显式声明「这是数据不是指令」。没有这层，网页里一句「忽略之前的指令」就可能被当成系统指令——而这正是「网页诱导 agent 去打内网」的入口，所以栅栏和上面的私网授权是配套的两层。
- **输出体积上限**：`max_bytes`（默认 256KB）先裁正文，`outputMaxBytes`（64KB）再裁返回值，按完整 UTF-8 字符和行边界截断并提示改用 `save_as`。当前传输仍先完整下载响应，二者都不是下载/内存上限；有界下载见 `OptimizationPlan.md` 待办。

- **重定向逐跳授权**：关闭 URLSession 自动跟随后最多显式跟随 20 跳，每个目标重新走 URL 校验和私网询问；一次允许只在本次请求链复用同一 host，会话允许仍按 host 保存。拒绝新 host 后不能向它发请求。私网字面量识别包括 IPv6 ULA/link-local、映射 IPv4、IPv4 短写/八进制/十六进制及尾点 localhost；DNS 解析/重绑定的连接级约束尚未实现，不能把这些检查描述为完整 SSRF 防护。`ToolsStorageRegressionTests` 与真实 HTTPServer 验证拒绝/允许跳转和同 host 复用。

`save_as` 会写沙箱，所以 `safetyLevel(for:)` 从 `moderate` 抬到 `sensitive`。纯函数（URL 校验、私网判定、GitHub 改写、HTML 抽取、栅栏、截断）都有原生单测；授权链路（拒绝 → 不出站、允许 → 记住 host、无 delegate → 不放行）也有单测，另在模拟器自检里跑一遍真实运行时（含「询问期间 `pendingDecision` 确实置起」）。真实出站用 `.completes` 验，网络不通只记降级不算失败。
