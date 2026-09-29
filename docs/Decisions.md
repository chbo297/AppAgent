# 等用户拍板（授权 / 澄清 / 方案选择）

> **什么时候读这份**：改 `AISession.requestDecision`、`DecisionResponder`、决策卡片，或排查「卡片一直等 / continuation 泄漏」时。


需要用户拍板的事只有一个入口：`AISession.requestDecision(_:)`。工具和 `LLMExecutor` 都不关心谁来回答。

- **责任链**：① 宿主策略 `AIAgentDelegate.policyFor(request:)`（**非交互**，返回 `nil` = 无意见；企业要「内网一律禁止，别问用户」在这里拦）→ ② 已注册的 `DecisionResponder`（正常就是 AppAgent 自己的对话面板）→ ③ 兜底：授权类 `.deny`，澄清类 `.answer(nil)`。**没人能回答不等于放行。**
- **卡片是 AppAgent 自己的**：`AppAgentViewController` 在 `viewDidLoad` 里造一个 `AppAgentDecisionPresenter` 注册进 `DecisionResponderCentral.default`，卡片渲染在**对话面板内部**（`AppAgentChatPanelView.decisionCard`，贴消息列表底部），不新建 window、不遮宿主界面、不影响别的 session。宿主 app 零代码。
- **阻塞态是个栈不是单槽**：`requestDecision` 期间 `uiState.setPendingDecision` 入栈、答复后按同一个 request 出栈（`pendingDecision` 给**队首那个**——和面板上正在展示的那张卡一致；`pendingDecisionCount` 给个数）。单槽的话两个并发请求里先答完的会把「还有人在等」直接清掉，宿主据此判断就错了。显式传了 request 却没命中时 `clearPendingDecision` 什么都不做，宁可漏摘也不摘掉别人还在等的那条。UI 通过 `onChange("pendingDecision")` 观察。await 发生在 executor 的 Task 里，不占主线程——用户可以切到别的 session 聊天，切回来卡片还在等。
- **卡片一张、请求按会话排队**：`DecisionResponder.respond` 拿得到发起请求的 session，`AppAgentDecisionPresenter` 把 sessionId + requestId 一并交给呈现闭包；VC 存进 `pendingDecisions[sessionId]`（**数组**，同会话并发的第二个请求排在后面而不是覆盖——覆盖会把它的 continuation 永久挂住）。不属于当前会话的请求**也要收下并返回 true**（返回 false 会让责任链兜底拒绝，等于替用户做了决定），`switchSession` 时先 `dismissDecision()` 再把新会话队首那张贴出来。
- **等待是可取消的**：`respond` 外面套 `withTaskCancellationHandler`。用户按停止 / 切走 run 之后，等在卡片上的 Task 会被取消——这时必须立刻恢复 continuation（返回 `nil` = 交回责任链兜底，**不是**替用户点「允许」）并通过 `dismiss(requestId:)` 把卡片撤掉、换上队列里的下一张。少了这一层，卡片会一直挂着等一个已经死掉的回合，executor 的 Task 也永远回不来。`Tests/UI/AppAgentUITests.swift` 有用例锁住「取消后不挂死且撤卡片」。
- **continuation 一个都不许漏**：三条出口都要堵住——① 取消可能落在「检查完没取消」与「贴出卡片」之间，`present` 返回 true 后要再查一次 `isSettled`，是就立刻 `dismiss`（否则留一张点了没用的僵尸卡）；② 呈现失败 `settle(nil)` 走责任链兜底；③ **面板销毁时 `AppAgentViewController.deinit` 调 `presenter.settlePendingDecisions()`**，不然那些 `CheckedContinuation` 带着未恢复状态析构（运行时报 "leaked its continuation"），发起它们的那一轮永远回不来。
  - 分工：continuation 只活在 `AppAgentDecisionPresenter.inFlight` 表里，面板拿到的只是 `complete` 闭包。所以**结清的实现在 presenter**（它持有 continuation），**触发的时机由面板给**（只有它知道自己没了）。
  - **不能指望 presenter 自己的 `deinit`**：`AISession.requestDecision` 在 `for responder in responders` 里 await，`responders` 是强引用数组，等待期间 presenter 一直被那个挂起的 executor 帧持着，正在等的时候它不可能析构。
  - `settlePendingDecisions()` 是 `nonisolated` 且只碰自己的锁，所以能从非隔离的 `deinit` 直接调，不需要 `MainActor.assumeIsolated`；VC 里 `decisionPresenter` 因此标了 `nonisolated(unsafe)`（只在 `viewDidLoad` 写、`deinit` 读，都在主线程）。
  - 结清给的是 `nil`（=「我答不了」），责任链继续问下一个 responder，最后落到 `AISession` 的兜底；兜底语义只有 Core 一份，UI 层不再复制。
  - VC 的 `deinit` 其余部分只留 `NotificationCenter.removeObserver`：`DecisionResponderCentral` 存弱引用、不需要手动注销；`uiState.onChange` 闭包本身 `[weak self]`，不清也不会野。
- **请求形态**：`DecisionRequest` = `.privateNetworkAccess` / `.toolAuthorization` / `.appAgentInspection` / `.clarification`，`title` / `message` / `options` 由它自己给出，卡片不 switch 业务。`clarify` 工具也走这条路，不再需要宿主实现回调。
- **Sendable 边界**：`DecisionResponder` 要求 Sendable，UIViewController 不是，所以用 `AppAgentDecisionPresenter`（`@unchecked Sendable` 薄壳 + 弱引用 + 内部跳 MainActor）把 async 语义接到 UIKit 点击上，`withCheckedContinuation` 只允许恢复一次。
- **自检必须换掉 responder**：真机上卡片会一直等真人点按钮，无人值守时整轮自检会挂死。`CapabilitySelfCheck.run` 开头把 `session.decisionResponders` 换成自动应答的假 responder（`SelfCheckDecisionResponder`），这条约定别破。
- **卡片布局两个坑**（都实测踩过）：① 别拿 `layout.messageListFrame` 定位——消息列表按完整 contentArea 布局、由 viewport 裁切，它的底边在可见区外面，卡片会被裁掉完全看不见；应贴 `viewportView.bounds` 底边。② viewport 会延伸到 inputBar 底下，所以还要减 `decisionCardBottomInset`（由 `applyChatPanelContainerLayout` 用 inputBar 几何写入），否则最下面的按钮被输入栏压住点不到。
- **人工验观感**：demo 支持 `xcrun simctl launch <udid> com.appagent.demo -show-decision-card`（仅 DEBUG）——展开面板、真的发一次私网授权请求走完整责任链，30s 后自动点「拒绝」，配 `simctl io ... screenshot` 看实际效果。
  - 验对话列表分层与 markdown 用 `-show-sample-conversation`：往当前会话灌一段样例对话（一轮里两次失败的工具往返 + markdown 答案），展开面板并抑制「未配置 API Key」弹窗，不需要真的连模型。
