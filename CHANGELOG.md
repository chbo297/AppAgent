# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added
- `app_web_inspect` 正式 `highlight` / `clear_highlight`：原生透传红框、滚动/布局跟随与导航/离屏清理，
  支持同源 iframe / open shadow 路径、节点 attributes 和坐标说明；补充真实 WKWebView 回归测试。
- 通用 `ToolExecutionGate` 与 `AIAgentProfile.toolExecutionGate`（默认 nil，运行时依赖、不持久化）：
  授权前和执行前检查完整工具参数；拒绝作为工具错误，不申请授权、不执行。
  子任务继承父 gate，发送任务前调用 `prepareDelegation`，供宿主固定子任务权限上限。

### Changed
- `app_action` 的常规宿主动作改为 `.moderate`，与模拟用户操作、公开 OpenAPI 导航一致，默认无需 SDK 授权确认；保留只读限制与宿主执行门禁。
- Responses 流失败保留上游 type/code/message，接入既有有界重试与模型回退；未知流错误不默认重试。
  失败、不完整响应及 `[DONE]` 不再输出待执行工具调用，完整响应也拒绝损坏的工具参数。
- `app_hook_capture` 不再内置业务桥通道或错误码集合；通道名、字段语义和脱敏规则由宿主定义，
  SDK 只提供安全通道名校验、配置切换、文件读取、游标过滤和有界输出。
- 清理 Host Capability、WebInspect、HostContext 与示例中的具体宿主命名，通用 SDK 不再依赖某个
  App 的桥框架、页面容器或后台服务。
- WebInspect 容器使用 selector associated-object UUID；所有 Provider 方法新增 `HostInspectionContext`，
  接入 scene/scope/readOnly/gate，无可见页不回退隐藏页；任意 `eval` 提升为 sensitive。
- WebInspect 参数预检拒绝空目标、错误类型、非法枚举与数值溢出，预算使用精确整数转换；
  原生标注共享持有 isolated world，补充无 scene 的真实 WebKit 测试入口、迟到结果及释放回归。
- 模型诊断日志按请求 ID 关联完整请求体与解析前响应文本，长报文分块保存并强制脱敏；
  补齐 EOF 尾帧、HTTP 错误正文和未知格式记录，修复同秒轮转复用文件及协议异常误记 SUCCESS。
- 会话内直接调用宿主能力的写操作也检查 gate，缺少已安装工具时拒绝；作用域授权后重新检查。
- UI 语义激活拒绝隐藏、透明、禁用的目标及祖先；检查视图的读取路径仍可访问这些目标。
- 属性观察改为按运行时声明直接读取 getter/ivar，保留明确允许的 UIKit 只读 getter；
  所有 scope 拒绝把普通方法或 KVC 的 `get<Key>` 猜测当成属性，堵住 `.safe` 读取的副作用入口。
- `AppNavigationProvider.navigate` 保留 Void API，正常返回仅承诺请求已受理/提交；
  `app_navigate` 返回 `submitted: true`、`completion: "unconfirmed"` 与明确的提交文案，
  `success` 仅表示提交成功，不再声称页面已呈现。提交后不得仅因呈现未确认而抛错，避免诱导重复请求。
- Endpoint Settings 默认地址、密钥、请求头和模型列表均为空，移除 `oneAPIDefault`、
  `oneAPIBaseURL` 和 `defaultOneAPIHeaders`；宿主须显式提供自己的接入配置。
- 设置页保存、模型探查与 Provider 构造统一校验 HTTP(S) 根地址、非空 API Key 和模型 id，
  请求与模型引用使用去除首尾空白后的值；任一启用模型 id 为空即拒绝整份配置。
- 无效配置不生成 Provider / ModelPolicy；应用或注册设置会清理旧的 Settings Provider，
  保留宿主自行注册的其他 Provider。

## [0.0.2] - 2026-09-30

### Added
- Overlay 可作为「常驻悬浮入口」：`AppAgentOverlay.start(startCollapsed:)` 让首帧以收起态胶囊落位，
  `AppAgentViewController.setInputBarCollapsed(_:animated:)` 供宿主运行时收 / 展输入栏（默认展开，行为不变）。

### Removed
- 移除残留的 CocoaPods 支持，只保留 SwiftPM（原因见 `docs/Dependencies.md`）。

## [0.0.1] - 2026-09-29

首个打包发布的版本。此前仓库只在本地开发，从未打过 tag；`0.1.0` 那条旧条目描述的是一套
已经被整体替换掉的 API（`LLMProvider` / `AIAgentLoop` / `ToolRegistry` / `ChatViewController`），
因为从未发布，直接由本条目取代。

### Added
- `AIAgent` 门面 + `AISession` / `AISessionManager` 多会话管理，`FileSessionStorage` 持久化
- `ModelProvider` 协议与 Anthropic 实现（SSE 流式走 `URLSession.bytes`），
  `ModelProviderCentral` 按 `"providerName/modelId"` 解析，`ModelPolicy` 支持 primary + fallbacks
- `LLMExecutor`：provider ↔ tool 循环，每轮恰好一个终止事件，状态唯一真相是 `AIAgentTurnRecord`
- `ToolProtocol` + `ToolCentral`（共享实例 / per-session 工厂），21 个内置工具；
  `Tool.SafetyLevel` op 级授权、输出预算、`preflightRejection` 授权前置校验
- 宿主能力工具：运行时内省（含 `view_activate` / `page_navigate` / `page_scroll`）、
  热修复、消息捕获、WebView 内省，协议 + 默认实现都可替换
- Memory（长期 + 热记忆）与 Skills（markdown + YAML frontmatter）
- UIKit overlay UI：`AppAgentOverlay` 穿透窗口 + `AppAgentViewController` 对话面板，
  决策卡片在面板内呈现，`AppAgentPresentationDelegate` 向宿主上报展示位置与遮挡区域
- 诊断：落盘日志、诊断包导出、模拟器能力自检脚本
- Swift 6 语言模式；Swift Package Manager 接入（不提供 CocoaPods：依赖的 BOUIKit / BODragScroll 2.2.1 未上 CocoaPods trunk）
