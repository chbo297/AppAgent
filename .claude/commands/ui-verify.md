---
description: Verification checklist for the AppAgent overlay UI rewrite
---

为正在进行的 UI 重写（`AppAgentOverlay` / `AppAgentWindow` / `AppAgentViewController` / `AppAgentInputBar`）提供验证清单。

## 静态代码核查（自动）

读取并核对以下要点。每项给出"✅ 符合 / ⚠️ 风险 / ❌ 不符合 + 文件:line"。

### 1. `Sources/UI/AppAgentWindow.swift` — 透传式 hitTest
- `hitTest(_:with:)` 在命中"空白区域"时返回 `nil` 而非自身，让事件下穿到 host window。
- `windowLevel` 设为 `.normal + 1` 之类（覆盖 host 但不抢 alert/keyboard）。
- 不重写 `becomeKey` 抢夺主键盘焦点，除非显式需要。

### 2. `Sources/UI/AppAgentOverlay.swift` — 集成入口
- `attach(in:)` 与 `start(in:agent:)` 都通过传入的 `UIWindowScene` 创建 window，**不**用 deprecated 的 `UIApplication.shared.keyWindow`。
- `start(in:agent:)` 内部应：① 创建/获取 `AISession` ② 绑定到 view controller ③ 设置 `uiState.onChange`。
- overlay 强引用 window + view controller（避免 window release 引起界面消失）。

### 3. `Sources/UI/AppAgentInputBar.swift` — 手势状态机
- `UIPanGestureRecognizer` 在 `.cancelled` / `.failed` 状态有复位路径（恢复到 .began 之前的 frame）。
- 横向 vs 竖向手势的 axis-locking 在 `.began` 阶段完成判定，避免抖动。
- 键盘出现/消失通知用 `keyboardWillShow/Hide` + `UIResponder.keyboardFrameEndUserInfoKey`，不用 `keyboardDidShow`（会闪烁）。
- delegate 回调（send/menu/voice/plus）都是 `weak` 引用避免循环。

### 4. `Sources/UI/AppAgentViewController.swift` — 流式渲染
- `session.uiState.onChange` 闭包内派发到 main queue（如果不是已经在 main 上调用）。
- TableView 滚动到底跟随流式输出，但用户主动上滑时**不**强制滚回（检查是否实现）。

### 5. `Examples/iOS/Sources/SceneDelegate.swift` — host window 顺序
- 创建 host window（`HostTabBarController`）并 `makeKeyAndVisible()` **先于** `AppAgentOverlay.start()`，否则 overlay 会成为 key window 抢走交互。

## 模拟器手测清单（5 条 golden path）

`/build-demo` 通过后，用户在模拟器逐项验证：

1. **启动**：app 起来，HostTabBar 三个标签可点，overlay 输入条出现在底部。
2. **胶囊收起/展开**：横向 pan input bar，胶囊从全宽收缩为右侧小圆，松手回弹；再次点击展开。
3. **键盘联动**：点输入框，键盘弹起，输入条平滑跟到键盘上沿；收起键盘平滑回落。
4. **流式发送**：输入消息发送，消息气泡出现，AI 回复流式逐字渲染，TableView 自动滚到底。
5. **透传交互**：在没有展开输入条的空白区域点击 HostTabBar 的标签 —— 应能切换 tab，证明 hitTest 正确透传。

## 输出格式

```
=== 静态核查 ===
1. AppAgentWindow.hitTest: ✅
2. AppAgentOverlay 集成入口: ⚠️ 见 Sources/UI/AppAgentOverlay.swift:42 …
...

=== 手测建议 ===
请在模拟器跑通上述 5 条 golden path
```

如果发现高风险问题，建议用户调用 `overlay-ui-reviewer` agent 做深度审查。
