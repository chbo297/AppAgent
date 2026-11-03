# Web 内省协议（WEB INSPECT PROTOCOL）

> **归属：AppAgent SDK。** 通用的 WebView 内省能力：让 agent 能回答「页面里某元素为何没展示」
> 「为何宽度没铺满」「JS 桥调了为何没反应」，**不绑定任何具体宿主 App**。
>
> 实现现状：`Sources/Core/HostCapability/WebInspectProvider.swift`（协议）、
> `DefaultWebInspectProvider.swift`（WKWebView 通用实现）、`Sources/Core/Tools/WebInspectTool.swift`（工具）。
> 宿主侧容器注册、桥协议和数据保留策略由宿主自己的接入文档定义。

## 1. 目标场景

1. **渲染问题**：「某按钮为何没展示」「某视图宽度为何没铺满」。agent 需要运行时 DOM、computed style、
   盒模型几何与遮挡关系，**而不是原始 HTML 源码**。
2. **桥问题**：「刚调了宿主的 JS 桥，为何没反应」。agent 需要 web 侧输出（console / JS 异常）、
   桥的入出消息，以及**失败原因**，再结合宿主源码推断结论。

## 2. 放置原则

能力优先放在 SDK 侧，让第一版**不依赖宿主发版**：

- DOM 查询用**一次性 `evaluateJavaScript`**，跑在独立 `WKContentWorld`；标注期间按需采样几何，
  未调用时不注入探针，不改页面加载路径。
- console / JS 异常采集按需 arming：`console_start` 时才装 `WKUserScript` + message handler，
  进程内环形缓冲，`console_stop` 摘除。
- 默认实现发现当前前台 scene 的 UIKit 树内 WKWebView，不承诺遍历外部 SDK 的脱树预加载池。
  业务容器归属、document-start 级采集仍由宿主补充；SDK 不依赖任何宿主类。

## 3. `app_web_inspect` 的 op 清单

工具名 `app_web_inspect`，group `host-runtime`。

- `targets`：列当前 scene/scope 内可发现的 WKWebView（UUID、url、title、frame、是否可见、宿主 VC 类名）。
  未传 `webviewId` 时仅选择可见且面积最大的容器，没有可见页面即失败，不回退隐藏页；
  显式 UUID 可只读检查同一前台 scene 内的隐藏页面，不能跨 scope/scene 寻址。
- `dom_summary`：语义锚点树。只列「有直接文本 / 可交互 / 有 id / 面积够大」的节点，大子树折叠成
  `⊞ N nodes` 并给出可二次调用的 path。行格式
  `<path> <tag>#<id>.<cls> rect=x,y,w,h [flags] "text…"`。
- `dom_query`：按 `path` 或 `selector` 定位，返回 attributes、坐标空间说明、盒模型（content/padding/border/margin）、computed 子集、
  `scrollWidth/clientWidth`、祖先链宽度与首个**约束宽度的祖先**——「没铺满」的答案在这里。
- `why_hidden`：一次判完 display / visibility / opacity / 零尺寸 / 祖先裁切 / 视口外 /
  被别的元素盖住（`elementFromPoint` 反查），直接给归因结论。
- `probe`：按屏幕点（view 坐标，自动换算 CSS px）反查节点，把用户说的「这个按钮」对上 path。
- `highlight` / `clear_highlight`：按 `selector` / `path` 在 WKWebView 上方显示或清除原生红框。
  红框完全触摸透传，不插 DOM，不借 `eval` 执行标注。每个 WKWebView 同时只有一个选中节点。
- `page_source`：`document.documentElement.outerHTML`（截断）或 `resources`
  （`performance.getEntriesByType('resource')` + 失败项）。
- `eval`：任意 JS，返回 JSON 可序列化结果。
- `console_start` / `console_read` / `console_stop`：`console.log/info/warn/error` + `error` +
  `unhandledrejection`，进程内环形缓冲（默认 500 条），`console_read` 支持 `sinceSeq` / `limit`。

## 4. 关键实现约定（改这块前先读）

- **path 约定**：从 `document.body` 起的子元素下标链（`"0/2/1"`）；`frame` 进入同源 iframe 的 body，
  `shadow` 进入 open shadow root，例如 `1/frame/0`、`2/shadow/0`，可组合嵌套。
  `html` 定位当前文档 documentElement。`dom_summary` 给出边界入口，按 path 钻取；
  `dom_query` / `why_hidden` / `highlight` 同时传 selector/path 时，在 path 指向的根下执行 querySelector，
  仅传 selector 时查顶层 document。跨源或 sandbox opaque-origin iframe、closed/不存在的 shadow root 明确失败；
  平台无法区分 closed 与未创建 shadow root，不伪称已读取。
- **坐标**：节点详情 rect 是所属 document 的 layout viewport CSS px，不是屏幕 pt；
  `probe` 输入是 WKWebView 局部 pt，按 visualViewport 和 content inset 换算。
  iframe 节点红框逐层换算到顶层 visual viewport，再转换为原生 pt；支持轴对齐缩放/平移，
  旋转、斜切、透视 iframe 几何明确拒绝。`why_hidden` 遮挡检查限当前 document/root。
- **独立 world**：`WKContentWorld.world(name: "appagent.inspect")` + `evaluateJavaScript(_:in:in:)`。
  SDK 持有同一 world 实例，使选中节点在后续几何采样间持续有效。
  共享持有 WKContentWorld 实例，保证选中节点在后续几何请求间持续存在；仅复用名称不足以保证全局状态存活。
  页面 JS 看不到探针，探针也不污染页面 `window`；CSP 不拦 WKUserScript / world eval。
- **不改 DOM**：正式结构查询只读；红框使用 WKWebView 的原生 UIView/CAShapeLayer 子视图，
  `isUserInteractionEnabled=false`，不往 DOM 插 overlay。选中的 DOM 引用仅存独立 world，
  不按 selector 反复重选，避免节点替换后悄悄标到另一个节点。
- **标注生命周期**：15Hz、有且仅有一个未完成的几何请求，覆盖滚动、缩放、visualViewport、CSS 布局变化；
  native offset/zoom/layout 已改变的旧采样丢弃，等待新采样，不把旧框贴到新位置。
  WKWebView/window 弱引用；导航、祖先隐藏/透明、离屏、移出窗口、scene/application 失活、
  节点脱离/不可见、清除或取消均移除标注与观察者。回调校验选择 token、几何 revision、窗口与 scope，
  旧请求不能复活已清标注。不替换宿主 navigationDelegate/scrollView delegate，不新建 overlay window。
- **console 代理必须在页面 world**：页面调的是页面 world 的 `console`，所以代理脚本注入 `.pageWorld`，
  保留原函数引用并透传，整体 try/catch；错误采集用 `addEventListener('error'/'unhandledrejection')`，
  **不覆盖 `window.onerror`**（会踩掉页面自己的兜底）。
- **绝不调 `removeAllUserScripts`**：宿主往同一个 `WKUserContentController` 注过自己的脚本（静音、浮层等），
  清掉会破坏宿主行为。只用 `removeScriptMessageHandler(forName:)`。反之宿主清脚本后，
  允许重新 `console_start` 补装。
- **输出预算**：`dom_summary` 目标 ≤3KB（默认 `maxNodes=120`），超出提示按 path 钻取；
  `page_source` 默认截断 64KB。
- **op 级安全**：只读 op 为 `.safe`；标注/清除、console 开关为 `.moderate`；
  `eval`、未知/缺失 op 为 `.sensitive`（见 §6）。

### 跨组件 identity 与 Provider 签名

WKWebView identity 存 objc associated object：key 必须是全局 selector
`NSSelectorFromString("appagent.webview.identity.v1")` **本身转换的指针**（不是 selector 变量地址），
value 为 `NSUUID().uuidString` 的 NSString。读取到已有值直接复用。主线程访问，registry 仅弱引用，
`targets` 的首字段及工具 `webviewId` 统一使用该 UUID，不再使用 `wN`。其他组件无需依赖 AppAgent，
按同样规则写入/读取即可关联记录；UUID 绑定实例，导航不换 ID。

```swift
@MainActor public static func identity(for webView: WKWebView) -> String

func highlight(webviewId: String?, selector: String?, path: String?,
               context: HostInspectionContext) async -> String
func clearHighlight(webviewId: String?, context: HostInspectionContext) async -> String
```

`WebInspectProvider` **所有方法均新增末尾 `context: HostInspectionContext`**（`targets(context:)`）。
自定义 provider 必须迁移签名并落实上下文边界；不提供丢弃 context 的旧协议兜底。
默认 provider 的 context 参数默认 `.init()`，直接无 session 调用仍由宿主承担执行授权责任。

## 5. 抓包通道

`HookCaptureStore` 不内置通道集合。宿主可以为桥入站、桥出站、页面 console、导航事件或其他
诊断来源定义自己的通道名；通道名只允许 ASCII 字母、数字、`.`、`_`、`-`，并作为 JSONL
文件名的一部分。宿主负责声明每个通道的记录字段、方向、状态码和脱敏规则。

桥的失败路径是否复用入出通道、是否单独建立错误通道，都由宿主协议决定。SDK 只提供按 channel
开关、文件扫描、页面/容器/调用/进程游标过滤和有界输出，不解释业务字段。

一次桥调用的入/出两条记录靠 `callId` 配对，**超时未回包的判定放 agent 侧算**，端上不做定时器。

## 6. 权限与执行边界

工具通过既有 executor 执行 gate、op 授权；内部调用 `HostInspectionAccess.context`，
修改操作再次检查 readOnly/gate。`scope` 默认 host，appagent/all 仍须当前轮的独立读取/修改授权，
`inspectionSceneIdentifier` 约束 scene，缺绑定且多个前台 scene 时拒绝猜测。
任意 `eval` 已提升为 sensitive；只看 DOM、同意原生标注均不等于授权任意 JS 修改。
provider 不负责推断用户意图，宿主 gate 继续按真实用户 turn 决定能力上限。
preflight 与 execute 共用参数校验：错误类型、空 webviewId/selector、非有限数、非整数及溢出直接失败，
不能把非法参数当作省略并落到默认页面。空 path 则明确代表 body。

上线前必须逐条补回（不允许默认继承内部行为）：

1. 任何未来 DOM 写回操作保持 `.sensitive` 或更高，不能复用 safe 读取或 moderate 标注入口。
2. **采集脱敏**：URL query 里的 token/手机号、`input[type=password]`、localStorage 一律不采；
   落盘上限与自动过期沿用宿主抓包框架的过滤/采样。
3. **诊断数据只在显式导出时上传**，不默认外传。
4. **域名与调用者判定由宿主策略提供**（SDK 不内置任何域名规则）：宿主通过自己的 gate
   或 `WebInspectProvider` 实现拒绝非受信页面。

## 7. 验证方式

Core 定向运行 `swift test --filter WebInspectTests`，覆盖分发、数值/类型/目标参数、错误、readOnly、scope 与 gate。
`Tests/UI/WebInspectViewTests.swift` 使用真实 WKWebView 加载内存 HTML，再调用 provider：
UUID 复用/弱引用、DOM attributes/坐标、iframe/shadow 边界、红框尺寸/触摸透传/零 DOM mutation、
滚动/布局、导航、隐藏/离屏和迟到结果隔离。有 scene 时使用 UIWindow；无 scene 的 Catalyst runner
使用 internal 单 UIView 根节点注入，避开 UIApplicationMain 缺失时的窗口构造，不手工初始化 NSApplication。
注入要求明确 binding、弱引用根节点并继续校验归属；生产公开初始化入口仍只使用真实活动 scene。
测试可暂缓交付真实 WebKit 几何结果，固定 clear/cancel/重新选择/归属变更的先后顺序，不伪造几何、不跳过用例。
释放断言与未登记的 WKWebView 对照，允许有限 run-loop 清理时间；另验选中页面移除后的 controller/overlay 释放。
完整 UIKit 构建与测试由主流程统一执行；编译通过不等于运行通过。

当前验证状态：Core 18 项与 identity 释放对照已实测通过；最新根节点注入、world 持有与延迟回调用例
尚待同一落盘版本的 UIKit 定向测试。旧 runner 的跳过或旧源码的测试结果不能作为新版红框验收。

## 8. AppAgent 侧文件索引

`Sources/Core/HostCapability/WebInspectProvider.swift`、`DefaultWebInspectProvider.swift`、
`Sources/Core/Tools/WebInspectTool.swift`、`Sources/Core/HostCapability/HostToolset.swift`（装配）、
`WebInspectHighlight.swift`（原生标注与生命周期）、`Tests/Core/WebInspectTests.swift`、
`Tests/UI/WebInspectViewTests.swift`。显式工程需把新增 `WebInspectHighlight.swift` 纳入编译，
测试工程另纳入 `WebInspectViewTests.swift`。
