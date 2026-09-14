# AppAgent 优化计划

> 2026-06-13 基于完整代码走读产出（覆盖全部 Sources / Tests / docs / Package / Podspec，
> 并已验证 swift build 与 swift test 通过，62 用例全绿）。
> 优先级：P0 = 必须尽快修，P1 = 近期修，P2 = 排期修。

---

## 0. 安全（最高优先级）

- [ ] **P0** 历史提交中曾包含 demo 真实 API key。
  根因：早期 demo 配置路径在 Examples/iOS/config.json 与 Examples/iOS/Resources/config.json 之间漂移，
  工程引用、文档说明和 .gitignore 未保持一致。当前约定路径为 Examples/iOS/Resources/config.json，
  并同时忽略旧根目录路径以防本地残留误提交。
  处理步骤：
  1. 立即轮换该 key；
  2. 确认真实配置不再被 Xcode 工程硬引用，也不进入 git 索引；
  3. 如果仓库已推送或将来开源，必须用 git filter-repo 清理历史，该 key 一律视为已泄露。

## 一、方向性优化

1. **把差异化做厚**：通用 chat+tools agent loop 是红海，AppAgent 的护城河是“agent 操作宿主 App”
   （app_action / app_navigate / app_state 三个注入协议 + 可穿透 AppAgentWindow 浮层）。
   主线 demo 应直接演示“一句话 → agent 跳页 / 执行业务动作”，而不是又一个聊天框。
2. **Provider 路线收敛**：下一个 provider 做 OpenAI-compatible 一种，即可覆盖
   OpenAI / DeepSeek / Qwen / Ollama / vLLM 及绝大多数网关；不要逐个实现 APIProtocol 的 9 种协议。
   同时实现 ModelPolicy.fallbacks（ErrorClassifier 已输出降级建议，LLMExecutor 尚未消费）。
3. **多模态**：ModelSpec 声明了 image 输入，但 AIAgentMessage.Content 没有 image case。
   “截屏给 agent 看当前界面”与“操作 App”主线天然互补，优先级应提前。
4. **授权 / 澄清 UX 产品化**：sensitive/dangerous 工具授权（delegate 回调）和 clarify 工具
   目前都要宿主自己做 UI。把“确认弹层 + 澄清问答”内置进 AppAgentUI 的 overlay。
5. **定发布姿态**：README 的 anthropics org、from 1.0.0，podspec 的 github.com/user/AppAgent
   均为占位；版本实际 0.1.0。开源或内部交付二选一，并建立小步提交习惯。

## 二、结构性优化

1. **Package 拆分**：README/podspec 宣称 AppAgentCore / AppAgentUI 两模块，实际只有单 target AppAgent。
   应拆为 Core（仅 Foundation）+ UI（依赖 Core）两个 target/product。
2. **Podspec 修复**：source_files 路径 Sources/AppAgent/**/*.swift 不存在（实际 Sources/Core、Sources/UI），
   按现状打包为空；宣称的 subspec 未定义；frameworks 无条件含 UIKit 与“Core 零 UI 依赖”矛盾。
3. **文档一体化**：README + 全部 5 篇 docs 引用已不存在的 API（LLMProvider / ProviderConfiguration /
   ChatViewController / .textDelta 事件）；CLAUDE.md UI 章节（3 文件）落后于实际（8 文件 overlay）。
   Quick Start 代码改为从 Examples 抽取，CI 增加“编译文档示例”步骤防漂移。
4. **历史与发送视图分离**：SimpleContextCompressor 直接改写 currentMessages 且 completed 时写回 session
   → 压缩触发后原始历史被永久覆盖。压缩应移到 prepareMessagesForProvider 同层（只影响发给 provider 的视图）。
5. **并发模型演进**：核心类均为 @unchecked Sendable + 自制锁。先开 -strict-concurrency=complete 作 warning
   基线；长期把 LLMExecutor 改为 actor。
6. **引擎层测试基建（回报率最高）**：现有 62 测试全是数据结构/注册中心/存储，LLMExecutor.runLoop 零覆盖。
   建脚本化 MockModelProvider，覆盖：单轮、工具循环、并行工具、超时、取消、重试耗尽、loop detector、压缩、maxIterations。

## 三、实现细节（按严重度）

| # | 级别 | 问题 | 位置 |
|---|------|------|------|
| 1 | P0 | run() 创建的 Task 从未存入 _runTask：isRunning 恒 false、cancel() 无效、同 session 并发 run 会交错写历史 | LLMExecutor.run() |
| 2 | P0 | 错误路径不调 setStreaming(false)/setError，UI 永久转圈；currentMessages 不写回，留悬空 user 消息。建议 runLoop 顶部 defer 统一收尾 | LLMExecutor.runLoop() |
| 3 | P1 | AsyncThrowingStream 未设 onTermination，消费方取消后 SSE 仍读完整响应，白烧 token；循环内未检查 Task.isCancelled | AnthropicProvider |
| 4 | P1 | ToolLoopDetector warning 分支 yield 了 toolCallStarted 却无 completed/failed，UI 卡“进行中” | LLMExecutor |
| 5 | P2 | createSession 与 resolveProvider() 重复解析逻辑；resolveDefault() 按枚举顺序挑 provider，多 provider 行为不可预期 | AIAgent / ModelProviderCentral |
| 6 | P2 | 请求 max_tokens 直接用 ModelSpec.maxTokens（默认 64000），不支持的模型会 400；应区分上限与单次请求值 | AnthropicProvider |
| 7 | P2 | executeSingleTool 把全部入参 key=value 打日志（clipboard/memory 内容入日志），需验证脱敏覆盖 | LLMExecutor |
| 8 | P2 | 工具超时是 TaskGroup race 非真取消，不配合取消的工具会后台继续；文档写明需 cooperative cancellation | LLMExecutor |
| 9 | P2 | 口径统一：Package iOS13 / README iOS15 / CLAUDE.md iOS13；README from 1.0.0 vs 实际 0.1.0 | 多处 |

## 四、建议落地顺序

1. 第一周：处理密钥与 git 历史；修 #1 #2 两个 P0；搭 MockProvider 把执行循环测试钉死。
2. 第二周：拆 Core/UI target；修 podspec；重写 README 与 docs；将 overlay 重构分批提交。
3. 之后：OpenAI-compatible provider + fallback 闭环；image content；授权确认 UI。

## 附录：已完成

- 2026-06-13 输入框拖拽收展手势重构：松手吸附改为「甩动阈值 + 惯性投影 + 中线吸附」三层判定，
  弹簧动画继承手指速度；“手势位移 → 尺寸”换算抽离为
  AppAgentViewController.applyPanTranslationToInputBar(translationX:)（逐行注释）。
- 2026-06-14 发布口径修正：以当前 Package.swift 的单 product/target `AppAgent` 和实际目录
  `Sources/Core`、`Sources/UI` 为准，重写 README 与 docs 下 GettingStarted / Architecture /
  Providers / Tools / UICustomization，修正 Podspec 的 `source_files`、平台、Swift 版本和 framework 声明。
