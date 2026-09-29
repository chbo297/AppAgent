# Web 内省协议（WEB INSPECT PROTOCOL）

> **归属：AppAgent SDK。** 通用的 WebView 内省能力：让 agent 能回答「页面里某元素为何没展示」
> 「为何宽度没铺满」「JS 桥调了为何没反应」，**不绑定任何具体宿主 App**。
>
> 本文已从 liji_server 仓迁入 AppAgent 仓（`docs/WebInspect.md`）——本仓即归属仓。
>
> 实现现状：`Sources/Core/HostCapability/WebInspectProvider.swift`（协议）、
> `DefaultWebInspectProvider.swift`（WKWebView 通用实现）、`Sources/Core/Tools/WebInspectTool.swift`（工具）。
> 宿主侧怎么接见 mapframework 仓 `docs/WEB_INSPECT_INTEGRATION.md`；服务端归因契约见 liji_server 仓 `docs/WEB_DIAGNOSIS_CONTRACT.md`。

## 1. 目标场景

1. **渲染问题**：「某按钮为何没展示」「某视图宽度为何没铺满」。agent 需要运行时 DOM、computed style、
   盒模型几何与遮挡关系，**而不是原始 HTML 源码**。
2. **桥问题**：「刚调了宿主的 JS 桥，为何没反应」。agent 需要 web 侧输出（console / JS 异常）、
   桥的入出消息，以及**失败原因**，再结合宿主源码推断结论。

## 2. 放置原则

能力优先放在 SDK 侧，让第一版**不依赖宿主发版**：

- DOM 查询用**一次性 `evaluateJavaScript`**，跑在独立 `WKContentWorld`；未调用时**不注入任何脚本**，
  页面加载路径零改动。
- console / JS 异常采集按需 arming：`console_start` 时才装 `WKUserScript` + message handler，
  进程内环形缓冲，`console_stop` 摘除。
- 宿主只在两件事上不可替代：**给容器稳定 id 与归属**（否则只能靠"栈顶"猜）、
  **document-start 级采集**（补上 arming 之前的日志）。这两项由宿主实现 `WebInspectProvider` 覆盖默认实现。

## 3. `app_web_inspect` 的 op 清单

工具名 `app_web_inspect`，group `host-runtime`。

- `targets`：列活着的 WKWebView（`w1`…、url、title、frame、是否可见、宿主 VC 类名、原生 view path）。
- `dom_summary`：语义锚点树。只列「有直接文本 / 可交互 / 有 id / 面积够大」的节点，大子树折叠成
  `⊞ N nodes` 并给出可二次调用的 path。行格式
  `<path> <tag>#<id>.<cls> rect=x,y,w,h [flags] "text…"`。
- `dom_query`：按 `path` 或 `selector` 定位，返回盒模型（content/padding/border/margin）、computed 子集、
  `scrollWidth/clientWidth`、祖先链宽度与首个**约束宽度的祖先**——「没铺满」的答案在这里。
- `why_hidden`：一次判完 display / visibility / opacity / 零尺寸 / 祖先裁切 / 视口外 /
  被别的元素盖住（`elementFromPoint` 反查），直接给归因结论。
- `probe`：按屏幕点（view 坐标，自动换算 CSS px）反查节点，把用户说的「这个按钮」对上 path。
- `page_source`：`document.documentElement.outerHTML`（截断）或 `resources`
  （`performance.getEntriesByType('resource')` + 失败项）。
- `eval`：任意 JS，返回 JSON 可序列化结果。
- `console_start` / `console_read` / `console_stop`：`console.log/info/warn/error` + `error` +
  `unhandledrejection`，进程内环形缓冲（默认 500 条），`console_read` 支持 `sinceSeq` / `limit`。

## 4. 关键实现约定（改这块前先读）

- **path 约定**：从 `document.body` 起的子元素下标链（`"0/2/1"`），与 `app_runtime_inspect` 的 view path 同风格；
  `dom_query` / `why_hidden` 同时接受 `selector`（优先 `selector`）。
- **独立 world**：`WKContentWorld.world(name: "appagent.inspect")` + `evaluateJavaScript(_:in:in:)`。
  页面 JS 看不到探针，探针也不污染页面 `window`；CSP 不拦 WKUserScript / world eval。
- **不改 DOM**：`why_hidden` / `dom_query` 全部只读。高亮框（若后续要做）由原生在 WKWebView 上盖 UIView，
  **不往 DOM 插 overlay**（会触发页面自己的 MutationObserver）。
- **console 代理必须在页面 world**：页面调的是页面 world 的 `console`，所以代理脚本注入 `.pageWorld`，
  保留原函数引用并透传，整体 try/catch；错误采集用 `addEventListener('error'/'unhandledrejection')`，
  **不覆盖 `window.onerror`**（会踩掉页面自己的兜底）。
- **绝不调 `removeAllUserScripts`**：宿主往同一个 `WKUserContentController` 注过自己的脚本（静音、浮层等），
  清掉会破坏宿主行为。只用 `removeScriptMessageHandler(forName:)`。反之宿主清脚本后，
  允许重新 `console_start` 补装。
- **输出预算**：`dom_summary` 目标 ≤3KB（默认 `maxNodes=120`），超出提示按 path 钻取；
  `page_source` 默认截断 64KB。
- **op 级安全**：只读 op 为 `.safe`；`eval` / `console_start` / `console_stop` 为 `.moderate`（见 §6）。

## 5. 抓包通道扩展

`HookCaptureStore.channels` 末尾追加两个通道（**只能末尾追加**，顺序即协议，读取侧按下标认通道）：

- `web_console`：web 侧输出与 JS 异常。
- `web_nav`：导航生命周期（开始 / 完成 / 失败 / web 内容进程终止）+ HTTP 状态 + 白屏。

**桥的失败路径不新开通道**：复用宿主已有的 in/out 通道，用记录里的 `status` 字段记负数错误码，
具体码值与语义由宿主定义并在宿主文档中声明（服务端据此做确定性归因）。
一次桥调用的入/出两条记录靠 `callId` 配对，**超时未回包的判定放 agent 侧算**，端上不做定时器。

## 6. 权限：当前放开，上线前必须补回

当前（内部使用阶段，owner 2026-09-27 决定）：任意 URL 可内省、不做调用者白名单、
`eval` 为 `.moderate` 不弹卡片、采集内容不脱敏——以免影响排查效率。

上线前必须逐条补回（不允许默认继承内部行为）：

1. **`eval` 与任何 DOM 写回抬到 `.sensitive`**，走 `DecisionRequest` 授权卡片。
2. **采集脱敏**：URL query 里的 token/手机号、`input[type=password]`、localStorage 一律不采；
   落盘上限与自动过期沿用宿主抓包框架的过滤/采样。
3. **诊断数据只在显式导出时上传**，不默认外传。
4. **域名与调用者判定由宿主策略提供**（SDK 不内置任何域名规则）：宿主通过 `AIAgentDelegate.policyFor(request:)`
   或自己的 `WebInspectProvider` 实现拒绝非受信页面。宿主侧要补什么见
   mapframework 仓 `docs/WEB_INSPECT_INTEGRATION.md` §4。

## 7. 验证方式

`swift build && swift test`（Core 单测 `Tests/Core/WebInspectTests.swift`），随后
`Scripts/simulator-selfcheck.sh` 在模拟器里用真实 WKWebView 跑自检项 `checkWebInspect`
（挂一次性隐藏 scratch WKWebView、灌「按钮 display:none / 内容比容器宽」的 HTML，
跑 targets→dom_summary→why_hidden→dom_query→eval，跑完移除不留痕）。

## 8. AppAgent 侧文件索引

`Sources/Core/HostCapability/WebInspectProvider.swift`、`DefaultWebInspectProvider.swift`、
`Sources/Core/Tools/WebInspectTool.swift`、`Sources/Core/HostCapability/HostToolset.swift`（装配）、
`HookCaptureStore.swift`（通道）、`Tests/Core/WebInspectTests.swift`。
