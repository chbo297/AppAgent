# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Changed
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
