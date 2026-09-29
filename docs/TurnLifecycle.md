# 一轮的执行阶段 + turnRecord 落盘 + 「必须有终止事件」契约

> **什么时候读这份**：改 `LLMExecutor` 执行循环、终止事件、turnRecord、阶段推进，或排查「界面一直转圈 / 没有反馈 / 切后台回来就不动了」时。


一轮的**全部状态只有一个真相来源：`AIAgentTurnRecord`**（`Core/Message/AIAgentTurnRecord.swift`），随会话快照落盘（`AISession.turnRecords` → `SessionSnapshot.turnRecords`），UI 只读它渲染：

```
turnID / startedAt / endedAt / stage / outcome / modelRef / roundCount
outcome = .answered | .empty | .failed(stage:message:) | .cancelled | .interrupted     // nil = 还在跑
```

流水线位置由 `AIAgentRunStage` 表示，UI 渲染成过程区顶部的小指示条：

`.preparing`（组装 prompt/工具清单）→ `.requesting`（请求已发，等首个内容）→ `.streaming`（收到首个 delta / 工具调用）→ `.tooling`（执行工具，可能在等用户拍板）→ `.finished`。

- **写入方只有 executor**：`LLMExecutor` 在 `addUserMessage` 之后 `openTurnRecord`，每次阶段变化 `advanceTurnStage`，终局 `closeTurnRecord`（**首次写入为准**，重复调用是 no-op）。`persistTurnState` 1s 去抖、终局强制落盘。`SessionUIState.runStage` 仍在，但只作为「该刷新了」的通知源，**不再是数据源**。
- **run 绑定自己分配的 turnID**：`addUserMessage` 返回锁内分配的编号，执行循环、消息归属与兜底收尾均显式传递它，不能在旧任务结束时重读已被新任务推进的 `currentTurnID`。`roundCount` 从 0 开始、进入循环后只增不减，终局后冻结；旧快照缺键为 nil。
- **不许再开第二条状态通路**。UI 侧曾经另从 `uiState.isStreaming / lastError / runStage` 读一份，这套双源正是三个真机 bug 的共同成因：loading 与过程区显示到**上一条**回复上面、指示条走到「完成」而下面的「思考中…」一直转圈、失败了界面上完全没有反馈。现在 `ChatMessageAssembler.assemble(_:turnRecords:streamingText:expandedTurnIDs:collapsedTurnIDs:)` 只吃记录；`streamingText` 是唯一例外（它是还没落盘的**内容**，不是状态）。
- **每个终局都要有可见的说法**：`ChatMessageAssembler.placeholder(for:hasActivity:)` 把 `.empty` 渲染成「（本轮没有返回任何内容）」、`.cancelled` 成「（已停止）」、`.interrupted` 成「（上次运行被中断…）」；`.failed` 把 `failureMessage` 以 `Error: …` 接在已有正文**后面**（半截答案本身也是线索，不覆盖）。最终流错误由 executor 保存当前尝试已收到的正文，不能把重试/模型回退期间的失败尝试正文或未执行的工具调用塞进下一次请求。
- **重启不自动重放**：`AISessionManager` 恢复后调 `session.markUnfinishedTurnsAsInterrupted()`，把上次没跑完的轮次标成 `.interrupted`，由用户决定要不要重问。在飞的 SSE 不可续、工具也不幂等，自动接着跑比中断更危险。
- **记录 → 时间线的映射只写一遍**：`ChatMessageAssembler.apply(_:to:)`。重建（`assemble`）和流式中（VC 的 `applyActivity`）都调它，两条路径因此不可能各说各话。它也负责「有终局但 stage 没到 `.finished`（失败/取消/中断）时照样 `finish()`」——不然折叠行会一直转圈。重建必须先应用失败记录再收尾，不能提前 `finish()` 把最远阶段点亮到完成；后续请求失败仍根据已有工具结果保留走过的工具阶段。
- **没有记录的轮次按「已结束、无阶段信息」渲染**：旧快照、灌进来的样例对话都是这种形状，不能因此转圈。
- **新加的快照键要能被旧数据缺席**：`SessionSnapshot.init(from:)` 对 `metadata` / `turnRecords` 用 `try?`。这两个键解不开就抛的话，`FileSessionStorage.loadAll` 会把**整段会话**丢掉。
- **阶段不是单调的**：一轮里多次工具往返会在 `.streaming` ↔ `.tooling` 之间来回，所以 UI 侧 `AppAgentActivityTimeline` 另记一个 `furthestStage`（只增不减）来点亮「已走过」的格子，否则指示条会来回闪。
- **失败停在出错那一步**：`outcome = .failed(stage:)` 不推进到 `.finished`，UI 只把对应阶段格标成红色警告，不再追加尾部警告。失败阶段格（`AppAgentRunStageStripView.onErrorTapped`）和过程摘要仍可展开过程；终局错误正文只在最终结果区显示，避免与过程区重复。「卡住时停在哪一步」是排查里最有用的一条信息，日志与诊断包也带上它。
- **本地报错演示**：👻 响应区域调试面板的「报错演示」按顺序自动发送 8 轮，覆盖准备失败、首次请求失败、请求重试耗尽、工具循环失败、输出中断、工具后请求失败、工具协议异常，以及工具失败但回答完成。独立页面使用隔离的 agent/注册表/内存存储，复用真实 executor 与聊天 UI，不调用真实模型、不注册全局授权 responder、不改原会话或草稿；支持停止、重播和关闭。演示脚本只模拟 provider/tool，不能直接伪造 turnRecord。
- **每轮恰好一个终止事件**（`.completed` 或 `.error`），这是硬契约：漏发就是真机上「回复一直是 …」（UI 靠终止事件收尾），重复发会让一轮被收两次。所以所有终止出口都收敛到 `TurnJournal` 的三个方法（`answered` / `failed` / `finalizeIfNeeded`），由它内部的 `claimTerminal()` 去重；`run` 的 `defer` 里调 `finalizeIfNeeded()` 兜最后一道底——补 `AIAgentError.runEndedWithoutResult`、清 streaming、**关掉 turnRecord**、记一条 `AppAgentDebugLog` failure。**别绕过 journal 自己 yield 终止事件。**
- 每个 assistant 回复都保留过程时间线数据，用于状态合并与历史重建；入口显隐统一由 `AppAgentActivityTimeline.shouldDisplayActivity` 决定。已结束、无 item 且无失败信息的纯结果回复隐藏过程区；运行中或有思考/工具/失败信息时保留。请求尚未发出便失败的轮次仍保留入口和失败阶段，不能只按 items 是否为空判断，也不能为了隐藏入口丢弃时间线数据。
- **「转圈」只有一个真相来源：`finishedAt`**。`ChatMessageAssembler.timeline(for:)` **不许**给「没有思考文本也没有工具往返」的轮次提前 return —— 那样返回的时间线没收尾（`isRunning == true`），折叠行会永远显示转圈的「思考中…」，而指示条早已走到「完成」。问一句「几点了」就是这种形状，实测踩过。配套地，`setStage(.finished)` 自己也会 `finish()`，让两个字段不可能各说各话。
- **组装器不许丢掉「正在跑的那一轮」**：空轮过滤条件必须放行「记录存在且没有 outcome」的轮次。丢了它，`applyActivity` 的「最后一条 assistant 气泡」就落到**上一轮**的回复上——loading / 过程区显示到上一条答案的上面（实测踩过，`handleUIStateChange(runStageKey)` 在 `.preparing` 就会触发一次重建，那时本轮的 assistant 消息还没进 wire 记录）。
- **`stop=tool_use` + 0 个工具调用 = 协议级异常，不是空回复**（OpenAI 兼容端点的 `tool_calls` 格式没被解析上就长这样）。**带正文也算异常**：那点正文通常是「我来看看当前页面…」这种过场话（实测收到过光秃秃一条 `...`），当成答案收下就会写进历史，下一轮模型拿它当自己的上一句、认为问题已经答过。处置顺序是「先换模型、再报错」：`LLMExecutor` 记一条 debug-log failure，然后按 `modelPolicy` 换下一个没试过的模型/协议重跑这一轮（同一个端点重试还是同样的解析结果，重试没意义）；fallback 用尽才 `finishWithError`。放它过去的话，界面就是「loading 转一圈然后什么都没有」——真机踩过。
- **没有产出的失败 / 被中断轮次不进 wire**：这类轮次只剩用户那句话（没有任何 assistant 消息）。它必须留在 `session.messages` 里给界面显示，但发给模型前由 `LLMExecutor.strippingOrphanTurns(_:keeping:)` 按 `turnID` 剔掉——正在跑的那一轮永远保留，旧快照里没编号的一律保留。实测不剔的后果：同一句提问在历史里堆了 4 条，wire 上出现连续多条 `user`（Anthropic 侧对交替严格），模型在思考里写「用户问了好几次」，还白烧 token。
- 用例：`Tests/Core/AppAgentCoreTests.swift` 锁「成功轮写 `.answered` + `.finished` + modelRef」「失败轮写 `.failed(stage:)` 且不推进到 `.finished`」「连 provider 都没有的轮次也有终局」「turnRecords 快照往返 + 旧快照无此键」「恢复时未完成轮标 `.interrupted` 且不改写已有终局」「失败轮恰好一个终止事件且 `failedStage == .requesting`」「成功轮停在 `.finished`」；`Tests/UI/ChatMessageAssemblerTests.swift` 锁四种终局的可见文案与「正在跑的一轮不被丢掉」；`Tests/UI/AppAgentActivityTimelineTests.swift` 锁 `furthestStage` 只增不减、`markFailed` 后 `finish()` 不把 stage 冲成 `.finished`。

## 打断与恢复（切后台 / 连接被撕掉）

> 症状：正在流式输出，把 App 切到后台再回来，界面就停在那里不动了。

iOS 把 App 切到后台几秒后挂起进程，协作线程池整体停摆，SSE 连接多半在挂起期间已被系统或对端撕掉。
回到前台后 `URLSession.bytes` 的失败模式**不是抛错，而是静默**：不再吐字节、也不报错，执行循环就停在
`for try await` 上，一直干等到 CFNetwork 的空闲超时（`provider.requestTimeout`，默认 300s）。
这是「界面一直转圈」的**第二个**来源，与上面那条漏发终止事件不同：事件没漏，是上游根本不再产生事件。

- **每条 provider 流都要先过 `StreamIdleGuard.wrap(_:idleLimit:onStall:)` 再交给循环消费**
  （`Core/Foundation/StreamIdleGuard.swift`）。它给相邻两个事件之间加时间上界，超限就以
  `ModelError.streamStalled(idleSeconds:)` 结束下游、并顺着 `onTermination` 取消上游（不留白烧 token 的连接）。
  **新增 provider 调用点时别忘了套**，漏套的症状就是本节开头那句。
- **空闲判据用墙钟（`Date`）而不是单调时钟，这是刻意的**：进程被冻结那段时间必须算进「没有进展」。
  墙钟天然把挂起时长计入，于是回到前台的第一个 tick 就判死重试 —— 也正因如此，**不需要再挂一个
  `willEnterForeground` 观察者**去催。轮询间隔由上界推出（`idleLimit/4`，夹在 50ms~1s），
  判定延迟最多 `idleLimit + tick`。
- **看门狗在执行循环这一侧包，不在 provider 里**：「多久没进展算卡死」是执行策略，provider 只负责搬字节。
  上界取自 `AIAgentExecutionPolicy.streamIdleTimeout`（默认 25s，`<= 0` 关闭），宿主可按端点排队情况调。
- **判死时只 `finish(throwing:)`，不先 cancel**。反过来的话，中继任务被取消后抛的 `CancellationError`
  会和 `streamStalled` 抢着结束下游，消费方看到的错误类型就变成不确定的了。取消统一交给 `onTermination`。
- **传输中断 ≠ 模型不可用**。`ErrorClassifier` 把 `streamStalled` 和非超时的 `URLError` 归入
  `.transport`：`retryable = true`、**`shouldFallback = false`**。端点是好的、断的是连接，换模型解决不了，
  只会白探测一轮候选。
- **重试前必须 `journal.attemptDiscarded()`**。`assistantText` 是每次迭代的局部变量、重来时从空开始，
  但 `uiState.streamingText` 不会自己清 —— 漏掉这一句，界面上就是「半截回答」后面紧跟一遍完整回答。
  这条以前只有模型回退分支调、重试分支没调；看门狗上线后重试成了最常走的路径，它也从偶发变成必现。
- **一轮的运行期全程持有后台执行断言**（`BackgroundActivity.begin(_:)`，
  `Core/Foundation/BackgroundActivity.swift`）。争来的 ~30s 让「切出去看一眼消息再回来」这种最常见的操作
  能把当前这一轮跑完。拿不到断言**不算错误**（额度用尽、非 UIKit 平台都可能），那时退回上面的判死—重试路径。
  UIKit 平台默认就装好真实实现、宿主零配置；`install` 只留给测试和已有自己后台任务管理器的宿主。
  过期回调里必须 `endBackgroundTask`，否则系统直接杀进程，所以 token 用「只结束一次」的盒子包着。
- **恢复是重发整个请求，不是续传**。SSE 不可续，代价是这一轮从头再来（上一次尝试的正文按上一条丢掉）。
  这也正是要先争取后台时间的理由：能跑完就不用恢复。进程真被杀掉之后的行为见上面「重启不自动重放」。
- 用例：`Tests/Core/StreamInterruptionTests.swift` 锁四条 —— 静默流变成 `streamStalled` 且上游被取消、
  持续有进展的流不被误杀、上界 `<= 0` 时整层旁路、以及「卡死 → 重试 → 只留最终正文」的端到端
  （判据是「每次尝试开始时 `uiState.streamingText` 必须为空」）。反向验证把 `idleLimit` 改成 0 时这一轮
  永不终止（正是线上现象），用例靠 `withDeadline` 把它转成失败而不是挂住。
