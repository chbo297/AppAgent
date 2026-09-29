# UI 层细节约定（ChatPanel / 对话列表 / 输入栏 / 几何）

> **什么时候读这份**：改 `Sources/UI/` 下的对话列表、过程区、行高、输入栏、面板几何或键盘联动时。
> 下面每一条都来自真机踩过的坑，改对应文件前先读；平时不必常驻上下文。

### 挂载形态只有一种：独占一个穿透 window

宿主接 UI 的唯一入口是 `AppAgentOverlay`：它建一个 `AppAgentWindow`（`windowLevel = .normal + 1`、
命中自己返回 nil 所以空白处穿透），并把 `AppAgentViewController` 装成这个 window 的 rootViewController。
窗内没有独立的「悬浮球」视图——那颗球就是**收起态的输入栏**（`AppAgentInputBar.isCollapsed`，宽度收到
`AppAgentInputBarMetrics.collapsedMinWidth` = 56 时圆角变成整圆，靠 `.collapsedMove` 手势拖动）；拉开后依次是
输入栏、对话面板、会话切换列表。

**不支持宿主把 `AppAgentViewController` 塞进自己的 VC 层级**（push/present/`addChild`/SwiftUI 包一层都不行），
所以它是 `public` 而非 `open`，也不再留 `inputBarFrameDidChange` 这类子类 override 钩子（要观察就用
`onInputBarFrameChange` 闭包）。原因是下面整份文档的几何推导都建立在「独占一个全屏穿透 window」上：
面板 frame 直接按 window bounds 算、键盘高度按 window 坐标系换算、决策卡片贴 `viewportView.bounds` 底边。
嵌进宿主容器后这些前提全不成立，只会得到一堆位置错乱。宿主想要长在自己页面里的聊天 UI，就对着
`AISession` / `AIAgentEvent` 自己写。

仓库内部的 `AppAgentFailureDemoViewController`（报错演示页）确实把聊天 VC 当子 VC 嵌了一层——那是
AppAgent 自己的调试页，跑在 AppAgent 自己的窗口里，不是宿主集成路径；它必须
`registersDecisionPresenter = false`，否则两份面板会抢同一条决策责任链。

### 展示状态上报：宿主怎么知道自己被挡住了

宿主实现 `AppAgentPresentationDelegate.appAgentPresentationDidChange(_:)` 拿
`AppAgentPresentationState`（也可以随时读 `viewController.presentationState` 主动查）：
输入栏展开/收起与位置、**对话面板可见区的位置和高度**、键盘避让高度，以及 `areas`
—— 当前盖住宿主的所有矩形（输入栏 / 面板 / 侧栏 / 语音浮层 / 决策卡片），宿主 window 坐标。

四条容易写错的地方：

- **面板的可见区是 `viewportView`**（`clipsToBounds = true`）。别改成容器 frame（容器按设计
  「不参与裁切」，高度是满屏）也别用 `messageListFrame`（列表按完整 contentArea 布局，底边在
  可见区外面——决策卡片踩过）。用例 `testPresentationStateReportsInputBarAndChatPanelAreas`
  就锁这一条，换成容器立刻失败。
- **发射点有四个，少一个就漏报**：`applyInputBarFrame`（输入栏 / 面板容器 / 键盘）、
  `AppAgentChatPanelView.onViewportChanged`（**竖向拖拽拉高不经过输入栏那条路**）、
  侧栏 / 语音浮层 / 决策卡片的显隐、`AppAgentOverlay.show()/hide()`。
- **去重只比几何与显隐**，`reason` / `animation` 不参与：同一份画面不许报两次。
- **`opacity` 必须逐级乘祖先 alpha**：面板淡出写在**容器**上，只看 viewport 自己的 alpha 会
  报出「已经透明了却还说在挡」的假遮挡。
- 动画参数来自 `AppAgentInputBarFrameAnimation.presentation` 这一份（`makeAnimator` 也用它），
  键盘那条路则来自 `ambientKeyboardAnimation`——宿主要跟着同速动，拿到的必须是我们真正用的曲线。

### 对话列表：两层消息，别混为一谈

**wire 层 ≠ 展示层**，这是这个 UI 最容易踩错的地方：

- **wire 层**（`AIAgentMessage`）：一次提问会展开成多轮 assistant ↔ tool 往返，而且工具结果在协议上必须是 `user` 角色（两家协议都这么要求）。这是给模型看的。
- **展示层**（`ChatMessage`）：一次提问 = 一个用户气泡 + 一个 agent 回复。agent 回复无背景、横向铺满，正文与过程区左右统一留 14pt；用户保持原气泡样式。内部多轮往返收进**过程区**，有思考、工具或失败信息的回复结束后保留「处理过程」入口，点击展开、再次点击收起，不展示耗时或轮数；没有这些明细的已完成纯文本回复只显示最终结果，不显示过程入口。

归属关系由 Core 打好的 `AIAgentMessage.turnID` 决定，**不靠位置猜**：`AISession.addUserMessage` 递增 `currentTurnID`，executor 产出的 assistant / 工具结果消息都打上同一个号。上下文压缩改写过消息列表也不会错挂。

- **只有 `isGenuineUserInput` 才配当用户气泡**：`role == .user` 且不含 `toolResult`。曾经直接把 wire role 当气泡归属，于是「Result: Error: Tool 'web_fetch' not found」这种工具错误以蓝色用户气泡的身份出现在对话里。
- **组装入口只有一个**：`ChatMessageAssembler.assemble(_:turnRecords:streamingText:expandedTurnIDs:collapsedTurnIDs:)`。`AppAgentViewController.reloadFromSession` 调它，别在别处再写一套 role → 气泡的映射。
- **失败 / 空回复也必须有气泡**：这类信息不在 wire 记录里，靠 `turnRecords` 带进来（见「一轮的执行阶段 + turnRecord 落盘」一节）。踩过：executor 先 `setStreaming(false)` 触发 `reloadFromSession`，而组装器会丢掉「既无正文又无过程」的空轮，于是「尚未配置 API Key / No provider configured」这类失败在界面上**完全没有反馈**。`handleUIStateChange` 的 `lastError` / `runStage` 分支只负责再 reload 一遍，本身不再携带状态。
- **过程区归属「当前 turn 的 assistant 气泡」，不是最后一行**：本轮还没吐正文时列表末尾是刚插入的用户气泡，写上去过程区就挂到蓝色气泡上了。`applyActivity` 同时匹配 `.assistant` 与当前 `turnRecord.turnID`，终局已记录时拒绝迟到的实时事件；列表侧是按 id 定位的 `updateActivity(_:expanded:messageID:)`，`ChatMessageCell.configure` 也要判 `role == .assistant` 才显示过程区。**流式正文也更新 assistant 气泡**（`handleUIStateChange("streamingText")` + `updateMessage(text:status:messageID:)`），两条路径别再一个按行一个按角色。
- **展开态记在 turnID 上**：`ChatMessage.id` 每次组装都是新 UUID，所以「用户点开了哪一轮」存在 VC 的 `expandedActivityTurnIDs`，再通过 `assemble(expandedTurnIDs:)` 生效；列表点击用 `listView.onActivityToggled` 回传。换会话时清空。
- **每轮结束的重建不许把人拽回底部**：`listView.setMessages(_:forceScrollToBottom:)` 默认只在「本来就贴着底」时滚；只有换会话 / 首次装载 / 灌样例对话传 `true`。
- **流消费 Task 必须认会话**：`sendMessage` 先 `currentStreamTask?.cancel()`，Task 内每个事件前 `guard !Task.isCancelled, currentSessionId == boundSessionId`，流断掉后的补收尾也过同一道闸——否则切走再切回来时旧 Task 会把上一个会话的时间线写到新列表上。
- **工具失败只看 `ToolCallResult.isError`**，不嗅 `Error:` 前缀：那串文案是给模型看的，工具正常返回的正文（比如读出来的日志）也可能这么开头。
- **过程区从记录推导**，不是运行时快照：所以切换会话、重启 App 之后历史里的工具往返与中间发言仍可查看（旧的 `lastTurnActivity` 快照机制已删除；仅实时 reasoning delta 尚未持久化）。时间线起止优先取 `turnRecord.startedAt/endedAt`，旧历史才回退消息时间戳。`roundCount` 仍记录执行循环次数（含重试/回退），不是工具调用数；旧记录未带此键时以 assistant 消息数回退，但 UI 不再展示耗时和轮数。
- **当前界面已显示的 reasoning 不因终局重建而丢失**：`reloadFromSession` 按 turnID + 记录起点合并当前会话已展示的明细；wire 中间发言用消息/block 的稳定 ID 与实时 reasoning 区分，按共同条目保序去重，工具最终结果优先。阶段、终态、耗时与轮数仍以记录为准，不能用旧 live 时间线整体替换。下一轮与重复刷新继续保留这些明细；切换会话清空展示缓存，不新增 reasoning 跨重启持久化。
- **旧快照兼容**：`turnID` 是后加的键，Optional 的合成 Decodable 用 `decodeIfPresent`，缺键即 nil；nil 时按「真的用户发言开新一轮」回退。
- **整体替换消息列表也要带上编号**：`AISession.updateMessages` 把 `currentTurnID` 抬到新列表里的最大号（只往前走）。否则恢复快照 / 压缩回写 / 灌样例对话之后，下一条提问会复用旧号并被并进历史里的某一轮。

### 过程区的 Codex 风格输出

- 对照源码：`openai/codex` 的 `codex-rs/tui/src/exec_cell/compact.rs`、`history_cell/activity_preview.rs` 与 `chatwidget/activity_presentation.rs`（本次参考 revision `a69d757cd8ef8310001186865911b69e4b4175e5`）。采用 `• 动作` 主行 + `└` 缩进明细，折叠只留标题行，展开读取保留的全文。
- **折叠就只剩标题行**：标题本身已经在说「思考中…」/「执行 X…」/「处理过程」，下面不许再挂一条「最新动作预览」。踩过：运行中点收起，`previewLabel` 恰好满足「运行中 + 已收起 + 有明细」而显形，同一条 thinking 被标题和预览各渲染一遍，看起来像收起之后又冒出一个新的「思考」块。`AppAgentActivityTranscript.detail` 因此不再有预览分支，展开即全文。
- `AppAgentActivityTranscript` 只负责展示格式；不要在 `ChatMessageAssembler` 中提前截断工具错误和输出。工具预算仍由 Core 管，展示层不做二次裁剪。
- `AppAgentActivityView` 保留运行中阶段图标；无失败的完成轮隐藏阶段条。有终局失败或工具失败时保留失败阶段与标题，点摘要或错误图标经同一条 `onToggle` → 列表高度重算链路展开过程；终局错误正文已经在最终结果区展示，过程区不得重复渲染。工具条目自身的失败结果仍属于真实过程明细，可以在展开后查看。
- 运行中默认展开，结束默认收起；显式选择由 `expandedActivityTurnIDs` / `collapsedActivityTurnIDs` 保存，阶段重建和终止事件均尊重用户选择。切换会话时清空。
- 当次运行的最新 assistant 回复按「半屏有效列表区域 + 用户消息尾部仍可见」决定初始留白，内容顶对齐、空白留在下方；外层几何未就绪时先用 fallback，首次真实几何到达后接管。内容增长沿既有阶梯策略单调增加，当前连续阅读期间不因几何变化、成功、失败或折叠缩高。重新进入聊天、切回会话、页面重建或显式刷新展示时，已结束的尾回复恢复实际内容高度，仍在运行的回复保留已分配高度。`reloadFromSession` 默认代表重新浏览；运行通知 / 终局事件调用时必须显式传 `preservingReplyHeight: true`。用户消息始终按实际高度。
- **跨重建的行状态一律挂在稳定身份上，身份由有意义的字段生成**：`ChatRowIdentity` =
  `turn(turnID:role:)`。`turnID` 由 Core 分配并随快照落盘，一轮里「用户气泡 / agent 回复」用 `role`
  区分，所以这两项就唯一确定一行。**不能用 `ChatMessage.id`**（每次组装都是新 UUID）。
  还没拿到编号的乐观占位退化成 `transient(UUID)`，只在本次列表内有效，下一次重建被权威行取代。
  不用「创建时间 + 同秒编号」那一路：`ChatMessage.timestamp` 是 assemble 时的 `Date()`，不是消息真正
  的创建时刻，做不了稳定 key；真正稳定的时间戳是 `turnRecord.startedAt`，而它与 `turnID` 一一对应，
  再拼进身份只是冗余。`startedAt` 只用在 `isSameLatestReply` 判断「新旧快照是不是同一轮」。
- 实际内容高度由 `ChatMessageHeightCache` 测量并缓存：**身份 → 宽度桶 → (测量输入, 高度)**，
  同时保留几个宽度（旋转 / 分屏 / 拖窗回来都能命中，桶数有上限 + LRU 淘汰，否则连续改宽会变成内存泄漏）。
  高度不挂在 `ChatMessage` 上：它是值类型，每次重建都是新实例，挂上去的高度会跟着实例一起消失。
  失效用**计算式判等**（`Input` 的 `Equatable`，含 `suppressResolvedActivity` / `isActivityExpanded`），
  不设 dirty flag —— 命令式标记漏一处就是行高偏小 + `clipsToBounds` 把正文裁掉。展开态不预存两份高度，
  而是作为判等输入之一，变了才重测。
- 当前回复的**已分配高度**由列表独立持有（不是内容高度，是占位留白）：乐观占位转权威记录时保留，
  换会话显式重置；宽度变化只重测内容，不降低当前轮已分配高度。增长是一条显式命令
  （`reserveLatestReplyHeight()`），`rowHeight(at:)` / `heightForRowAt` **纯读不写** —— 把增长藏在
  getter 里会让「读一次高度」等于「消耗一次增长」，刷新前后两次取值相等就把该提交的 batch 短路掉了。
- 思考和工具明细共用一个带高度上限的内部 `UIScrollView`（具体上限见 `AppAgentActivityView`），超出内部滚动，全文不裁剪；短明细按实际高度。高度上限必须在模板 cell 首次 Auto Layout 测量时生效，不能依赖布局后再回写高度。展开后的过程行使用不可编辑但可选择复制的 `UITextView`，自身不滚动，复用已有文本视图而不逐字拆建整棵 stack。
- 过程明细的**阅读位置同样归列表**（`AppAgentChatMessageListView.activityDetailPositions`，
  按 `ChatRowIdentity` 索引），`AppAgentActivityView` 只负责「应用」和「上报」：存在视图里就等于存在
  「谁碰巧复用了这一格」上，行滚出屏幕再回来会归零或串到别的行。
  位置是 `AppAgentActivityDetailPosition`（offset + **是否贴底**两项：只记 offset 的话，明细追加后
  offset 没变但已经不在底部，「运行中跟随最新一行」就断了）。只在**用户拖动**时上报
  （程序化恢复也会走 `scrollViewDidScroll`，那时布局可能还没完成、最大 offset 是 0，回写会把存好的位置抹成 0）。
  乐观占位转权威记录时按身份迁移；收起不覆盖（过程区隐藏时直接 return，不写 offset）；
  换会话 / 清历史由 `setMessages` 按「还在列表里的身份」过滤后一并清掉。
- 展开态变化经同一条行高刷新链路同步布局：原位配置现有 cell，同高度不更新表格，高度改变才用空 `performBatchUpdates` 重新取高，不用 `reloadRows` 替换 cell；正文渲染输入不变时不重新解析 Markdown 或写入 `attributedText`。cell、contentView 与过程区都用 `clipsToBounds` 裁切，避免自动收起时旧文本短暂画到相邻行。没有明细且没有失败信息的完成轮隐藏整个过程区，即使保留了展开偏好，也不显示「本轮未记录思考或工具明细」或占用过程高度。
- Demo 的 `-show-sample-conversation` 可叠加 `-focus-sample-activity`（定位折叠摘要）或 `-expand-sample-activity`（经列表折叠链路展开）；样例工具失败必须显式设置 `isError: true`。这些参数只用于程序化截图，不替代真实触摸验收；灌样例会清空当前 Demo 会话，请使用隔离模拟器。

### agent 回复的 markdown 渲染

`ChatMessageCell` 里 assistant 正文走 `AppAgentMarkdown.attributed(...)`，用户自己的话保持纯文本。三个坑都实测踩过，改这个文件前先读注释：

- **`NSAttributedString(AttributedString)` 不认块级结构**：`AttributedString` 把标题/列表/段落记在 `presentationIntent` 里，转成 NSAttributedString 后这些元数据不产生换行，整篇会糊成一段。必须按块边界自己补换行。
- **只有空行分隔的块才算不同块**：`- 甲\n- 乙` 会被并进同一个块，光看 intent 分不开。所以解析前先做一遍块级规整（`normalizeBlocks`）：块之间补空行，列表项/表格行自带字面量前缀。前缀刻意用不成 markdown 标记的形式（无序用「• 」，有序序号后跟不换行空格），否则会被解析器当列表标记吃掉、列表项又并回一块。
- **属性一律用 `NSAttributedString.Key` 写**，不要用 `attributed[range].strikethroughStyle` 这类动态查找：同名属性在 UIKit 与 SwiftUI 两个 attribute scope 里都有，动态查找会挑中 SwiftUI 那个，而本 target 不链接 SwiftUI —— 直接变成链接错误（`Undefined symbols: SwiftUI.Text.LineStyle`）。
- **每个 run 从解析结果转过来**（`NSAttributedString(AttributedString(slice))`），只覆盖字体与正文色：按字符串重建 run 会把解析器给的 `.link` 丢掉，链接就只剩样式、点不动。删除线记在 `inlinePresentationIntent` 里、转换时不落成属性，要额外补 `.strikethroughStyle`。
- **GFM 表格**：系统解析器不认，会退化成普通段落且各列直接拼在一起。`normalizeBlocks` 把表格改写成「表头：值」的条目行。真表格渲染要引入第三方渲染器，暂不做。

`Tests/UI/AppAgentMarkdownTests.swift` 断言的就是渲染出来的字符串（块要各占一行、表格不粘连），改渲染逻辑先跑它。

## 输入栏右侧动作槽：加号 / 发送 / 停止

对照另一个 agent app（ChatGPT iOS）的输入栏：右下角那一格是**一个槽三种形态**，不是三个按钮堆在一起。
`AppAgentInputBar.trailingAction` 由两个输入派生，优先级固定：

- **有草稿 → `.send`**：蓝色实心圆 + 白色 `arrow.up`，**语音按钮一起隐藏**，界面上只剩「把这段话发出去」；
- **无草稿 + loop 运行中 → `.stop`**：同一个蓝圆 + 白色 `stop.fill`（配上圆底就是「外圆内方」），语音按钮照常可用；
- **其余 → `.plus`**：原来的加号。

- **形态只由派生决定**：点击统一走 `trailingActionTapped` 按当前形态分发，外面不要再判一遍草稿。
  `hasDraftText` 会 trim 空白（纯空格不给发送按钮，否则是个点了没反应的死按钮）；语音长按的
  `canBeginVoiceInput` 仍按「空白也算已输入」判，两者刻意不同。
- **运行状态由宿主写入，inputBar 不自己猜**：`setRunActive(_:)`。`AppAgentViewController.isAgentRunActive`
  的口径是「执行器手上还有活」——`session.isRunning`，加上「当前轮记录还没终局」兜住任务已摘、记录未关的那一小段；
  并在 `reloadFromSession` / 每次 `uiState` 通知 / 发送后 / 流关闭后各同步一次。**流关闭（`for await` 结束）
  发生在 executor `clearRunTask` 之后**，那是「已经不在跑了」最可靠的一刻，少了这次同步按钮会卡在停止态。
- **按过停止就不再邀请第二次**：`stoppedRunTurn`（会话 id + turnID）记下用户已经停过这一轮。executor 可能还卡在
  工具里没走到取消检查点、`turnRecord` 也就还没关，但按钮必须立刻切回加号；新一轮 turnID 一变自然失效。
- **发送即打断**：运行中发新内容（打字发送或语音转文字）默认先取消上一轮。`LLMExecutor.run` 自己也会取消上一个
  任务，但 UI 侧显式 `session.cancel()` 一次，上一轮才会明确记成 `.cancelled`（界面「（已停止）」），
  而不是等兜底补一个 `runEndedWithoutResult`。同一会话重跑不占新并发额度（`RunGovernor.canAdmit` 的 `isAlreadyRunning`）。
- **撞并行上限要弹窗，不许静默 return**：上限 9（`RunGovernor(limit: 9)`，只算 `delegationDepth == 0`
  的顶层会话；`delegate_task` 派出去的子会话完全豁免）。撞线时 `sendMessage` 在任何乐观 UI 之前就阻断，
  弹 `makeConcurrencyLimitAlert(runningCount:)` 告诉用户「已经有几个在运行」，**草稿留在输入栏**
  （`finishInputBarAfterSend()` 排在这道闸之后）。曾经这里只写一行日志就 `return`，用户的感受是
  「点了发送没反应」。Core 侧 `AISession.sendMessage` 仍是权威闸门，并通过
  `AIAgentDelegate.aiAgent(_:session:didRejectRun:)` 把 `AIAgentError.concurrencyLimitReached` 交给宿主，
  宿主自己那套 UI 要不要提示由它决定。上限是产品策略可调，但「撞线必须可见」这条不许退回去。
- **圆比加号里的圆再大一圈，但不铺满整格**：`trailingActionCircleSide = 24 + 8`（`plus.circle` 的符号尺寸
  再加半径 4pt——实心圆得压得住这一格），居中摆在加号那 40pt 的格子里；图标按这个圆的比例给
  （`arrow.up` 16pt、`stop.fill` 12pt，均 semibold）。圆比整格小但点按范围不许缩：`bo_hitAreaOutsets`
  外扩 4pt 补回整格（约定：命中区用 BOUIKit，不手写 `hitTest`）。
  `applyTrailingActionGeometry` 同时让 frame 和淡出 alpha 跟着 `plusButton` 走，bar 收窄 / 收起时一起淡出。
  `Tests/UI/AppAgentUITests.swift` 锁住三态、圆的尺寸与居中，以及「格子角上仍算命中」。

## 语音输入：太快松手算误触

`AppAgentVoiceInputCoordinator` 从 `begin`（= 面板亮起）开始计时，松手时不足
`timings.minimumValidPress`（生产 0.3s）就按**误触**处理：直接 `requestStopRecording(reason: .cancelled)`
关面板，**不走** send/edit 那条「多录 `trailingCapture` 尾音 + 等最终结果」的收尾，也不发送、不进编辑态、
不再补一次震动（按下那一下已经震过）。

- 判定不看松手落在哪个区（send / edit / cancel 一律作废）：这次交互当没发生过。
- 时间钩子是注入的（`init(now:)`），单测用假时钟推进；`.phase1` 把 `minimumValidPress` 设成 0，
  所以同步 `begin → end` 的老用例照旧验收尾逻辑。
- 键盘模式还叠着长按自身的 0.2s，所以那条路径实际要按住约 0.5s 才算一次有效语音输入。
- 用例：`Tests/UI/AppAgentVoiceInputCoordinatorTests.swift` 锁「0.2s 松手作废且无尾音请求」与
  「0.31s 照常进收尾」。

## 面板几何与写入判等

### 几何常量归 nonisolated 的 metrics 命名空间

输入栏与面板的几何常量都住在 `Sources/UI/AppAgentGeometry.swift` 的
`AppAgentInputBarMetrics`（`barHeight` / `innerPadding` / `buttonSize` / `minimumInputAreaWidth` /
`collapsedMinWidth` / `minimumExpandedWidth` / `expandedCornerRadius`）和
`AppAgentChatPanelMetrics`（`navigationBarHeight`）里，**不要再挂回视图类的 static 上**。
`AppAgentInputBar` / `AppAgentChatPanelNavigationBar` 是 UIView，Swift 6 下整类都是 `@MainActor`
隔离的，挂在它们身上的 static 也随之被视为主 actor 隔离；而 `AppAgentInputBarFramePolicy` /
`AppAgentChatPanelGeometry` 是刻意不带隔离的纯函数几何层（好让布局推导能在单测里直接调），
于是每个 nonisolated 读点都会被 Swift 6 点名一次
（`main actor-isolated static property 'X' can not be referenced from a nonisolated context`，
实测 40 处）。这些数没有主线程语义，一份真相放在 nonisolated 的命名空间里，两边都读得到。

### 写之前先判等（`bo_setFrame` / `bo_isScrolledToBottom`）

BOUIKit 0.2.0 起还提供几何层：`bo_setFrame` / `bo_setBounds` / `bo_setCenter`（不变就不写，返回是否真的写了）、`bo_isApproximatelyEqual`（容差默认 0.5pt）、`bo_maximumContentOffsetX/Y`、`bo_isScrolledToTop/Bottom`、`bo_isContentBottomVisible`、`bo_setContentOffset`。`Sources/UI/AppAgentGeometry.swift` 里的 `isApproximatelyEqual` 只是转发到 `bo_` 版本，别再写第二套容差。

**「贴底」有两个口径，别混用**：消息列表用 `bo_isScrolledToBottom` 判断包含 `adjustedContentInset` 的真实底部，以 `bo_maximumContentOffsetY` 为滚动目标。普通单次更新使用按当前屏幕 scale 换算的 **1px** 容差；BODragScroll 连续改变展示高度的跟手路径使用 **0.001pt**，避免逐帧判定和写入产生阶梯抖动。在更新消息、高度或 inset **之前**记录是否贴底，更新后才对齐新目标；首次分配视口仍强制到底。`bo_isContentBottomVisible` 只用于诊断，不能作为跟底条件，否则会提前跳过 inputBar 和间距占用的 bottom inset。

**最新回复占位空白的唯一例外**：初始留白基于半屏有效列表区域，并为用户消息尾部保留可见空间。列表滚到真实底部时，短回复的多余留白留在回复下方，用户消息尾部仍可见；跟随判定与写入共用原容差，用户上翻后不强拉，历史行和用户尾行仍按真实底部。

判等真正值钱的是三类写入，这几处必须走 `bo_`：

- **每帧驱动**：`AppAgentRegionDebugViewController.refreshOutlines` 的 `outline` 由 CADisplayLink 刷新，绝大多数帧几何没变。
- **写入有副作用**：给 scrollView 写 frame 会顺带重算并夹取 `contentOffset`（`AppAgentChatPanelCoordinator.updateLayout` 的 `dragScrollView`）；已经贴底还调 `scrollToRow` 会打断在飞的减速动画（`AppAgentChatMessageListView.scrollToBottom`）。
- **frame 承载动画**：重复写同一个 frame 会打断在飞的 `UIViewPropertyAnimator`。

其余 frame 写入点**不必**逐个包：它们多数已在更粗粒度上短路（`AppAgentChatPanelView.applyLayout` 的 `guard layout != appliedLayout`、容器与 `AppAgentInputBar.setInputBarFrame` 的 `isApproximatelyEqual`、`applyTableViewFrame` 的自带判等），剩下的只在 `layoutSubviews` 里跑一次，包一层只是噪音。

### 键盘顶起：只把容器整体上移，面板几何一概不动

**键盘的动画参数要整份拿过来用**：`AppAgentKeyboardObserver.Animation` 同时带 `duration` 和
`options`（曲线）。只用 duration 配 `UIView.animate(withDuration:)` 会落到 `.curveEaseInOut`，
而系统键盘用的是私有曲线（`UIView.AnimationCurve` 常量 7）—— 同时长不同速，看起来就是 inputBar 与
键盘「一起出发、中途分开、最后又汇合」。曲线原始值要左移 16 位才是 `AnimationOptions`。

**键盘只做一件事：把整个 ChatPanel 容器上移。** `AppAgentChatPanelGeometry` 不接受键盘参数，面板自身高度、
展示高度（`dragScrollView.displayHeight`）、档位在键盘抬起到收起的全过程里都不变；唯一变化的是
`AppAgentChatPanelContainerView` 的 frame（`applyChatPanelContainerLayout` 把 `view.bounds` 按 `keyboardLift`
偏移后交给 `AppAgentChatPanelContainerLayout`）。宿主接线只剩一句（`handleKeyboardHeightChange`）：在键盘自己的
`UIView.animate(withDuration: duration)` 块里调 `layoutInputBar(reason: .keyboard)`，inputBar 与容器在同一条
动画上下文里一起上移。

**走过的弯路别再回头**：曾经把 `keyboardLift` 从 `maximumDisplayHeight` 里扣掉、再在键盘动画块内 clamp 一次
展示高度（为了让面板顶部停在顶部安全区下沿）。代价是键盘每次抬起都要动展示高度，而展示高度由
`dragScrollView.contentOffset` 承载，链路上任何一次 scrollView frame 写入都会把在飞的 `bounds.origin` 隐式动画
夹掉，实测始终有一次闪动（改成判等写 frame 也没治住）。geometry 的 `keyboardLift` 参数与 coordinator 的
`clampDisplayHeightToMaximumHeight()` 因此整体删除。

**派生写入一律直接提交、继承调用方的动画上下文**。三条硬约定（都是实测踩出来的，别再回头加 trick）：

- **不剥动画**。面板内部几何曾经走 `UIView.performWithoutAnimation`，于是裁切窗口瞬跳到终态、内容再慢慢滑上来，看起来就是「先落后键盘、再跳一下」。
- **裁切与圆角用 `clipsToBounds` + `layer.cornerRadius` + `maskedCorners`，不用 `layer.mask`**。`layer.mask` 拿不到 UIKit 动画块的隐式动画（实测 `animationKeys()` 恒空，`CATransaction.setDisableActions(false)` 也救不了），而它又是唯一的裁切者；手工给 mask 补 `CABasicAnimation` 能治全屏那次跳动，但 `path` 那条会在半屏高度制造「内容重绘半截闪白」。面板背景同理改成 `layer.backgroundColor` + `cornerRadius`、**不设 `shadowPath`**（让 UIKit 从 layer 形状自己推，形状变化才跟着 frame 一起动）。上下圆角只有「四角同半径」和「只上两角」两种形态，正好用 `maskedCorners` 表达，`AppAgentChatPanelShapePath` 因此整个删掉了。
- **列表不做「高度冻结 + 按锚点平移」的中间态**。`updateVisibleArea` 直接写 tableView 高度，然后在「原来贴底」时 `scrollToBottom(animated: false)`；顺序不能反——视口变矮会把贴底的 offset 极限推高，落点必须在高度写入之后才算得对。曾经为此加过裁切容器 + 冻结高度 + 位移 + 收尾复位的一整套，结果它和 viewport 的裁切各走一条时间线，反而更跳。

`Tests/UI/AppAgentChatPanelGeometryTests.swift` 锁住三条：键盘抬起既不改面板高度也不改展示高度；容器随键盘整体上移；viewport 用 `clipsToBounds` + 圆角而不是 mask 裁切。
