# 真机排查：落盘日志 / 诊断包 / 模拟器自检

> **什么时候读这份**：真机上排查问题、改日志与诊断导出、加工具后补自检项时。


真机上 `print` 看不到，所以 `Logger` 的输出另有一条落盘通道：

- `AppAgentRunLog.shared.install()` 打开 `Logger` 并把格式化后的每一行追加到 `Documents/AppAgent/logs/appagent-<时间>.log`，按 2MB 滚动、只留最近 3 个文件。**`AppAgentOverlay` 初始化时自动调用**，宿主零代码；install 幂等，且**不吞掉已有 handler**（宿主原来接了自己的日志系统照旧生效）。
- 导出在调试面板（会话侧栏的「调试」入口）：面板顶部有显眼的「导出全部数据」按钮，导航栏分享菜单里也有同一项。走 `AppAgentDiagnostics.export`，打出一个 zip：`summary.txt`（环境 + 各项计数 + 包内清单）、`debug-log.txt/.json`（模型调用记录）、`run-logs/`、`sessions/`（会话快照，含每轮工具往返）、`memory/`。
- zip 不引三方库：`NSFileCoordinator` 的 `.forUploading` 读意图会给出目录的临时 zip 副本，拷出来即可。**这一步阻塞**，所以 `export` 在后台队列跑、回调切主线程，UI 期间显示「正在打包…」。
- 导出前必须 `runLog.flush()`：写入是异步排队的，不 flush 最后几行还在队列里——恰恰是卡住之前那几行。
- **响应侧的原始 SSE 也落日志**（`AnthropicProvider` 里每条 `sse<<` 一行，截断 800 字）。以前只记请求体，于是「模型说 stop=tool_calls、我们却解析出 0 个调用」这类问题在诊断包里查不到根因，只能靠猜端点格式。
- **OpenAI 兼容端点的三个坑**（都是排查的产物）：① 有的端点在流式分片里用 `message` 而不是 `delta`，`OpenAIChoice.delta` 必须是 Optional 并 `delta ?? message` 兜住——非 Optional 时这类分片整块解码失败被静默丢掉，工具调用就这么没了；② 老式 `function_call` 也要收，并到 0 号槽走同一套收尾。`finish_reason=tool_calls` 却 flush 出 0 个调用时会打 warning 并带上原始 chunk；③ **续传分片里 `id` / `name` 是空字符串而不是缺键**（GLM 系 OneAPI 端点实测如此：首片给全名，后续每片都带 `"id":"","name":""`）。`if let` 挡不住空串，覆盖上去就把首片的工具名擦掉，`flushToolCalls` 再按「名字为空」整条丢掉 —— 现象正是 ② 那句 warning + 界面 loading 转一圈没结果。所以 `OpenAIChatCompletionsMapper` 合并分片一律走 `nonEmpty(_:)`：**空值只补不覆盖**；`OpenAIResponsesMapper` 的 `call_id` / `id` 同理。`Tests/Core/AppAgentCoreTests.swift` 用真实分片序列锁住这条。
- **「切后台回来就不动了」在日志里长这样**：`sse<<` 在某个时刻整片断掉，随后出现 `streamStalled: iteration=N, idle=…s` 与一条 reason=`transport`、文案「模型响应中断：Ns 没有新内容，按可重试错误处理」的 debug-log failure，紧跟着 `retry`。看到这组就是连接在挂起期间被撕掉、由空闲看门狗判死后重试，机制见 `docs/TurnLifecycle.md` → 打断与恢复。**只有 `sse<<` 断掉、没有 `streamStalled`** 才是真的卡住 —— 那说明这条流没被 `StreamIdleGuard` 包上。
- `Tests/Core/AppAgentDebugLogTests.swift` 锁住两点：`Logger` 的行确实进了文件；诊断包是真 zip（`PK` 魔数）且概要计数正确。

## 模拟器能力自检（工具回归的主力手段）

`Examples/iOS/Sources/CapabilitySelfCheck.swift` 在真机/模拟器运行时里**直连每个工具的 `execute`**（不经过 LLM），逐项判定通过与否。单元测试拿不到 UIKit 运行时，这里能，所以验证工具改动优先走它。

```bash
Scripts/simulator-selfcheck.sh                 # 自动挑一个已启动的 iPhone 模拟器
Scripts/simulator-selfcheck.sh <device-udid>
SKIP_BUILD=1 Scripts/simulator-selfcheck.sh    # 复用上次构建
```

- 脚本每一步都套了 `gtimeout`（需 `brew install coreutils`）：卡住会直接失败并打印最近日志，不会挂住终端。app 内部每个检查项另有 8s 预算，超时记为失败后继续跑完剩余项。
- 产物：`Documents/AppAgent/diagnostics/selfcheck-report.txt`（含授权 SDK 预览，逐项 ✓/✗ + `total=/ok=/fail=` 汇总，脚本拷到 `/tmp/selfcheck-report.txt`）、`Documents/selfcheck-ui-hierarchy.txt`（未截断的宿主 `ui_hierarchy` + `view_tree`）。授权 SDK/all 的层级另存 `Documents/AppAgent/diagnostics/selfcheck-sdk-hierarchy.txt`，不混入宿主产物。脚本以 `fail=0` 决定退出码。
- 自检在 overlay 挂载**之后**才跑；默认 host 摘要和 full 都必须排除 SDK 窗口，显式授权 `appagent/all` 才包含 SDK。`-run-selfcheck` 同时抑制「尚未配置 API Key」弹窗，避免污染 dump。
- 首页「能力自检」按钮在 app 内弹出同一份报告。
- 加新工具时**一并在 `CapabilitySelfCheck` 加一条检查**，用三种期望之一：`.ok`（必须成功）、`.errorContains(...)`（必须以某个错误拒绝）、`.completes`（只要求不挂死，用于依赖真实模型或宿主 UI 的项）。
- **自检必须跑完不留痕**：变更类内省（`view_set` / `view_invoke` / JS `uiSet`）只打在 `installScratchView()` 挂上去的一次性隐藏视图上，绝不改真实 UIKit 视图；改了全局观感的（深浅色、当前 tab）要复位；剪贴板只清掉自己写的内容。报告里有「临时视图已移除 / 深浅色已复位 / tab 已复位 / 剪贴板已清理」几条守着这个约定。
- **别在 `withBudget` 之外写可能阻塞的调用**。踩过：直接 `UIPasteboard.general.string` 读别的来源写入的剪贴板会触发系统粘贴授权，无人确认时整轮自检卡死（脚本 60s 超时才发现）。所以不去「读旧值再还原」剪贴板，且所有清理动作也一律包在 `withBudget` 里。
