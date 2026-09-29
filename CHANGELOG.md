# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

