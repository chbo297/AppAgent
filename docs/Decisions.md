# 等用户拍板（授权 / 澄清 / 方案选择）

> **什么时候读这份**：改 `AISession.requestDecision`、`DecisionResponder`、决策卡片，或排查「卡片一直等 / continuation 泄漏」时。


需要用户拍板的事只有一个入口：`AISession.requestDecision(_:)`。工具和 `LLMExecutor` 都不关心谁来回答。

- **责任链**：① 宿主策略 `AIAgentDelegate.policyFor(request:)`（**非交互**，返回 `nil` = 无意见；企业要「内网一律禁止，别问用户」在这里拦）→ ② 已注册的 `DecisionResponder`（正常就是 AppAgent 自己的对话面板）→ ③ 兜底：授权类 `.deny`，澄清类 `.answer(nil)`。**没人能回答不等于放行。**
- **卡片是 AppAgent 自己的**：进程里只有一份 `AppAgentDecisionPresenter.shared`，第一个 `AppAgentViewController` 在 `viewDidLoad` 里 `attach` 时把它注册进 `DecisionResponderCentral.default`。卡片渲染在**对话面板内部**（`AppAgentChatPanelView.decisionCard`，贴消息列表底部），不新建 window、不遮宿主界面、不影响别的 session。宿主 app 零代码。
- **阻塞态是个栈不是单槽**：`requestDecision` 期间 `uiState.setPendingDecision` 入栈、答复后按同一个 request 出栈（`pendingDecision` 给**队首那个**——和面板上正在展示的那张卡一致；`pendingDecisionCount` 给个数）。单槽的话两个并发请求里先答完的会把「还有人在等」直接清掉，宿主据此判断就错了。显式传了 request 却没命中时 `clearPendingDecision` 什么都不做，宁可漏摘也不摘掉别人还在等的那条。UI 通过 `onChange("pendingDecision")` 观察。await 发生在 executor 的 Task 里，不占主线程——用户可以切到别的 session 聊天，切回来卡片还在等。
- **卡片一张、请求按会话排队**：`DecisionResponder.respond` 拿得到发起请求的 session，`AppAgentDecisionPresenter` 把 sessionId + requestId 一并交给呈现闭包；VC 存进 `pendingDecisions[sessionId]`（**数组**，同会话并发的第二个请求排在后面而不是覆盖——覆盖会把它的 continuation 永久挂住）。同一 agent 的后台会话也要收下并返回 true，`switchSession` 时先 `dismissDecision()` 再显示新会话队首；**其它 agent 的请求返回 false**，交给责任链中所属面板，不能排进当前面板永远切不到的队列。agent 换绑时 VC 清掉自己的队列并 `releaseDecisions(of:)`，请求回到 presenter 继续等。回归见 `AppAgentViewControllerLifecycleTests`。
- **等待是可取消的**：`respond` 外面套 `withTaskCancellationHandler`。用户按停止（或宿主代码调用 `session.cancel()`）之后，等在卡片上的 Task 会被取消——这时必须立刻恢复 continuation（返回 `nil` = 交回责任链兜底，**不是**替用户点「允许」）并通过 `dismiss(requestId:)` 把卡片撤掉、换上队列里的下一张。少了这一层，卡片会一直挂着等一个已经死掉的回合，executor 的 Task 也永远回不来。`Tests/UI/AppAgentUITests.swift` 有用例锁住「取消后不挂死且撤卡片」。
- **用户不选就一直等，不倒计时、不替用户做决定**：等待挂在 presenter 的 `entries` 上，不挂在面板上。面板（`attach` 进来的 surface，弱引用）只负责展示。
  - 面板被释放：surface 和 entry 的 `owner` 都是弱引用，自动回到「没人展示」；请求不结束，会话保持「等用户选择」挂起。下一个面板 `attach`（或换绑回原 agent）时 `offerUnowned()` 把它重新交出去，VC 切到那个会话就贴出卡片。
  - 结束只有三条路：用户作答；run 被取消（用户按停止）→ 恢复为 `nil` 并撤卡；进程里**从来没有**面板 attach 过（纯 headless）→ `respond` 直接返回 `nil` 走兜底。
  - 取消可能落在「检查完没取消」与「贴出卡片」之间：`offer` 之后再查一次 `isSettled`，是就立刻 `dismiss`（否则留一张点了没用的僵尸卡）。
  - 结清给的是 `nil`（=「我答不了」），责任链继续问下一个 responder，最后落到 `AISession` 的兜底；兜底语义只有 Core 一份，UI 层不再复制。`settlePendingDecisions()` 只给测试和整体拆除用。
  - **面板离开不停这一轮**：切会话、换绑 agent、面板释放都只调 `detachStreamConsumer()`，不取消流消费者 Task。取消会顺着 `LLMExecutor` 输出流的 `onTermination` 把这一轮停掉，卡片也跟着被结清。旧消费者只弱引用面板，靠 `streamConsumerToken` 在下一个事件上自己退出。停止只走 `stopCurrentRun()` → `session.cancel()`。`DecisionResponderCentral` 存弱引用、不需要手动注销；agent 换绑另主动解除旧会话的 `onChange`，避免迟到通知刷新新界面。
- **请求形态**：`DecisionRequest` = `.privateNetworkAccess` / `.toolAuthorization` / `.appAgentInspection` / `.permission` / `.clarification`，`title` / `message` / `options` 由它自己给出，卡片不 switch 业务。`clarify` 工具也走这条路，不再需要宿主实现回调。
- **权限卡（`.permission`）**：宿主经 `AIAgentProfile.toolPermissionPolicy` 登记权限类别（如「修改 App 运行时」）和「哪次调用需要哪项权限」。`LLMExecutor` 在宿主门禁之后、安全级别卡之前检查：已授权直接放行，否则弹卡，选项为「允许单次 / 在本会话中允许 / 始终允许 / 拒绝」。本会话授权记在 `AISession.permissionGrants` 并随快照落盘；始终允许记在设备级 `AppAgentPermissionStore`（UserDefaults）。权限卡覆盖了这次调用后不再弹安全级别卡。委派任务沿父链继承本会话授权，但不能自己申请新权限。对话页顶部栏的齿轮（`AppAgentSessionPermissionsViewController`）列出当前会话的权限并可修改或撤销。回归见 `Tests/Core/ToolPermissionTests.swift`。
- **卡片交互：先选中、再提交**。点选项只是选中（单选圈），底部「确定 / 提交」才生效，防误触。选项文字默认最多两行，超出时右侧出现展开/收起箭头。两种形态由 `DecisionRequest` 自己说明：授权类（`isSkippable == false`）只能在有效选项里选，一直等；提问类（`.clarification`）最后一项固定是「其他（自己输入）」（`DecisionOption.customAnswerID`），没有 choices 时只剩这一项（开放式提问），可「跳过」。
- **提问卡不倒计时**：卡片没有倒计时，也不会到时自动跳过，用户点「跳过」才返回 `.answer(nil)`。`ClarifyTool.waitsForUser == true`，`LLMExecutor` 不给它套通用 `toolTimeout`（否则等久了被掐成超时错误）。回归见 `Tests/Core/ClarifyWaitTests.swift`。
- **Sendable 边界**：`DecisionResponder` 要求 Sendable，UIViewController 不是，所以用 `AppAgentDecisionPresenter`（`@unchecked Sendable` 薄壳 + 弱引用 + 内部跳 MainActor）把 async 语义接到 UIKit 点击上，`withCheckedContinuation` 只允许恢复一次。
- **自检必须换掉 responder**：真机上卡片会一直等真人点按钮，无人值守时整轮自检会挂死。`CapabilitySelfCheck.run` 开头把 `session.decisionResponders` 换成自动应答的假 responder（`SelfCheckDecisionResponder`），这条约定别破。
- **卡片布局两个坑**（都实测踩过）：① 别拿 `layout.messageListFrame` 定位——消息列表按完整 contentArea 布局、由 viewport 裁切，它的底边在可见区外面，卡片会被裁掉完全看不见；应贴 `viewportView.bounds` 底边。② viewport 会延伸到 inputBar 底下，所以还要减 `decisionCardBottomInset`（由 `applyChatPanelContainerLayout` 用 inputBar 几何写入），否则最下面的按钮被输入栏压住点不到。
- **人工验观感**：demo 支持 `xcrun simctl launch <udid> com.appagent.demo -show-decision-card`（仅 DEBUG）——展开面板、真的发一次私网授权请求走完整责任链，30s 后自动点「拒绝」，配 `simctl io ... screenshot` 看实际效果。
  - 验对话列表分层与 markdown 用 `-show-sample-conversation`：往当前会话灌一段样例对话（一轮里两次失败的工具往返 + markdown 答案），展开面板并抑制「未配置 API Key」弹窗，不需要真的连模型。
