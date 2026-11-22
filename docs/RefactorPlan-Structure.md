# 结构维护约束与后续拆分

> 2026-11-04 复核。这里只保留仍有效的结构决定；原方案中的旧行号、预估体量、
> 已被替换的 TurnReporter/StreamAttempt 草案和重复执行记录已移除。
> 当前问题与修复进度统一见 [OptimizationPlan.md](OptimizationPlan.md)。

## 当前结构

- `Core/Session/TurnJournal.swift`：一轮状态与终止事件的唯一出口。
- `Core/Session/RunLoopState.swift`：执行循环的局部状态。
- `Core/Session/ModelSwitchStep.swift` 与 `LLMExecutor.switchToNextModel`：错误回退和协议异常共用换模型逻辑。
- `Core/Providers/ToolSchemaMapper.swift`：三种线协议共用工具输入 Schema 编码。
- `UI/AppAgentViewController/`：主控制器按职责分片；刷新原因由 `AppAgentChatReloadReason` 明确表达。

这些拆分已经存在，不应再作为待实现任务。文件职责见 [FileMap.md](FileMap.md)。

## 必须保留的执行契约

| 约束 | 原因与依据 |
|---|---|
| 每轮恰好一个 `.completed` / `.error`，只走 TurnJournal | 漏发让 UI 一直转圈；重复发让同一轮被收两次。见 [TurnLifecycle.md](TurnLifecycle.md) |
| UI 只允许 active run 更新；旧轮记录和调用方终止事件仍须完成 | 被新轮替代不代表旧调用方失去结果；旧轮也不能覆盖新轮 UI |
| 失败保留失败阶段，取消使用取消终局 | 避免错误显示为正常完成；见 `TurnJournal.failed` |
| 收尾顺序是 finalize → clear task → finish stream | 提前摘 task 会使最后一次 UI 清理失去 active 身份 |
| delta 顺序是 yield → stage → append | 改顺序会改变首个流式刷新看到的内容 |
| turnID 显式传递；不重读可能已更新的 currentTurnID | 防止旧任务把结果写进新轮 |
| 重试/回退丢弃失败尝试的正文和未执行调用 | `LLMStreamFailureTests` 覆盖；不能把不同尝试拼成一次回答 |
| 压缩只改 provider 视图，不覆盖原始聊天历史 | `CoreConcurrencyAuditTests` 覆盖成功、失败及工具续行 |
| 中间持久化节流，终局强制保存 | 避免逐 token 写盘，又不丢最终状态 |
| stop=tool_use 但无调用是协议异常 | 先尝试可用 fallback，用尽后报错，不能当空回答完成 |

UI 的稳定身份、行高与键盘几何约束统一放在 [UILayer.md](UILayer.md)，这里不重复。

## 候选优化（尚未实施）

1. **ToolRunner**：若工具执行门禁、授权和预算继续增长，再提取独立执行单元。
   前提是工具结果顺序、safe 并发/写串行、取消与授权责任链保持不变。
2. **输入栏 pan 状态机**：可提取纯状态转换，但手势阈值、速度投影和坐标关系保持不变；
   需要状态机回归加真机触摸验收，不能只用编译通过代替。
3. **运行时内省的值解析/selector 闸门**：只有被多处复用时才提取；不按文件行数拆分。

暂不抽 `StreamAttempt`：当前流消费、重试与 Host Context 提交共享多项状态，
直接搬成多参数函数不会形成独立边界；已有 `ModelSwitchOutcome` 表达换模型结果。
只有依赖边界先变清楚，才重新评估。

暂不拆 SwiftPM Core/UI 产品，也不恢复 CocoaPods；它们会改变集成与发布设计，
本轮审计保持现有单产品结构。依赖与发布顺序见 [Dependencies.md](Dependencies.md)。

## 验证口径

- Core 变更：有缺陷的针对性回归先失败，再执行 `swift test`。
- UIKit 变更：Catalyst 全量测试与 Demo 构建；系统手势/麦克风/后台挂起另做运行时验收。
- 测试数量、文件行数以本轮日志和实际目录为准，不在多份文档复制静态快照。
