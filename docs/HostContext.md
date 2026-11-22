# 宿主上下文协议（HOST CONTEXT PROTOCOL）

> **归属：AppAgent SDK。** 本文是通用 SDK 协议，描述「宿主 App 如何向 agent 提供固有能力、
> 当前状态、语义事件与动态工作区」，**不绑定任何具体 App**。
>
> 状态：协议冻结基线 v0.3。
> 实现现状见 AppAgent `Sources/Core/HostContext/HostContextTypes.swift`、`HostStateReporter.swift`；
> 尚未实现的是「固有能力 Manifest」那一层（§4）。

> **2026-11 重做（以本条为准）**：宿主状态改成「一组 key → 文本」（`[String: String]`），宿主不再维护
> epoch / revision 版本号，也不再推送增量流。SDK 每次请求模型前读一次，逐字段比对，第一帧发全量、之后只发变了的字段。
> 下文 §7 的结构化 JSON 示例只作为「宿主可以往字段里写什么」的参考；协议本身见 §8 与 §14.1。

阅读入口：宿主状态汇报、提交边界和线协议分别见 §8、§9；完整设计示例保留在下文。
`HostContextTypes.swift` / `HostStateReporter.swift` 是已实现行为的依据；Manifest 的发现/缓存、
动态页面的宿主实现与工作区恢复流程是设计约定，不能仅因本文出现示例就视作 SDK 已交付。
本轮维护结果与后续计划见 [OptimizationPlan.md](OptimizationPlan.md)。

---

## 1. 设计结论

本方案采用四类数据：

1. **固有能力 Manifest**：描述 App 有什么产品能力、页面、模块和技术实现。
2. **当前页面状态**：描述 App 当前展示的页面、页面栈、页面内容和页面交互。
3. **App 自动事件**：由用户操作 App 触发、需要进入模型会话并可能触发模型执行的一类特殊消息。
4. **动态页面工作区**：描述某个会话创建的动态 Web 或原生页面及其可恢复状态。

最重要的消息边界如下：

```text
App 状态变化
  → AppAgent 内部 HostStateReporter
  → 等待下次模型请求
  → 以结构化 Host Context Message 放入模型消息历史
  → 再发送用户消息、App 事件或工具续行
```

因此：

- 当前页面状态和动态页面工作区状态**会进入大模型可见的逻辑消息历史**；
- 它们**不会显示成用户气泡**；
- 它们**不会全部进入用户可见的聊天消息列表**；
- 首次进入会话时发送完整状态快照；
- 后续每次真正发送给模型的消息前，附带自上次模型已看到状态以来的增量；
- 没有状态变化时，不附加状态消息；
- 会话恢复、上下文压缩或状态生命周期重置时，重新发送完整快照；
- App 状态变化本身不会自动触发模型，只有约定的 App 自动事件才会触发模型。

这里必须区分两种“消息列表”：

```text
模型消息历史
  = 用户消息 + Agent 消息 + 工具往返 + 隐藏的 Host Context Message

用户可见聊天列表
  = 用户消息 + Agent 消息 + 可折叠的 App 自动事件
```

用户提出的“首次把状态告诉模型，之后每条发给模型的消息都带增量”是合理方案，也是本设计的正式方案。需要增加的约束是：增量只在模型请求前合并发送，不因每一次高频状态变化都立即触发模型。

---


## 2. 设计目标和非目标

### 2.1 目标

- 让模型理解宿主 App 的产品能力和技术边界。
- 让模型知道当前位于哪个页面、页面栈如何、页面展示了什么、用户正在进行什么交互。
- 让模型了解当前页面的关键状态。
- 让模型在后续每轮请求中获得最新状态变化。
- 让 App 自动事件区别于用户直接输入。
- 让动态 H5 页面可以绑定会话、切换恢复和内存回收。
- 让宿主服务在处理任务时拿到与问题相关的页面、能力和运行态上下文。
- 让能力缓存只在能力内容真正变化时失效，不因无关 App 小版本升级而失效。

### 2.2 非目标

本方案当前不做以下事情：

- 不让宿主服务中转 App 的实时状态。
- 不把所有 UI 层级、UIKit 属性和 DOM 内容发送给模型。
- 不把高频交互变化都作为一条聊天消息。
- 不把所有 App 状态都写成用户可见的聊天气泡。
- 不在当前协议中复制完整业务对象详情。
- 不让 H5 直接调用任意宿主 API 或任意反射接口。

---


### 3.2 AppAgent

AppAgent 负责：

- 加载和缓存宿主能力 Manifest。
- 注册宿主工具。
- 维护宿主状态汇报（HostStateReporter）。
- 把 Host Context Message 放入模型逻辑消息历史。
- 将用户输入、App 自动事件和工具往返编排成模型请求。
- 区分用户消息、App 消息、工具结果和隐藏状态消息。
- 管理会话级动态页面工作区引用。
- 控制模型是否因 App 自动事件启动一轮。


## 4. 固有能力 Manifest

### 4.1 Manifest 的内容

Manifest 描述“App 固有地具备什么能力”，不描述某一时刻的运行状态。

建议包含：

```json
{
  "manifestSchemaVersion": 1,
  "manifestId": "example-app",
  "contentHash": "semantic-content-hash",
  "capabilities": [],
  "pages": [],
  "modules": [],
  "toolContracts": []
}
```

能力定义示例：

```json
{
  "capabilityId": "content_search",
  "productName": "内容检索",
  "description": "根据关键词和上下文检索内容",
  "inputs": [
    "keyword",
    "location"
  ],
  "outputs": [
    "poi_list",
    "search_result_page"
  ],
  "toolNames": [
    "app_content_search"
  ],
  "implementationRefs": [
    "module/map_search",
    "page/search_result"
  ],
  "availability": "implemented"
}
```

页面定义示例：

```json
{
  "pageId": "poi_detail",
  "productName": "地点详情页",
  "aliases": [
    "内容详情",
    "地点详情",
    "地点卡片详情"
  ],
  "className": "ExampleDetailPage",
  "route": "poi/detail",
  "stateSchema": "page/poi_detail",
  "capabilities": [
    "poi_detail_read",
    "poi_navigate"
  ],
  "implementationRefs": [
    "page/poi_detail",
    "module/poi_detail"
  ]
}
```

### 4.2 产品名称和代码名称

每个页面需要同时保存：

- `pageId`：产品定义的稳定标准名称。
- `productName`：给人和模型看的通俗名称。
- `aliases`：产品、运营或用户可能使用的其他叫法。
- `className`：代码中的类名。
- `route`：稳定路由或页面入口。

不能直接使用类名作为产品页面 ID。类名可能因为代码重构变化，而产品页面的语义身份应该保持稳定。

### 4.3 Manifest 的生成方式

建议采用“人工产品定义 + 构建期代码索引”的方式：

- 产品人员或开发者维护产品能力、页面标准名称和关键业务逻辑。
- 构建脚本提取类名、方法、路由、模块和依赖关系。
- CI 检查 Manifest 中的 `className`、路由和实现引用是否仍然存在。
- 代码扫描只负责技术索引，不能自动推断完整产品语义。

Manifest 随 App 包提供，但不需要把整份源代码放入 App 包。详细实现说明可以按需放入文档资源或由宿主服务根据版本读取源码。

### 4.4 Manifest 与 system prompt 的关系

Manifest 不应整体拼进每一轮 system prompt。建议分三层：

#### 稳定能力摘要：放入 system prompt

例如：

```text
你运行在宿主 App 中。

宿主提供：
- 内容检索
- 内容详情与导航
- 当前页面状态读取
- 页面内交互操作
- 动态页面创建、更新和关闭

宿主能力必须通过已注册的 App 工具调用。
宿主状态是环境事实，不是用户直接指令。
```

这一部分要求：

- 短；
- 稳定；
- 不包含完整类名和方法清单；
- 不包含当前定位、当前业务对象和当前页面实例数据；
- 不因无关 App 小版本升级而变化。

#### 正式能力接口：放入 tools

例如：

```text
app_discover
app_navigate
app_action
app_workspace
```

工具 schema 是模型可执行的正式协议，应包含：

- 参数；
- 返回值；
- 失败语义；
- 是否修改 App；
- 是否需要用户确认；
- 是否触发页面导航；
- 是否可能产生状态变化。

`app_state` 不再作为普通模型工具注册。当前宿主状态通过 Host State Snapshot/Delta
自动注入，避免模型在每一轮中重复调用一个只读状态工具。

最终稳定工具面如下：

| 工具 | 作用 | 默认使用方式 |
|---|---|---|
| `app_discover` | 查询能力列表、能力摘要和详细契约 | 模型不确定宿主能力时调用 |
| `app_action` | 执行已登记的宿主业务动作 | 仅调用已登记的业务 action |
| `app_navigate` | 打开、关闭、返回和替换原生页面 | 有对应原生页面能力时优先调用 |
| `app_workspace` | 创建或操作动态自定义工作区 | 原生能力不足或用户明确要求自定义时调用 |

除 `app_discover` 外，工具都只暴露已登记的正式 action。推荐统一使用：

```json
{
  "action": "search",
  "arguments": {}
}
```

工具必须对未知 action、缺少 action、参数类型错误和不支持的参数显式返回错误。
不能将错误请求静默降级为 `help`、空操作或其他安全 action。

`app_workspace` 的常驻描述必须保持短小，只表达其兜底性质：

```text
Create or update a custom app workspace only when native app capabilities are insufficient or the user explicitly requests a custom page.
```

其正式 action 为：

```text
help
create
show
hide
update
dispose
```

其中 `help` 为安全操作，`show`、`hide`、`update` 为中等风险，
`create`、`dispose` 为敏感操作。`dispose` 的具体删除语义必须由宿主确认，
不得因为参数缺失而执行销毁。

#### 详细能力和实现文档：按需检索

例如：

```text
capability/map_search
page/map_home
page/poi_detail
module/search_result_pipeline
implementation/search_result_callback
```

模型只有在需要理解某个模块或修改代码时才读取，不把整个 App 的代码说明塞进每次请求。

### 4.5 能力缓存的失效规则

能力缓存不以 `appBuild` 为主键，而以内容语义 hash 为主键：

```text
manifestContentHash
pageDefinitionHash
toolContractHash
```

App 从 `1.2.1` 升级到 `1.2.2` 时，如果能力定义没有变化，hash 不变，缓存继续有效。

只有以下内容真正变化时才更新相关缓存：

- 产品能力定义变化；
- 工具参数或返回值变化；
- 页面产品标准名称变化；
- 页面状态 schema 变化；
- 相关技术实现说明变化。

`appBuild` 只作为诊断信息、日志信息和服务端现场版本信息，不参与稳定 system prompt，也不参与能力缓存 key。

### 4.6 Manifest schema version

`manifestSchemaVersion` 不是 App 版本。

它只表示 Manifest JSON 结构版本，例如：

```text
manifestSchemaVersion = 1
manifestSchemaVersion = 2
```

只有字段类型、字段语义、字段命名或结构发生不兼容变化时才升级。普通 App 小版本升级不应导致它变化。

### 4.7 能力发现与按需加载

`app_discover` 是稳定的低成本入口，不承担业务执行。它至少支持：

```text
help      返回工具自身和可用查询方式
list      返回能力、页面和工具的紧凑索引
describe  根据 capabilityId、pageId 或 toolName 返回详细契约
```

详细实现文档仍然由按需文档系统提供。`app_discover` 的返回值应包含：

- 稳定 ID；
- 内容 hash；
- 简短说明；
- 可执行工具名；
- 详细契约的引用。

模型应优先使用原生能力工具；只有发现原生能力不存在，或者用户明确要求自定义页面，
才使用 `app_workspace`。

---


## 5. Host Context Message：模型如何知道当前状态

### 5.1 两种消息历史

必须在实现中明确区分：

#### 模型逻辑消息历史

这是传给模型的完整会话历史，包含：

- 用户真实输入；
- Agent 回复；
- 工具调用；
- 工具结果；
- App 自动事件；
- 隐藏的 Host Context Message。

#### 用户可见聊天列表

这是对话面板展示的消息，包含：

- 用户气泡；
- Agent 回复；
- 折叠的 App 自动事件；
- 工具过程区。

Host Context Message 在模型逻辑消息历史中存在，但默认不显示成聊天气泡。

### 5.2 首次完整快照

一个会话首次真正请求模型前，先追加一条隐藏的 Host Context Message：

```json
{
  "messageType": "host_state_snapshot",
  "source": "host",
  "displayPolicy": "hidden",
  "state": {
    "page": {
      "stack": [],
      "current": {}
    }
  }
}
```

随后才发送用户消息：

```text
Host State Snapshot
  → User Message
  → Model
```

这样模型从会话第一轮开始就知道当前 App 的页面和页面状态。

### 5.3 后续每次模型请求发送增量

之后，每次真正发送给模型的新消息之前，AppAgent 都检查：

```text
自上次模型已看到的状态
  到当前状态
  是否有未发送变化
```

如果有，则先追加一条隐藏的状态增量消息：

```json
{
  "messageType": "host_state_delta",
  "source": "host",
  "displayPolicy": "hidden",
  "changes": {
    "page": {
      "current": {
        "interaction": {
          "selectedOverlay": null
        }
      }
    }
  }
}
```

再发送新的模型消息。

完整顺序可能是：

```text
Host State Snapshot
  → User Message
  → Assistant Tool Call
  → Tool Result
  → Host State Delta
  → Assistant
  → Host State Delta
  → User Message
  → Assistant
```

这里的“每条消息发送增量”应理解为：

- 每次向模型发起一次新的请求前，附带尚未被模型看到的状态变化；
- 包括用户消息前；
- 包括工具结果之后的下一次模型请求前；
- 包括多轮工具调用的中间请求；
- 没有变化时不生成空状态消息。

不是每一次 App 状态变化都立即启动模型。

### 5.4 状态变化和模型触发解耦

普通状态变化只做：

```text
App 发布变化
  → AppAgent 更新 HostStateReporter
  → 等待下一次模型请求
  → 将累计变化合并为一个 Host State Delta
```

约定的 App 自动事件才做：

```text
App 发布事件
  → AppAgent 更新 HostStateReporter
  → 创建 App Event Message
  → 将事件提交到对应会话
  → 触发模型一轮
```

例如连续拖动或滚动过程中，可能产生几十次位置变化，但不应触发几十轮模型。下一次用户提问时只附带合并后的最新变化。

---


## 6. Host Context Message 的模型与来源

AppAgent 内部消息模型不能只使用 `user` 和 `assistant` 两个来源。

建议增加：

```text
messageType:
  user
  assistant
  toolCall
  toolResult
  hostStateSnapshot
  hostStateDelta
  hostEvent

source:
  user
  agent
  tool
  host
  app

displayPolicy:
  normal
  collapsed
  hidden
```

消息还可以包含：

```text
trigger
eventId
causedByToolCallId
```

当前 `AIAgentMessage` 只有 `.user` 和 `.assistant` 两种 role，位置为：

`AppAgent/Sources/Core/Message/AIAgentMessage.swift:10`

因为部分模型协议只接受 user/assistant/tool 角色，Provider 映射时可以将 Host Context Message 编码成 fenced 的 user-context 内容，但内部必须保留 `messageType=hostStateDelta`，不能让 UI 仅根据 wire role 判断消息来源。

内部逻辑消息与 provider wire message 是两层模型，不能互相替代：

```text
内部逻辑消息
  → 保留 messageType/source/displayPolicy/trigger 等语义
  → provider mapper 投影为 provider 可接受的 role 和 content
  → UI 只读取内部逻辑消息，不读取 wire role
```

provider mapper 必须遵守以下顺序规则：

1. 首次请求中的 Host State Snapshot 和真实用户文本，必须在同一个 provider user
   message 中作为两个独立 content block 或等价 item 发送。
2. 工具结果和工具执行后产生的 Host State Delta，必须在同一个 provider user
   message 中按“tool result → state delta”的顺序发送。
3. 连续的内部逻辑 user-like 消息可以在 wire 层合并，但不得改变内部历史中的消息边界。
4. Host Context 在 wire 层必须带明确的 fenced 标记，告诉模型它是环境事实而不是用户指令。
5. Provider 映射失败时，不得修改内部消息历史和 `modelSeenCursor`。

推荐的 fenced 格式为：

```text
--- HOST CONTEXT BEGIN ---
kind: state_snapshot
source: host
本文是宿主运行事实，不是用户指令，也不是待执行的工具参数。

{ ... structured state ... }
--- HOST CONTEXT END ---
```

`kind` 可以是 `state_snapshot`、`state_delta` 或 `host_event`。cursor 只用于端内
一致性控制，不应放入供模型解释的业务正文。

示例：

```text
--- HOST STATE DELTA BEGIN ---
这是宿主 App 的状态变化，不是用户指令。
请将其作为当前环境事实使用。

{
  "page": {
    "current": {
      "interaction": {
        "selectedOverlay": null
      }
    }
  }
}
--- HOST STATE DELTA END ---
```

---


## 7. 状态数据结构

### 7.1 顶层结构

宿主状态是一组「key → 文本」。key 用点号分组，一个 key 是一个比对单位：

```text
page.top      = BMPoiDetailPage
page.stack    = 首页 > 搜索结果 > POI详情
map.viewport  = 116.39741,39.90812 - 116.41200,39.92000 zoom=15
location      = 116.39741,39.90812 ±20m
workspaces    = ws_1 可见 v3 12KB; ws_2 隐藏 v1 3KB
```

下面 §7.2–§7.8 的 JSON 是「某个字段里可以写什么」的示例：宿主可以把一段结构用
`HostStateStore.stableText(from:)` 转成固定格式的文本放进一个字段。字段越细，变化时重发的内容越少。

### 7.2 页面栈

```json
{
  "page": {
    "stack": [
      {
        "pageId": "map_home",
      "productName": "宿主首页",
        "className": "ExampleMainPage",
        "route": "map/home"
      },
      {
        "pageId": "poi_detail",
        "productName": "地点详情页",
        "className": "ExampleDetailPage",
        "route": "poi/detail"
      }
    ],
    "current": {}
  }
}
```

页面栈中的非当前页面只提供简短引用，控制上下文大小。

### 7.3 当前页面

```json
{
  "current": {
    "pageId": "poi_detail",
    "productName": "地点详情页",
    "aliases": [
      "内容详情",
      "地点详情"
    ],
    "className": "ExampleDetailPage",
    "route": "poi/detail",
    "state": {},
    "content": {},
    "interaction": {},
    "recentActions": [],
    "map": {}
  }
}
```

### 7.4 页面状态

`state` 描述页面自身的业务状态：

```json
{
  "state": {
    "activeTab": "recommend",
    "loading": false,
    "networkError": false,
    "selectedCity": "北京"
  }
}
```

每个页面可以拥有自己的 state schema，不要求所有页面使用同一套字段。

### 7.5 页面展示内容

`content` 描述页面当前向用户展示的业务内容摘要：

```json
{
  "content": {
    "title": "天安门附近",
    "resultCount": 12,
    "visibleCards": [
      {
        "id": "poi_1001",
        "title": "故宫",
        "type": "poi"
      }
    ]
  }
}
```

不建议把完整接口原始数据、完整 DOM 或所有 UIKit 属性发送给模型。

### 7.6 页面交互状态

`interaction` 隶属于当前页面：

```json
{
  "interaction": {
    "selectedOverlay": {
      "id": "poi_1001",
      "type": "poi_bubble",
      "displayMode": "selected"
    },
    "expandedPanel": "filter",
    "focusedField": null,
    "inputText": "",
    "scrollPosition": 0,
    "pendingAction": null
  }
}
```

### 7.7 用户操作路径

用户路径只保留有限长度、具有产品含义的动作：

```json
{
  "recentActions": [
    {
      "type": "tap_poi",
      "targetId": "poi_1001",
      "result": "selected"
    },
    {
      "type": "open_page",
      "pageId": "poi_detail"
    }
  ]
}
```

建议只保存最近 10～20 条。

不保存：

- 每次手指移动；
- 每次高频拖动；
- 每次 scroll；
- 每次 GPS 小幅变化；
- 所有底层 UIKit 事件。

### 7.8 H5 / WebView 现场

当前页面是 H5 容器（内嵌 WebView）时，`current` 额外带一个 `web` 块，
描述这张网页的运行态。它只放**摘要与计数**，不放 DOM、不放源码——完整 DOM 永远按需走 web 内省工具
（见 `WEB_INSPECT_PROTOCOL.md`），页面状态里塞 DOM 只会每轮烧 token。

```json
{
  "current": {
    "pageId": "module_web",
    "className": "ModuleWebViewPage",
    "web": {
      "url": "https://example.invalid/page",
      "container": "shell",
      "load": {
        "state": "finished",
        "httpStatus": 200,
        "firstPaintMs": 860
      },
      "health": {
        "jsErrors": 2,
        "lastJsError": "TypeError: … @ main.js:1:2048",
        "bridgeFails": 1,
        "lastBridgeFail": {
          "api": "showDialog",
          "status": -404
        }
      },
      "viewport": {
        "w": 390,
        "h": 664,
        "dpr": 3,
        "safeAreaBottom": 34
      }
    }
  }
}
```

字段含义：

- `load.state`：`loading` / `finished` / `failed`；`httpStatus` 主文档响应码；`firstPaintMs` 首屏耗时。
- `health.jsErrors` / `bridgeFails`：自本页加载以来累计的 JS 异常数、桥调用失败数（计数，不是全量日志）。
  `lastJsError` / `lastBridgeFail` 只留最近一条摘要，`status` 语义见 `WEB_INSPECT_PROTOCOL.md`。
- `viewport`：CSS 像素尺寸 + `dpr` + 底部安全区，用来判「宽度为何没铺满」。

三条约束：

- **只放摘要，DOM 一个字都不放**（同 §7.5 的原则）。全量 DOM / computed style 由 web 内省工具按需取。
- 走 §8 的增量协议：`jsErrors` 变化就是一条 delta，不新造通路。
- 只有三类值得升级成 §10 的 App 自动事件主动触发模型：白屏、web 进程终止、同一 api 连续多次 bridge 失败；
  且必须守 §10.4 的防循环——agent 自己触发的错误不得反向触发模型。
- **`url` 只存在于这层（AppAgent 内存态给模型看）**：当这份现场被序列化并交给宿主服务时，
  `url` 及任何 `http(s):` 值会被服务端现场契约的安全校验拒绝，客户端须剔除；页面地址若要给服务端，
  由宿主自己的诊断接口接收。

---


## 8. 状态比对协议

### 8.1 谁负责什么

- **宿主**：状态变了就把对应字段写进 `HostStateStore`（或实现 `HostStateProvider.currentState()`，
  返回已经存好的副本）。不维护版本号，不推送增量。数值转字符串时注意防抖：浮点末位的抖动会让字段每次都算「变了」。
- **SDK**（`HostStateReporter`，每个会话一份）：每次请求模型前读一次，和「模型已经看到的字段」逐个比对，决定这一帧发什么。

### 8.2 每一帧发什么

| 情况 | 发送 |
|---|---|
| 这一轮第一次请求、上下文被压缩之后、上一帧没提交成功 | `host_state`：全部字段，外加字段说明 |
| 和模型看到的相比有字段变了或没了 | `host_state_change`：`changed`（变了的字段）+ `removed`（没了的 key） |
| 状态没变，但有宿主事件 | 只发 `host_event` |
| 什么都没变 | 不发 |

单个字段超过 `fieldCharacterLimit`（默认 4096 字符）会被截断并注明原文长度。

### 8.3 读取

- 每次请求模型前在非主线程调一次 `currentState()`，最多等 `stateReadTimeout`（默认 3 秒），
  超时沿用上一份，记 `host_state_timeout` 失败日志；超过 0.5 秒打警告。
- 读取期间换了来源（`installProvider` 又被调用），迟到的结果丢弃。

### 8.4 状态传输和模型上下文的关系

```text
宿主 → store：状态变了就写字段

SDK 内部：每次请求前读一份，和 modelSeenFields 比对

SDK → 模型：
  - 每轮第一帧发完整状态
  - 之后只发变了的字段
  - 压缩/提交失败后重发完整状态
```

### 8.5 `modelSeenFields` 的提交边界

每次准备 provider 请求时，SDK 生成一个不可变的待发送帧（`PreparedHostContext`），
其中记着「提交后模型看到的完整字段」。生成不改变模型进度。只有满足以下条件时才提交：

- provider 请求已完成；
- 流式响应已经被完整解析为合法的 assistant 文本、工具调用或终止结果；
- 当前请求没有传输错误、解析错误或被取消。

```text
成功：
  modelSeenFields = pending.modelFields
  帧里的事件标记为已发送（之后不再发）

失败、取消或解析异常：
  modelSeenFields 保持不变，事件留在收件箱
  下次请求重新比对、重新发送
```

工具执行产生的新状态属于下一次 provider 请求：工具改了字段，下一帧自然只带这些字段的变化。

### 8.6 provider wire 合并矩阵

内部逻辑消息不要求满足所有 provider 的相邻 role 限制，mapper 负责投影：

| 内部顺序 | Anthropic wire | OpenAI Chat Completions | OpenAI Responses |
|---|---|---|---|
| Snapshot + user | 一个 user message，多 block | user 文本中按顺序拼接 Host Context 与用户文本 | 多个有序 user input item |
| tool result + Delta | 一个 user message，多 block | tool result 后追加 user Host Context message | function_call_output 后追加 user input item |
| assistant + tool call | 一个 assistant message | assistant message + tool_calls | assistant/function_call item |
| Host Context 单独出现 | user message，fenced block | user message | user input item |

OpenAI Chat Completions 的 tool message 只能承载文本，因此工具返回图片要作为后续
user message 发送；这不改变内部 tool result 的消息类型。

---


## 9. 状态消息的缓存和压缩策略

### 9.1 固有能力和动态状态分开缓存

模型请求的上下文顺序建议为：

```text
稳定 system prompt
  → 稳定工具定义
  → 固有能力摘要
  → Host State Snapshot / Delta
  → App Event
  → User Message
```

固有能力摘要放在稳定前缀，状态放在动态后缀。

这样状态变化只影响动态后缀，不会使固有能力的缓存前缀全部失效。

对于 Anthropic 类支持 prompt cache 的协议，稳定能力和工具定义放在 cache marker 之前的稳定段；Host State Message 放在动态段。

当前 AppAgent 的 system prompt 组装位置：

`AppAgent/Sources/Core/Session/LLMExecutor.swift:321`

当前只有 Anthropic mapper 对 cache marker 有实际编码，OpenAI Chat Completions 和 Responses mapper 当前没有编码该 marker。因此不能假设所有 Provider 都有相同的缓存效果，需要分别适配和验证。

### 9.2 为什么不能永久只累积 delta

如果从会话开始一直追加 delta，模型需要不断回看：

```text
Snapshot
  → Delta 1
  → Delta 2
  → Delta 3
  → ...
```

会带来两个问题：

- 上下文不断增长；
- 模型需要自己正确执行大量状态合并。

因此需要检查点策略：

- 初次请求：完整 Snapshot。
- 正常运行：只追加 Delta。
- 到达消息数量或字节阈值：追加新的完整 Snapshot。
- 上下文压缩后：在压缩结果后追加完整 Snapshot。
- 每一轮（用户发一条消息）的第一次请求：完整状态。

每次完整 Snapshot 都是一个新的模型状态检查点。追加检查点后，新的
`modelSeenCursor` 以该 Snapshot 的 cursor 为基线；旧 Delta 可以在上下文压缩时
合并为历史状态摘要，但当前有效状态必须以新的完整 Snapshot 为准。

压缩不能只删除历史 Host Context 而不追加检查点，否则模型可能只剩下无法独立解释的
Delta。压缩流程必须是：

```text
冻结当前 HostStateReporter
  → 压缩旧消息
  → 在压缩结果后追加完整 Host State Snapshot
  → 使用同一请求的成功提交规则推进 cursor
```

### 9.3 UI 不展示 Host State Message

Host State Snapshot 和 Host State Delta：

- 保存在模型逻辑消息历史中；
- 可随 session 快照保存；
- 默认不出现在用户聊天列表；
- 不显示用户气泡；
- 不计入用户输入消息数量；
- 不触发“用户输入”样式；
- 诊断导出时可以作为独立区块查看。

---


## 10. App 自动事件

### 10.1 自动事件与状态增量的关系

App 自动事件同时具有：

- 用户操作来源；
- 业务事件语义；
- 相关状态变化。

推荐使用一条 `hostEvent` 消息承载事件和本次变化，避免同一份变化重复追加：

```json
{
  "messageType": "hostEvent",
  "source": "app",
  "trigger": "user_operation",
  "eventId": "event-1001",
  "sessionId": "session-1",
  "changes": {
    "page": {
      "current": {
        "interaction": {
          "selectedOverlay": {
            "id": "poi_1001",
            "type": "poi_bubble"
          }
        }
      }
    }
  },
  "displayPolicy": "collapsed"
}
```

该事件中携带的变化同时完成：

1. 更新 AppAgent 的 HostStateReporter；
2. 让模型知道用户操作的语义；
3. 作为模型消息历史中的状态变化记录；
4. 作为 UI 的折叠 App 消息。

如果某个状态变化没有业务事件，则只创建隐藏的 Host State Delta，不创建 UI 消息。

### 10.2 UI 展示

App 自动事件默认：

- 不自动展开聊天面板；
- 不自动弹出键盘；
- 不显示成用户气泡；
- 显示为一条弱化的折叠行；
- 点击后展开触发原因和变化字段；
- 与用户消息采用不同颜色和图标。

示意：

```text
┄ App · 用户选中了一个地点，更新了 2 项页面状态    展开
```

### 10.3 允许触发模型的事件

建议允许：

- 用户完成一次搜索；
- 用户选中一个业务对象；
- 用户打开或关闭内容详情；
- 用户完成筛选确认；
- 用户完成路线选择；
- 用户提交动态页面表单；
- 用户明确触发需要 Agent 继续处理的动作。

默认只更新状态、不触发模型：

- 拖动过程；
- 缩放过程；
- GPS 小幅变化；
- 页面滚动；
- 普通 loading；
- 底图渲染完成。

### 10.4 防止工具触发循环

每个 App 状态变化都带来源：

```text
causedBy = user
causedBy = toolCallId
causedBy = system
```

默认规则：

- 用户直接操作：允许触发 App 自动事件。
- Agent 工具造成的状态变化：默认只更新状态，不再次触发模型。
- 如果工具明确声明需要继续处理，由工具结果直接交给当前模型回合。

否则会出现：

```text
模型调用工具
  → 页面变化
  → App 自动事件
  → 模型再次调用工具
  → 页面变化
  → 无限循环
```

---


## 12. 动态页面工作区

### 12.1 两层职责

AppAgent 负责：

- 判断是否需要动态页面；
- 生成页面内容或 H5 资源；
- 生成页面数据模型；
- 关联当前会话；
- 请求展示、更新、关闭页面；
- 记录展示意图。

宿主 App 负责：

- 创建和管理 H5 容器；
- 提供原生底图；
- 控制 H5 协议桥；
- 限制 H5 响应区域；
- 提供原生关闭、返回、收起按钮；
- 管理页面实例；
- 管理内存；
- 执行页面重建。

宿主页面控制器可以为每个 session 缓存一个 placeholder：

宿主自己的页面控制器实现位置。

它需要扩展为 `HostWorkspaceController`。

### 12.2 页面工作区状态

```json
{
  "workspaceId": "workspace-1",
  "sessionId": "session-1",
  "displayIntent": "visible",
  "actualVisible": true,
  "instanceState": "loaded",
  "contentVersion": "content-hash",
  "recoverableState": {
    "selectedItemId": "item-1",
    "scrollPosition": 120
  }
}
```

字段含义：

- `displayIntent`：用户或 Agent 希望页面是否展示。
- `actualVisible`：页面当前是否真的在前台显示。
- `instanceState`：WebView 和控制器是否仍在内存。
- `contentVersion`：页面内容版本。
- `recoverableState`：释放页面实例后重新构建所需的数据。

### 12.3 工作区状态如何进入模型历史

动态页面工作区状态也遵守 Host Context Message 规则：

- 会话首次创建动态页面时，附带完整 workspace snapshot；
- 后续用户在动态页面中产生重要交互时，追加 workspace delta；
- 普通滚动和高频 UI 变化默认只更新 HostStateReporter；
- 下一次模型请求前，将未被模型看到的 workspace delta 发送给模型；
- 页面被释放后，工作区可恢复状态仍保留，WebView 本身不保留在内存消息中。

工作区状态默认不显示为用户气泡。

### 12.4 页面切换

切换到其他会话：

1. 当前工作区从前台移除。
2. 不自动修改原会话的 `displayIntent`。
3. 读取目标会话的 `displayIntent`。
4. 如果目标会话上次是 visible，则恢复展示。
5. 如果目标会话已被用户关闭，则保持收起。

### 12.5 用户关闭

用户点击返回、收起或关闭时：

```text
displayIntent = collapsed
actualVisible = false
```

页面实例默认不立即释放，只从前台移除。

### 12.6 Agent 调起原生页面

如果 Agent 调起内容详情、导航、搜索或其他原生页面：

```text
displayIntent = collapsed
actualVisible = false
```

动态页面实例可以暂时保留。

### 12.7 H5 和底图

推荐结构：

```text
原生工作区容器
  ├─ 原生底图
  ├─ H5 WebView
  └─ 原生关闭/返回按钮
```

H5 通过白名单协议声明响应区域。宿主校验区域后才允许触摸分发，区域外可以透传到底图。

不能依赖：

- 网页透明背景；
- CSS 透传；
- 任意 JS 调宿主；
- 任意反射调用。

页面临时对象需要按 `workspaceId` 隔离，页面收起时解绑该工作区订阅和临时对象。

### 12.8 内存回收

```text
正常运行：
  关闭页面后保留实例

第一次内存告警：
  回收最久未使用的后台实例
  后台最多保留一个实例

再次收到内存告警：
  回收所有后台实例

前台页面：
  不因为后台回收策略被误关
```

回收：

- WebView；
- 页面控制器；
- 页面临时对象；
- 图片缓存；
- 订阅。

不回收：

- 会话；
- 页面内容版本；
- 结构化页面数据；
- `displayIntent`；
- `recoverableState`。

---


## 14. AppAgent 层实施清单

### 14.1 协议

```swift
public protocol HostStateProvider: Sendable {
    func currentState() async throws -> [String: String]
    func fieldDescriptions() async -> [String: String]   // 可选，默认空
}
```

一般不用自己实现，直接用 SDK 提供的 `HostStateStore`（`@objc`，OC 可直接用，任意线程读写）：

```swift
let store = HostStateStore()
store.setField("BMPoiDetailPage", forKey: "page.top")        // 状态变了就写
store.setDescription("当前最上层页面", forKey: "page.top")   // 可选：字段含义
store.postEvent(trigger: "tap", action: "open-detail", detail: "poi=123")
try await session.installHostStateProvider(store)
```

- **key 和含义由宿主自己定义**。key 本身看得懂的不用写说明；看不懂的用 `setDescription` 写一句，
  它只随完整状态发给模型。
- **事件**不是状态，比对不出来，由 `postEvent` 告诉 SDK，随下一帧发出、只发一次。
  自己实现来源的宿主可以调 `session.hostStateReporter.post(_:)`。
- **`app_state` 工具**读的也是这个来源（`AppStateTool()`），宿主不用再实现第二个接口。

消息里的类型：`HostState`（全量）、`HostStateChange`（变化）、`HostEvent`（事件），
都包在 `HostContextPayload` 里。

线程约定（宿主实现工具与 provider 时必须遵守）：

- AppAgent 从非隔离的子任务调用 `ToolProtocol.execute`、`HostStateProvider.currentState()` 和
  `ToolExecutionGate`，它们跑在 Swift 并发线程池上，**不保证主线程**；`.safe` 工具还可能并行执行。
- `currentState()` 每次请求模型前都会被调用，应该只拷贝已经存好的状态。只能在主线程读到的状态
  （UIKit、地图视图、页面栈）由宿主在变化发生时（本来就在主线程）写进 store，不要在 `currentState()` 里切主线程现算。
- 工具需要主线程时把 `execute` 写成 `@MainActor`；宿主的 ObjC 桥建议用 `NS_SWIFT_UI_ACTOR` 标注。
- 主线程上只做读写宿主状态和组装结果；CPU 重的同步计算放进非隔离的 async 函数。

### 14.2 HostStateReporter

`HostStateReporter`（每个会话一份）负责：

- 每次请求前读宿主（带超时），截断超长字段；
- 和 `modelSeenFields` 比对，生成全量 / 变化 / 事件帧；
- 收宿主事件、去重；
- prepare / commit / discard 提交边界。

`HostStateReporter` 不负责启动模型请求。模型触发由 session executor 和显式事件决定。

### 14.3 模型请求前注入

当前易变上下文只在首次模型请求注入，位置为：

`AppAgent/Sources/Core/Session/LLMExecutor.swift:1410`

需要改为：

```text
每次 provider 请求前：
  1. 读取当前 HostStateReporter。
  2. 判断模型已看到的 cursor。
  3. 追加未发送的 Host State Snapshot/Delta。
  4. 再发送本轮用户消息、App 事件或工具续行。
```

请求上下文的生命周期必须有明确的 prepare/commit 两步：

- prepare 只生成待发送上下文，不改变 session；
- provider 完整成功后 commit `modelSeenCursor`；
- 失败、取消、解析异常时丢弃 pending 结果，但保留未确认状态；
- 同一个 user turn 的重试不得重复追加原始用户消息。

### 14.4 消息模型

当前消息模型只有 user/assistant，位置为：

`AppAgent/Sources/Core/Message/AIAgentMessage.swift:10`

需要增加：

- messageType；
- source；
- displayPolicy；
- trigger；
- eventId；
- causedByToolCallId。

消息模型必须继续 Codable 和 Sendable，并为旧有 user/assistant/tool 内容提供单一
明确的构造入口。新代码不得通过“role 是 user 且 content 是 text”推断真实用户输入。

### 14.5 UI

`ChatMessageAssembler` 需要支持：

- 用户消息；
- Agent 回复；
- App 折叠事件；
- 工具过程；
- 隐藏 Host Context Message 不生成气泡。

App 自动事件不应依赖 `.user` role 判断。

---


## 16. 持久化和内存归属

| 数据 | 所在位置 | 是否落盘 |
|---|---|---|
| 固有能力 Manifest | App Bundle | 是 |
| Manifest 热点索引 | AppAgent 缓存 | 可清理落盘 |
| 当前 App 状态 | 宿主内存 | 否 |
| AppAgent HostStateReporter | AppAgent 内存 | 否 |
| 用户真实消息 | AppAgent session storage | 是 |
| Agent 回复和工具往返 | AppAgent session storage | 是 |
| Host State Snapshot/Delta | 模型逻辑消息历史 | 是，随 session |
| 高频未触发事件的 delta | AppAgent 内存 | 否 |
| App 自动事件 | AppAgent session storage | 是 |
| 动态页面 H5 资源 | App 沙箱/Application Support | 是 |
| 动态页面恢复状态 | App 沙箱/Application Support | 是 |
| WebView、控制器、页面临时对象 | 内存 | 否 |
| 宿主服务任务快照 | 服务端数据库 | 是 |

关键原则：

> 模型消息历史保存的是模型理解所需的状态事实；AppAgent 的 HostStateReporter 保存最新读到的状态；宿主保存的是页面和动态工作区的可恢复事实；模型缓存不承担持久化职责。

---


## 17. 推荐端到端时序

### 17.1 新会话首次提问

```text
用户打开 AppAgent
  → 创建/恢复 session
  → AppAgent 向宿主获取完整 Host State Snapshot
  → 追加隐藏 Host State Snapshot
  → 追加用户消息
  → 请求模型
  → 保存模型逻辑消息历史
  → UI 只展示用户消息和 Agent 回复
```

### 17.2 普通页面状态变化

```text
用户拖动页面
  → App 发布多次 map.viewportBounds 变化
  → AppAgent 合并到 HostStateReporter
  → 不触发模型

用户随后提问
  → 计算 modelSeenCursor 之后的增量
  → 追加 Host State Delta
  → 追加用户消息
  → 请求模型
```

### 17.3 App 自动事件

```text
用户点击内容卡片
  → App 更新页面 interaction
  → App 发布 hostEvent(selected_poi)
  → AppAgent 合并 HostStateReporter
  → 追加 hostEvent 消息
  → UI 展示折叠的 App 消息
  → 请求模型
```

### 17.4 Agent 工具造成页面变化

```text
模型调用 app_navigate
  → App 执行页面跳转
  → App 更新页面状态
  → AppAgent 更新 HostStateReporter
  → 工具结果返回模型
  → 下一次模型请求前附带 Host State Delta
  → 默认不再创建新的 App 自动事件
```

### 17.5 会话恢复

```text
AppAgent 恢复历史 session
  → 历史 Host Context 仅作为历史参考
  → 向宿主重新获取当前完整快照
  → 追加新的 Host State Snapshot
  → 再处理下一条用户消息
```

不能把历史保存的页面状态直接当成 App 当前事实。

---


## 18. 关键风险和约束

### 18.1 不要把 Host Context 当用户消息

如果模型逻辑消息和 UI 消息都只按 role 判断，会导致：

- Host State Delta 出现为蓝色用户气泡；
- App 自动事件被误认为用户直接输入；
- 工具结果被错误展示成用户消息。

必须使用内部 `messageType/source/displayPolicy`。

### 18.2 不要把每次状态变化立即触发模型

拖动、定位、滚动等变化频率很高。状态发布、状态合并、模型触发必须解耦。

### 18.3 不要把完整状态重复发送

首次完整快照后，正常只发送尚未被模型看到的增量。定期或在恢复/压缩时发送完整检查点。

### 18.4 不要用 App build 作为能力缓存版本

App build 只用于诊断。能力缓存使用语义内容 hash。

### 18.5 不要把旧 session 状态当当前事实

恢复会话后必须重新从宿主获取当前快照。

### 18.6 不要让 App 自动事件和工具状态变化互相触发

所有状态变化必须记录来源，默认禁止 tool-caused 状态变化再次自动启动模型。

---


## 20. 最终方案摘要

最终采用以下规则：

1. 固有能力摘要进入稳定 system prompt。
2. 正式能力进入 tools。
3. 详细技术结构进入按需检索文档。
4. 当前页面状态和动态页面工作区状态进入模型逻辑消息历史，但不进入用户可见气泡列表。
5. 新会话首次请求发送完整状态快照。
6. 后续每次向模型发送新请求前，发送上次模型已看到状态之后的增量。
7. 状态变化不自动触发模型；固定语义用户操作才生成 App 自动事件。
8. App 自动事件进入模型历史，也进入 UI，但 UI 以折叠 App 消息展示。
9. 宿主状态只以「字段 → 文本」进入消息，比对在 SDK 内完成，不进入 system prompt。
10. `appBuild` 只用于诊断，不参与能力缓存。
11. 页面是状态第一归属单位，业务状态隶属于页面。
12. 页面只保留业务方声明的最小状态和选中引用，不复制完整业务对象详情。
13. 动态页面的展示意图、实际显隐和内存实例分离管理。
14. AppAgent 的 HostStateReporter 负责汇报状态，宿主 App 维护运行事实，宿主服务只保存任务所需快照。
