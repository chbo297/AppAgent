# Workspace（会话工作区）

工作区是 AppAgent 自带的一张可复用页面：模型写 H5 文件，AppAgent 负责展示；需要时宿主在 H5 下面垫一块自己的原生视图（插槽视图），
比如地图 App 放一张可拖动的子图区。数据属于会话，一个会话一份；全局只有一个容器、一个页面，每个插槽名一个视图，切会话换数据。

## 数据

`AISession.workspace: SessionWorkspace`（`Core/Session/SessionWorkspace.swift`），随会话落盘、归档、恢复：

- `isShown` / `title`：整体显隐和标题。
- `h5`：`isShown`、`files`（相对路径 → 文本，入口 `index.html`）、`state`（String → String）。
- `slots`：插槽名 → `isShown`、`state`（String → String，内容由宿主插槽视图自己编码）。插槽铺满 H5 下方，同一时间最多显示一个。
- 上限见 `SessionWorkspaceLimits`；`AISession.updateWorkspace(_:)` 先整体校验，任一项超限整次拒绝，成功才落盘并发
  `AISession.workspaceDidChangeNotification`。

对话面板档位 `AISession.chatPanel`（collapsed / half / full）同样属于会话；输入栏是小球还是展开是全局状态，不属于会话。

## 谁负责什么

- **AppAgent（`Sources/UI/Workspace/`）**：容器、页面 VC、H5 加载与安全边界、触摸分配、显隐时机
  （切会话、面板显隐、退后台、内存告警）、对话面板顶栏的工作区开关、给模型的 `workspace` 工具。
- **宿主**：实现 `AppAgentWorkspaceHost`，只回答这几件事：功能开没开、容器挂在自己界面哪一层、
  有哪些插槽（`workspaceSlots`，名字 + 一句说明）及按名创建插槽视图（`AppAgentWorkspaceSlotView`，每个名字全局一个）、
  页面按钮能调哪些宿主动作。操作插槽内容的工具由宿主自己注册，经 `AppAgentWorkspace.shared.slotView(named:forSession:)`
  拿到前台视图，经 `updateSlotState(_:slot:sessionId:)` / `slotState(slot:sessionId:)` 读写该会话的插槽状态（后台也能写）。

这和 `AppAgentUIDelegate` 是两套通道：`AppAgentUIDelegate` 说的是 AppAgent 整体挡住了宿主什么、宿主要它让出什么；
这里说的是工作区页面和宿主插槽视图之间的事。

## 接入

```swift
AppAgentWorkspace.shared.install(host: myHost, chatViewController: overlay.viewController)
await ToolCentral.default.register(AppAgentWorkspaceTool(slots: myHost.workspaceSlots, hostGuide: "..."))
```

- `install` 可重复调用：宿主开关变化后再调一次，开启时挂上容器并按当前会话数据恢复，关闭时收起并回收（会话数据不删）。
- 会话切换、面板状态、面板隐藏由 `AppAgentViewController` 直接送到 `AppAgentWorkspace`，宿主不转发。
- `slots` 为空时工具只有 H5 层。

## 工具 `workspace`

只改执行它的会话自己的数据，后台会话也能改；界面只跟随当前会话，后台改动在切到该会话时才显示。

- `read`（可带 `path` 读全文）/ `write`（`files`、`title`、`replace_all`）/ `edit`（`path`、`old`、`new`，old 必须恰好出现一次）
  / `delete`（`paths`）/ `set_state`（`state: {key: string|null}`）/ `clear`。
- `show` / `hide` 配 `target`：不传是整个工作区（各层设置保留）；`h5` 是 H5 层；插槽名是该插槽，显示一个插槽会隐藏其他插槽。
  H5 层隐藏且没有显示中的插槽时视为没有内容：页面不挂出来，顶栏也不出开关。
- 返回概览和 `live`（触摸模式、加载失败、页面脚本错误），模型据此修页面。

## 页面 JS

文档开始时注入：

- `window.appAgent.workspace`：`state`、`setState(key, value|null)`、`setTouchRegions(regions)`、`useAutoTouchRegions()`；
  事件 `appagent:layout`（布局变化）、`appagent:state`（模型改了 state）。
- `window.hostApp.invoke(action, args)`：调用宿主登记的页面动作，同一时间一个，宿主 60 秒不返回按超时失败。
  「只认用户点击」以原生为准：WebView 收到触摸后 5 秒内放行一次（`AppAgentWorkspaceTapGate`）；
  页面脚本能绕过注入脚本里的 `navigator.userActivation`，iOS 16.4 以下也没有这个 API，所以 JS 那层只是提前拦截。
- 页面不在前台时调 invoke 直接返回失败，不会一直占着。

## 规则

- **界面只跟当前会话**：渲染器只观察当前会话的数据变化；后台会话的数据变化不碰界面。
- **门禁**：`canAffectHostUI(sessionId:)`——该会话是前台会话，且对话面板或工作区可见，App active。
  插槽视图写操作和宿主改界面的工具都用这条；`workspace` 工具本身只改会话数据，不过这条门禁。
- **独立页面**：`presentStandalonePage(id:title:workspace:)` 用同一容器展示不属于任何会话的只读页面（例如宿主保存的需求页），
  收起即释放，当前会话的工作区自动恢复；它的插槽视图 `persistsState == false`，不回写会话。
- **每个插槽名一个视图**：第一次显示该插槽时向宿主要一次，哪个会话到前台就 `bind(pageId:state:persistsState:)`
  给哪个，离开前台或换成别的插槽时 `unbind()`，功能关闭或内存告警且没人在用时 `dispose()`。
- 只改 state 不重载页面，改文件才重载 WebView。

## 测试

```sh
swift test --filter SessionWorkspaceTests   # 落盘、回收站恢复、整次拒绝、chat_panel
python3 Scripts/workspace-h5-tests.py       # H5 内容、触摸策略、scheme、桥脚本（真实 WKWebView）
```

容器挂载、手势穿透与切会话恢复需要宿主真机联调，测试不覆盖。
