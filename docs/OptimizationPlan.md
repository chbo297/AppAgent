# 项目审计与维护计划

> 2026-11-04。以当前源码、失败回归和本轮验证为依据；取代 6 月计划中已经过时的
> CocoaPods、未实现 fallback、缺少授权 UI、执行循环零覆盖等条目。

本轮优先处理会丢历史、漏消息、绕过授权、让旧任务污染新界面的问题，同时精简重复实现和过期文档。
修复保持现有单 SwiftPM 产品、宿主扩展边界、UI 外观与工具授权设计。下表的“已修复”代表代码与回归已落地；
编译、自动化测试、真实网络及设备手工验收分别记录，不相互替代。

## 已落地修复

### 会话、执行与状态

| 问题与影响 | 修复方案 | 依据与回归 |
|---|---|---|
| 上下文压缩永久覆盖聊天历史，成功或失败都会丢原文 | 只压缩 provider 消息视图，持久历史保持完整 | `LLMExecutor.runLoop`；`CoreConcurrencyAuditTests.testCompressionPreservesCompleteSessionHistoryOnSuccessAndFailure` |
| 多线程追加用户消息发生读改写覆盖 | 对消息数组原子追加 | `AISession.addUserMessage`；200 路追加回归，修前一次仅保留 49 条 |
| 并发检查与启动分离，突破 9 路上限 | manager 内串行完成准入与同步启动 | `AISessionManager.startRunIfAdmitted`；48 路同时启动，修前实测 14/9，修后 9/9 |
| 旧流取消清掉新轮运行 UI；准备前抢占误报内部失败 | 取消绑定 run 身份，早期退出明确报告取消，异步准备后重验身份 | `LLMExecutor.cancel/run`；`CoreConcurrencyAuditTests` 两条取消回归 |
| 嵌套 JSON 的字典顺序绕过循环检测，ABBA 被误报为 ABAB | 按 JSON 值等价比较，只接受方向一致的交替对 | `ToolLoopDetector`；嵌套对象与乒乓检测回归 |
| 注入消息上下文时丢失来源、展示策略等元数据 | 重建时保留全部消息字段 | `LLMExecutor.prepareMessagesForProvider`；消息身份与宿主元数据回归 |
| 宿主状态流静默等待时一直持有宿主状态汇报器，无法释放 | 增量流已移除；事件消费者只弱引用 reporter，store 不持有 reporter | `HostStateReporter.startEventConsumerIfNeeded/deinit`；`HostStateReporterTests.testReporterIsNotRetainedByStore` |

### 工具、存储与 Provider

| 问题与影响 | 修复方案 | 依据与回归 |
|---|---|---|
| 朗读等待不响应取消，模拟器冷启动时拖住超时收尾 | 一次性终态恢复等待者，合成器在 MainActor 启停，取消抛错并丢弃迟到完成 | `TextToSpeechTool`；`TextToSpeechCancellationTests` 三条回归，修前预取消超过 1 秒仍未退出 |
| 非有限值、溢出、小数被直接转整数，可能崩溃；文件分页还有负切片和加法溢出 | 共用有限、精确整数与区间校验，分页先限定起点再算剩余长度 | `ToolArgumentValues`、`FileTool.read`；`ToolsStorageRegressionTests` 数值边界回归 |
| `web_fetch` 自动重定向绕过目标私网授权 | 最多 20 跳显式跟随，每跳重验目标 host | `WebFetchTool.perform/authorizedURL`；模拟传输及真实 HTTPServer 均验证 |
| 私网识别漏掉 IPv6、映射 IPv4、短写/八进制/十六进制 IPv4 和尾点 localhost | 按地址字节与规范化主机名分类 | `WebFetchTool.isPrivateHost`；另类地址回归 |
| 按字节切中文可能生成替换字符 | 回退到完整 UTF-8 边界后裁剪 | `WebFetchTool.clip`；中文截断回归 |
| 文件搜索声明支持的 ? 与中间 * 实际不匹配 | 实现完整的这两种通配符，保留普通名称子串查询 | `FileTool.matchGlob`；组合通配符回归 |
| 技能描述内 --- 提前结束 frontmatter，带引号的名称不能正常查找 | 只认独立分隔行，解析引号元数据并保留正文 CRLF | `SkillsManager.parseSkillFile`；分隔符及引号/换行回归 |
| 记忆读取 await 后旧缓存覆盖新增/删除；读取失败被永久缓存为空 | generation 隔离迟到读取，失败不缓存，循环响应取消 | `MemoryStore.loadCached`；延迟读取与瞬态失败回归 |
| 记忆禁用仍报保存成功，负查询/注入上限会崩溃 | 明确返回禁用错误，非正上限返回空结果 | `MemoryTool`、`MemoryStore`；禁用与负限额回归 |
| Anthropic/Chat Completions 损坏参数被替换成空对象并执行；Chat 的 DONE 还会释放未完成调用 | 损坏或非对象参数抛解码错误；Chat 只在工具 finish reason 下提交调用 | `ProviderToolArgumentTests`；修前 3 条用例有 10 个失败断言 |
| SSE 字段冒号后没有空格时事件和 DONE 被丢弃 | 接受有/无一个可选分隔空格，保留 payload 其余空白 | `SSEParser`；`testSSEParserAcceptsFieldsWithoutSpaceAndPreservesPayloadWhitespace` |
| 非正 token 配置可通过 usable 校验，随后构造 Provider 触发断言；非法超时转换溢出 | 配置与探测入口校验 token 上限及可表示超时 | `AppAgentEndpointSettings`、`AppAgentModelDiscovery`；`EndpointValidationAuditTests` |
| 以 / 开头的错误模型引用被当成正常 provider/model | 分割时保留空组件并拒绝；模型 id 内的 / 仍支持 | `ModelProviderCentral.resolve`；模型引用回归 |

### UIKit 与 Demo

| 问题与影响 | 修复方案 | 依据与回归 |
|---|---|---|
| 流任务持有聊天控制器，界面销毁与授权收尾无法发生 | 每个事件内弱持有界面，销毁时取消消费者 | `AppAgentViewController+SessionBinding`；`AppAgentViewControllerLifecycleTests` |
| agent 换绑后旧观察、旧请求及异步完成仍可能写新界面 | 解绑、取消、结清旧决策；异步返回核对所属 agent | `AppAgentViewController` 与 ChatPanel/SessionSidebar 分片；换绑回归 |
| 全局授权 presenter 接走其它 agent 的请求后永久排队 | 只接收所属 agent 的会话，后台会话仍正常排队 | `enqueueDecision`；决策归属回归 |
| 语音取消/收尾后马上开始，旧识别事件会关闭新面板或发送旧文本 | 切断旧消费者并忽略取消后的事件，保留正常预热复用 | `AppAgentVoiceInputCoordinator`；两条重启回归 |
| 清历史后 turnID 复用，旧展开选择套到新轮；换展示代理吞掉首通知 | 用 startedAt 隔离轮次状态；按观察者身份重置去重缓存 | `AppAgentSessionActivityTests`、`AppAgentChatPanelGeometryTests` |
| 设置页编辑地址/Key 或关闭后，旧探查会写回模型、失败提示和可用绿灯 | 取消旧任务并按探查 generation 隔离所有结果，编辑后状态恢复未实测 | `AppAgentSettingsViewController`；`AppAgentSettingsProbeLifecycleTests` 三条可控等待回归 |
| Demo 仍声称自动使用内置默认端点配置 | 改为完整配置校验及未配置提示 | `Examples/iOS/Sources/SceneDelegate.swift`；Demo 构建验证 |

## 精简与文档校正

- 三种协议中逐份复制的工具 Schema 编码合并到 `Core/Providers/ToolSchemaMapper.swift`。
  `ToolSchemaMappingTests` 验证嵌套类型、默认值、required 与协议专属 cache metadata 保持一致。
- `RefactorPlan-Structure.md` 从旧方案/废弃接口/重复执行记录收拢为当前结构、执行契约和候选拆分。
- GettingStarted、CONTRIBUTING 的最低要求统一为 Swift 6 / iOS、Catalyst 15 / macOS 12；
  更正不存在的 Demo scheme、旧 Provider/Tool 协议名和 UI 文件路径。
- Architecture 说明 Objective-C 辅助 target；Providers 补三种线协议及 reasoning 事件；
  FileMap 去掉易漂移的文件计数，补共用 Schema 与第四个宿主能力工具。
- 模拟器自检更新未知 key 的受限作用域拒绝断言；激活改用独立可见临时目标，并新增隐藏目标拒绝回归。
- HostContext 保留既有完整设计，补实现与设计的阅读边界；不因篇幅大而删除协议依据。

## 验证结果

本轮新增 **46 条回归测试**，最后一轮结果如下：

| 检查 | 结果 | 日志 / 产物 |
|---|---|---|
| `swift build` | 通过，无 Swift 编译警告 | `/tmp/appagent-audit-build.log` |
| `swift test` | 400 项，1 跳过，0 失败 | `/tmp/appagent-audit-core-final.log` |
| Catalyst Core + UIKit 全量 | 689 项，1 跳过，0 失败 | `/tmp/appagent-audit-catalyst-final.log` |
| Catalyst Demo 构建 | BUILD SUCCEEDED | `/tmp/appagent-audit-demo-final.log` |
| iOS Simulator Demo 构建 + 运行时工具自检 | 179/179，fail=0，10.5 秒；使用原 60 秒报告预算 | `/tmp/appagent-audit-simulator-build.log`、`/tmp/appagent-audit-selfcheck-report.txt` |
| 真实 HTTP 重定向授权 | 新私网 host 拒绝时未请求目标；允许与同 host 复用均成功 | `/tmp/appagent-real-redirect-result.log`、`/tmp/appagent-real-redirect-allow-result.log` |
| 文档相对链接 / diff 格式 | 21 份文档无断链，`git diff --check` 通过 | 本轮本地检查 |

跳过项是需要大小写敏感文件系统的既有用例。Demo 构建仅有 Xcode 的 AppIntents 元数据跳过提示；
Catalyst 的系统服务诊断日志没有造成测试失败。临时自检模拟器已关闭、删除，原有设备状态已恢复。
失败回归与修后日志分别留存；`/tmp` 证据用于本次复查，稳定回归在 `Tests/` 中。
模拟器首轮曾发现 TTS 超时和 6 个过时自检项，修复后按原预算重跑通过，未靠放宽预算绕过。

## 后续方案（尚未实施）

| 优先级 | 现状与影响 | 方案和验证边界 |
|---|---|---|
| P1 | web_fetch 的 max_bytes 只裁输出，`data(for:)` 仍先完整下载，超大正文可占内存 | 另设传输预算，按字节流有界读取；区分返回片段与 save_as 完整文件语义。需要大响应/取消/重定向传输回归 |
| P1 | 主机名后缀/地址字面量检查没有覆盖 DNS 解析为私网、DNS rebinding | 设计连接地址约束及逐连接授权，处理 IPv4/IPv6 多地址和重解析；本轮逐跳检查不能替代连接级防护 |
| P1 | 工具超时仍依赖工具协作取消，永不恢复的 continuation 会拖住整轮 | 明确任务所有权、迟到结果隔离和仍在发生的副作用，再实现硬返回；现有契约见 ToolSafety.md |
| P2 | 多个同协议 provider 未配置 modelPolicy 时默认选择依赖字典遍历 | 先确定默认选择契约（注册顺序或名称排序），再补多 provider 回归；本轮保持既有选择设计 |
| P2 | Keychain 写入失败的跨存储一致性尚缺故障注入验证 | 为凭据存储引入可替换接口，注入失败，验证旧配置不丢且 UI 如实报告失败；未在真实故障环境验证 |
| P2 | 结构大文件仍有拆分空间 | 按 RefactorPlan-Structure.md 的边界逐项评估；不按行数搬家，不改变集成产品或手势设计 |

真实模型服务、键盘、触摸穿透、语音权限/麦克风和后台挂起体验未做设备端到端验收；现有自动化通过不能替代这些验收。
历史文档提过旧密钥暴露，但本轮未审计 Git 全历史、未验证外部密钥轮换；不将该历史事项混作当前已证实故障。
