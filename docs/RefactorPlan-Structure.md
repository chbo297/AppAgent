# AppAgent 结构重构方案（LLMExecutor / AppAgentInputBar）

> 2026-09-28 产出。基于实测行数与逐段读码，非估算。
> 目标：**把"必须小心改"的原因从纪律搬到结构**，而不是单纯减少行数。
>
> ⚠️ 文中 `LLMExecutor.swift` 的行号基于 2026-09-28 14:49 之前的版本（1620 行）。
> 该文件随后被改动（现 1627 行），**行号整体下移约 7–8 行**；函数名与代码片段仍然准确。
> 动手前用 `grep -n` 重新定位，不要直接按行号跳。

---

## 0. 体量现状（实测）

| 目标 | 行数 | 结构问题 |
|------|------|----------|
| `Sources/Core/Session/LLMExecutor.swift` | 1619 | `runLoop` 599 行 + `executeToolsConcurrently` 327 行 = **57%** |
| `Sources/UI/AppAgentInputBar.swift` | 1431 | 14 个可变状态字段，其中 **8 个只服务 pan 手势**（300 行） |
| `Sources/Core/HostCapability/DefaultRuntimeInspectProvider.swift` | 1140 | **零 stored property**，全 static —— 拆分收益低，不做大改 |
| `Sources/UI` 占 `Sources` 比例 | 42.3% | 合理；约定已有 ~60% 被测试/类型锁住 |
| `AGENTS.md` | 559 | 九成是踩坑史（决策依据），不是该搬进代码的东西 |

**结论**：LLMExecutor 的问题真实但定位在"两个巨型函数 + 四条并行状态通路"；
RuntimeInspect provider 不值得为行数拆；UI 占比不是问题。

---

## 1. 不变量清单（重构期间一条都不许破）

每条后面是**破了会发生什么**。改动前后都要按这张表自查。

- **I1 每轮恰好一个终止事件**（`.completed` 或 `.error`）。漏 → 界面永远停在 "…"；重复 → 一轮被收两次。
- **I2 `isActiveRun` 三层门控不对称**（见 §3.1）。把记录面拖进 UI 门控 → 被抢占的旧轮次永远没有终局，重启后静默变 `.interrupted`。
- **I3 失败停在出错那一步**：`outcome = .failed(stage:)` 不推进 `.finished`。
- **I4 取消与失败分开**：`error is AIAgentError.cancelled` → `.cancelled`，界面显示「（已停止）」。
- **I5 `run()` 的 defer 顺序**：`finalizeIfNoTerminalEvent` → `clearRunTask` → `continuation.finish()`。
  先摘 task 会导致 finalize 时 runID 已非 active，UI 清不掉。
- **I6 delta 路径的三步顺序**：`yield` → `setStage(.streaming)` → `uiState.append`。
  顺序变了会改变"首个 delta 触发的那次 reload 是否已包含该 delta"。
- **I7 turnID 显式传递**，不得重读 `session.currentTurnID`（可能已被下一个 run 推进）。
- **I8 最终流错误只保留本次尝试的正文**，不把重试/回退期间的失败正文或未执行的 toolCall 写进历史。
- **I9 `persistTurnState` 去抖 1s，终局 `force: true`**。
- **I10 `stop=tool_use` + 0 调用 = 协议异常**：先按 modelPolicy 换模型重跑，fallback 用尽才报错。

---

## 2. LLMExecutor 目标结构

```
Sources/Core/Session/
├── LLMExecutor.swift            ~350  编排：run / cancel / runLoop 骨架
├── TurnJournal.swift            ~260  ★ 唯一状态写入方（§3，已落地）
├── RunLoopState.swift            ~70  runLoop 的 11 个可变局部
├── TurnPreparation.swift        ~180  system prompt / tools / provider 消息视图
├── ModelSelector.swift          ~150  primary + fallbacks + probe + triedModelKeys
├── StreamAttempt.swift          ~320  单次请求：SSE 消费 / 重试 / 协议异常 → AttemptOutcome
├── ToolRunner.swift             ~330  并发分流 / 授权 / 超时 / 预算裁剪
└── HostContextStage.swift        ~80  prepare / commit / discard 事务
```

---

## 3. TurnReporter —— 这次重构的核心

### 3.1 三层门控（★ 审核中发现原方案漏了这条，是最大的隐藏坑）

一轮的状态写往四个地方，但**门控条件是三套，不是一套**。实测对照
`finishWithError`(603-626) / `finalizeIfNoTerminalEvent`(286-314) / 成功收尾(1143-1167)：

- **UI 面** —— `session.updateMessages` / `uiState.*` / `agent.sessionDid*`
  → 受 `isActiveRun(runID)` 门控。被新 run 抢占后不许再动界面。
- **记录面** —— `session.closeTurnRecord` / `persistTurnState`
  → **无条件执行**。源码 305-306 注释写明：即使已不是 active run，也要关掉**自己的** turnID，
  否则重启后只剩一条无声空轮。
- **事件面** —— `continuation.yield(.completed/.error)`
  → 过 `noteTerminal(runID)` 去重后**无条件**发。流的消费者是发起这次 run 的调用方，
  它有权知道结果，与"谁是 active run"无关。

`TurnReporter` 必须把这三层写死在内部，调用方无法只写其中一层。

### 3.2 接口（已落地，见 `Sources/Core/Session/TurnJournal.swift`）

比初稿改了四处，理由见 §3.6。

```swift
final class TurnJournal: @unchecked Sendable {
    // 依赖单向注入 —— journal 不认识 LLMExecutor，测试可直接构造
    private weak var session: AISession?
    private let continuation: AsyncStream<AIAgentEvent>.Continuation
    private let isActive: () -> Bool               // runID 已绑进闭包
    private let persist: (AISession, Bool) -> Void // 节流是 per-session，留在 executor

    // 可变状态一律走 ReadersWriterLock
    private var _hasTerminated = false             // 取代 executor 的 [UUID] + 上限 + 淘汰
    private var _turnID: Int?
    private weak var _agent: AIAgent?

    func attach(agent: AIAgent)
    func prepareUI()                               // 五个 uiState 重置
    func openTurn(turnID: Int)                     // openTurnRecord

    func advanceStage(_:)                          // uiState + 记录整体受门控
    func recordModel(_:stage:)                     // 不受门控、强制落盘
    func advanceRound(_:)

    func contentDelta(_:) / reasoningDelta(_:)      // yield → stage → append，顺序是契约
    func attemptDiscarded()

    func answered(_:)                              // ← 三个唯一终局出口
    func failed(_:messages:)
    func finalizeIfNeeded()
    private func claimTerminal() -> Bool
}
```


```swift
/// 一轮的状态出口。final class、非协议 —— contentDelta 在每 token 路径上，
/// 协议会引入 witness table 间接调用。测试用真 reporter + InMemorySessionStorage，
/// 从 AsyncStream 收事件序列断言，不需要假实现。
final class TurnReporter {
    private weak var session: AISession?      // run() 有一条出口拿不到 session（112-116）
    private weak var agent: AIAgent?          // 构造时 agent 尚未解析（137 才 guard 出来）
    private let runID: UUID
    private let turnID: Int?                  // 早期失败出口可能还没分配
    private let continuation: AsyncStream<AIAgentEvent>.Continuation
    private unowned let owner: LLMExecutor    // 借用 isActiveRun / noteTerminal / persistTurnState

    func attach(agent: AIAgent)               // 后置注入，对应 137 之后
    func attach(turnID: Int)                  // 后置注入，对应 129 之后

    // 生命周期
    func turnStarted()                        // ← 122-133：uiState 五写 + openTurnRecord
    func stage(_ s: AIAgentRunStage, modelRef: String? = nil)   // ← 630-635 / 953 / 1056
    func round(_ n: Int)                      // ← 686-687

    // 流式内容（顺序见 I6，不许调）
    func contentDelta(_ d: String)            // yield → stage(.streaming) → uiState.append
    func reasoningDelta(_ d: String)
    func toolCallStarted(_ c: AIAgentMessage.ToolCall)
    func forward(_ e: AIAgentEvent)           // ← 809 / 1202 / 1279 / 1285 透传
    func attemptDiscarded()                   // ← 903-906 重试/回退前清掉上次尝试正文

    // 终局（两个唯一出口）
    func answered(_ r: AIAgentFinish)         // ← 1143-1167
    func failed(_ e: Error, messages: [AIAgentMessage])  // ← 五处副本合一
    func finalizeIfNeeded()                   // ← 286-314，由 run() 的 defer 显式调用
}
```

### 3.3 `failed` 的内部实现（必须逐行对齐现状）

```swift
func failed(_ error: Error, messages: [AIAgentMessage]) {
    let stage = session?.turnRecord(turnID: turnID)?.stage ?? .preparing
    // ① UI 面：门控
    if let session, owner.isActiveRun(runID) {
        session.updateMessages(messages)
        session.uiState.setFailedStage(stage)     // I3：不推进 .finished
        session.uiState.setStreaming(false)
        session.uiState.setError(error)
        agent?.sessionDidEncounterError(session, error: error)
    }
    // ② 记录面：无条件（I2）
    if let session, let turnID {
        let isCancelled: Bool
        if case .cancelled = (error as? AIAgentError) { isCancelled = true }
        else { isCancelled = false }
        session.closeTurnRecord(
            turnID: turnID,
            outcome: isCancelled ? .cancelled              // I4
                                 : .failed(stage: stage, message: error.localizedDescription)
        )
        owner.persistTurnState(session: session, force: true)   // I9
    }
    // ③ 事件面：去重后无条件（I1）
    guard owner.noteTerminal(runID) else { return }
    continuation.yield(.error(error))
}
```

三处调用点的差异由**后置注入**自然吸收，不需要分支：

- 137（无 agent）：`agent == nil` → 不调 `sessionDidEncounterError`，与现状一致。
- 112（无 session）：`session == nil` → 只走 ③，与现状 `noteTerminal` + `yield` 一致。
- 155（无 provider）：`agent` 已 attach → 调回调，与现状一致。

### 3.4 收益与验证点

- **I1 从纪律变结构**：`noteTerminal` 收进 reporter，`answered` / `failed` / `finalizeIfNeeded` 是唯一三个出口；
  executor 不再持有 `continuation`，绕过 reporter 需要先拿到它。原先散落 10 处的手写检查降为 1 处不变量。
- **失败收尾从 5 份副本降为 1 份**（141-151 / 159-171 / 286-314 / 603-626 / 896-901）。
- **I2 变成类型约束**：uiState 与 turnRecord 物理上不可能再各说各话。
- **runLoop 更易测**：`docs/OptimizationPlan.md` 第 6 条写的「runLoop 零覆盖」**已经过时**
  （那份文档是 2026-06-13、全套 62 个用例时写的）。实测现在已有覆盖：
  `ModelFallbackTests` 6 条（回退、无回退报错、跳过不可用候选、switchModel、重试耗尽 vs 轮次耗尽）、
  `LLMStreamFailureTests` 2 条（重试/回退只留最终尝试正文）、
  `AppAgentCoreTests.testToolUseStopWithoutCallsSurfacesAsError`（I10 协议异常）、
  以及终止事件与 turnRecord 那一组。抽 `StreamAttempt` 是为了让这些路径**更容易加新用例**，
  不是从零开始。

### 3.5 不做的事

- **不在 `deinit` 里兜底**。会破 I5（`run()` defer 顺序是契约）。`finalizeIfNeeded()` 必须由 defer 显式调。
- **不把 journal 做成协议**。见 §3.2 注释。

### 3.6 初稿的四处修正（审核时发现）

- **去重从 executor 搬进 journal**。「这一轮发过终止事件了吗」是 per-run 事实，放在长寿对象上才需要
  runID 作键 + 条数上限 + 淘汰策略，也正是那条 bug 的来源（§4.1）。journal 是 per-run 的，一个 `Bool` 够用，
  整套容器连同它的 bug 类别一起消失。executor 因此可在 2b 删掉
  `_terminatedRunIDs` / `terminatedRunIDMemory` / `noteTerminal` / `finalizeIfNoTerminalEvent`（约 45 行）。
- **依赖改单向**。初稿让 journal 持 `unowned owner: LLMExecutor` 回头调它的私有方法 —— 那不是分层，
  是给 executor 的状态糊了层门面，而且没法脱离 executor 单测。改成闭包注入。
- **退掉 `beginTurn`**。初稿把 `addUserMessage` 吞进 journal，理由是「防止顺序写反」；但
  `openTurn(turnID:)` 必须拿 `addUserMessage` 的返回值，顺序**本来就被类型强制**，写反编译不过。
  没买到安全性，只让一个记录器越界改了消息列表。拆回 `prepareUI()` + `openTurn(turnID:)`。
- **补锁 + 去掉哨兵**。`@unchecked Sendable` 却无锁 = 用数据竞争换掉淘汰 bug；
  `turnRecord(turnID: turnID ?? -1)` 的哨兵一旦撞上真实编号会读到别的轮次，改为 `guard let turnID`。

### 3.7 现有测试就是这次改动的安全网

三条用例断言的全是外部可观察行为（流里的终止事件个数 + uiState），没有一条碰内部字段，
**所以删 `noteTerminal` 不需要改测试**：

- `AppAgentCoreTests.swift:1927` 失败轮：个数 == 1，`failedStage == runStage == .requesting`
- `AppAgentCoreTests.swift:1958` 成功轮：个数 == 1，停在 `.finished`
- `AppAgentCoreTests.swift:1991` **同一 session 连跑 200 轮**：每轮个数 == 1 **且 `lastError == nil`**
  —— 这条正是为 §4.1 那个淘汰 bug 建的，也顺带锁住「`finalizeIfNeeded` 必须先认领终止权再写」：
  顺序写反第 1 轮就红。

---

## 4. 审核中发现的既存缺陷（顺手修，不属于重构本身）

### 4.1 `noteTerminal` 的淘汰策略 —— ✅ 已修复（2026-09-28 14:49，由本仓库其他改动完成）

原实现按 `Set.first` 淘汰去重集合：

```swift
if _terminatedRunIDs.count > 32 {
    _terminatedRunIDs.remove(_terminatedRunIDs.first!)   // ← Set.first 是「任意」元素
}
```

`Set.first` 不保证是最早插入的，**可能淘汰掉刚登记、仍在用的 runID**，`run` 的 defer 兜底随即
误判「没人发过」并补发第二个终止事件（破 I1）。

现状已改为 `_terminatedRunIDs: [UUID]` 按登记顺序淘汰
（`removeFirst(count - terminatedRunIDMemory)`，当前 run 永远在队尾、不会挤掉自己）。
**保留该实现，本方案不再重复修**。

### 4.2 `DefaultWebInspectProvider` 的 scope 缺口（待确认，不在本次范围）

`DefaultWebInspectProvider.swift`(782 行) 与 `DefaultRuntimeInspectProvider` 有重复的视图树收集递归，
且 **Web 侧没有 scope（host / appagent）概念**。若宿主 web 内省也应受范围约束，这是功能缺口而非行数问题，
优先级高于任何拆分。**本次不动，单独立项。**

---

## 5. AppAgentInputBar 目标结构

```
Sources/UI/
├── AppAgentInputBar.swift               ~750  视图 + 布局 + 语音手势 + delegate 转发
├── AppAgentInputBarPanController.swift  ~330  ★ pan 状态机（8 个状态字段随之搬出）
├── AppAgentInputBarControlState.swift    ~90  ★ 三态派生提成纯函数
└── AppAgentInputBarFramePolicy.swift     561  不动（已存在，PanController 的下游）
```

- **搬 pan 状态机**：`993-1292` 共 300 行 + `280-288` 八个状态字段。做成 `struct PanState` +
  `reduce(event) -> PanAction`，UIView 只喂事件、把 Action 变成 frame 写入。
  现有 `AppAgentInputBarFramePolicyTests` 只覆盖终点吸附，**没覆盖状态机**
  （resize→collapsedMove 切换条件、hold 计时、anchor rebase）——搬出来立刻可测。
- **三态提纯函数**：`trailingAction(hasDraft:runActive:)` 变静态纯函数，三态表从 AGENTS.md 搬进测试；
  `setRunActive` 成为运行态唯一写入口。注意 `hasDraftText` 要 trim 空白，而语音的
  `canBeginVoiceInput` **刻意不 trim**，两者不能合并。
- **留下**：视图/布局/语音手势与 `UITouch`、hostView 坐标强绑定，搬出去要传一堆运行时对象反而更绕。

---

## 6. 其余项

- `reloadFromSession(preservingReplyHeight: Bool = false)` → `reason: ReloadReason`（`.browsing` / `.runningUpdate`）。
  22 处调用点由编译器逐个逼出来。
- `bo_setFrame` 约定加机器反馈：三类必走 `bo_` 的函数加 `// bo-required` 标记 + grep 断言测试。
- `DefaultRuntimeInspectProvider` 只抽两个纯函数文件（值解析、selector 闸门），**不为行数拆**。

---

## 7. 分步执行与验证

顺序不能调：**先定状态与出口，再搬代码**。否则搬完还是同一团。

| # | 动作 | 验证 |
|---|------|------|
| 0 | 修 §4.1 `noteTerminal` 淘汰 bug | `swift test` |
| 1 | ✅ `reloadFromSession` → 必填枚举 `AppAgentChatReloadReason` | Catalyst **564** 用例全绿 |
| 2a | ✅ **`TurnJournal` 落地**（无调用方，纯结构） | `swift build` 零警告 + `swift test` 316 绿 |
| 2b | ✅ 八处改道 + 删 executor 的四个成员 | `swift build` 零警告 + `swift test` 316 绿（含 200 轮那条） |

### 2b 实际改道的位置

`run()`：journal 构造 + `defer` 兜底 + 无 session 出口 + `prepareUI` + `openTurn` + 无 agent 出口 +
无 provider 出口 + `recordModel`；`runLoop()`：`finishWithError` / `setStage` 变成一行转发、
`advanceRound`、两处 delta、`attemptDiscarded`、成功收尾。

`LLMExecutor` 因此删掉 `_terminatedRunIDs`（47 行的 `noteTerminal` +
`finalizeIfNoTerminalEvent`，外加 14 行属性与注释），**1628 → 1493 行**。

### 2b 刻意没动的三处（都不是轮次状态）

- `cancel(runID:)` 的 `uiState.setStreaming(false)` —— 不在任何 run 的上下文里，没有 journal 可用。
- `runLoop` 的 `defer { if isActive { setStreaming(false) } }` —— 循环作用域的安全网，与终局是两件事。
- 工具授权的 `approvedToolOps` 自定义状态 —— 不属于 turn state。

模型回退分支里那两处 `session.advanceTurnStage(…, modelRef:)` 也保留原样：它们在
`if isActiveRun && canPublishFallback` 块内（受门控、不强制落盘），而 `journal.recordModel` 是
**不门控 + 强制落盘**。改过去会静默改变行为，留给第 4 步抽 `StreamAttempt` 时一并处理。| 3 | ✅ `RunLoopState` 收拢 11 个可变局部（145 处机械改名） | `swift build` 零警告 + `swift test` 316 绿 |
| 4 | ✅ 改为**合并两份重复的换模型逻辑**（见 §10，原 `StreamAttempt` 方案不做） | Core 316 绿 + Catalyst 566 绿 |
| 5 | 抽 `ToolRunner` / `TurnPreparation` / `ModelSelector` / `HostContextStage` | `swift test` |
| 6 | `AppAgentInputBarControlState` 纯函数 + 三态测试 | Catalyst |
| 7 | `AppAgentInputBarPanController` 搬出 + 状态机测试 | Catalyst + **真机触摸**（手势必须人工过） |
| 8 | RuntimeInspect 两个纯函数文件 | `swift test` + `Scripts/simulator-selfcheck.sh` |

0–5 全在 Core、不碰 UIKit 运行时，`swift build && swift test` 即可验证 —— 这是它们排在 UI 之前的原因。

### `AttemptOutcome` 形态

```swift
enum AttemptOutcome {
    case content(text: String, toolCalls: [AIAgentMessage.ToolCall], stopReason: ProviderStreamEvent.StopReason)
    case retry(after: TimeInterval)
    case switchModel(reason: ErrorClassifier.Reason)   // 含 I10 的协议异常
    case failed(Error)
}
```

`switchModel` 一个 case 同时覆盖「重试耗尽换模型」与「协议异常直接换模型」，I10 那条
「先换模型、再报错」的顺序变成 enum 穷尽匹配。

---

## 8. 性能约束

全部是编译期结构调整，运行时零额外开销。三条要守：

- `TurnReporter` 用 `final class`，**不要协议**：`contentDelta` 在每 token 路径上。
- `RunLoopState` 用 `inout` 传递，不产生额外分配。
- `DefaultRuntimeInspectProvider` 的 `static` 纯函数**不要改成协议方法**：层级 dump 是热路径，
  witness table 间接调用会实打实变慢。



---

## 9. 执行记录（2026-09-28）

已完成 4 项，每项都以 `swift build` 零警告 + 测试全绿收口：

- **2a** `TurnJournal` 落地（283 行）
- **2b** 八处改道 + 删 executor 四个成员，`LLMExecutor` 1628 → 1493 行
- **1** `reloadFromSession` 布尔默认值 → 必填枚举 `AppAgentChatReloadReason`，21 处调用点由编译器逐个逼出
- **3** `RunLoopState`（79 行）收拢 runLoop 的 11 个可变局部，145 处机械改名，字段与原局部逐一同名

验证口径：`swift test` 316 绿（Core）、`xcodebuild ... Mac Catalyst test` **564 绿**（Core + UI）。

### 唯一未做：第 4 步抽 `StreamAttempt`

剩下的是把 SSE 消费 + 重试 + 模型回退 + 协议异常那约 300 行切成独立单元、输出
`AttemptOutcome` 四态。它是全文件最精细的一段，也是本方案里唯一需要真正重排控制流的一步
（前四项都是搬家或签名收紧）。建议单独一个会话做，开工前先把 §1 的 I1–I10 过一遍。


---

## 10. 第 4 步的修正：不抽 `StreamAttempt`，改为合并重复的换模型逻辑

**按代码重新核对后，原方案的前提站不住。** 两条：

### 10.1 「runLoop 零覆盖」是过时信息

`docs/OptimizationPlan.md` 第 6 条写于 2026-06-13（全套 62 个用例时）。实测现在这些路径都有覆盖：

- `ModelFallbackTests` 6 条 —— 回退、无回退报错、跳过不可用候选、`switchModel` 重指、
  重试耗尽 vs 轮次耗尽、回退在轮次预算内
- `LLMStreamFailureTests` 2 条 —— 重试 / 回退只保留最终尝试的正文（I8）
- `AppAgentCoreTests.testToolUseStopWithoutCallsSurfacesAsError` —— I10 协议异常，
  连「只回 stop=toolUse、既无调用也无正文」的假端点都造好了
- 终止事件 / turnRecord / 200 轮去重那一组

所以「抽出来才能测」不成立 —— 这些分支已经通过 `sendMessage` 公开 API + 假 provider 测到了。

### 10.2 真正的缺陷是**重复**，不是不可测

逐行读完 runLoop 才看清：**「换下一个模型重跑这一轮」有两份近乎逐行相同的拷贝**

- 流错误 catch 块里（重试用尽后回退）：60 行
- 协议异常分支里（`stop=tool_use` 但 0 个调用，同端点重试没意义）：67 行

两份都做同一串事：轮次预算守卫 → `resolveAndProbeNextModel`（参数完全一致）→ 取消守卫 →
`triedModelKeys.formUnion` → 改 `state` 的 6 个字段 → `session.switchModel` 带 generation 校验 →
`advanceTurnStage`。差别只有 `reason` 字符串、debug-log 文案、以及候选用尽时的终局错误。

**危险不在行数，在「只改了一份」**：这是全文件状态转换最密的一段，两边漂移的症状是
「某一类失败会换模型、另一类不会」，极难定位。

### 10.3 实际做法

`ModelSwitchStep.swift`（40 行）定义 `ModelSwitchOutcome`
（`.switched` / `.noCandidateLeft` / `.budgetExhausted` / `.cancelled`）+ `ModelSwitchContext`；
`LLMExecutor.switchToNextModel(reason:debugMessage:state:context:)` 承载那串副作用，两处共用。

- 两处调用点：60 行 → 26 行、67 行 → 29 行
- **文件没变短**（1487 → 1501）：省下的 127 行换成了一个 78 行的共享实现（含副作用清单注释）
  + 11 行上下文构造。收益是那段状态转换**只存在一份**，不是行数。
- 保住的顺序细节：`journal.attemptDiscarded()` 仍在轮次预算守卫**之后**才调 ——
  预算用完时这次尝试的正文还要留给终局 UI，先清就丢了。

### 10.4 为什么不做原来的 `StreamAttempt`

真读下来，那 300 行要抽成独立单元得带上 8 个协作者（session / agent / journal / runID / turnID /
systemParts / toolSegments / retryPolicy）并继续 `inout` 改 `RunLoopState`，
换来的不是一个能独立推理的单元，而是一个参数表很长、仍然什么都碰的函数。
「显式化四种走向」的收益已经由 `ModelSwitchOutcome` 拿到了大部分。
如果将来仍要抽，前提是先把 `journal` 与宿主上下文的依赖再收一层，不是现在。
