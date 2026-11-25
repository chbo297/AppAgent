# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Changed
- 新增会话工作区（`Sources/UI/Workspace/`，见 `docs/Workspace.md`）：数据归会话（`AISession.workspace`，随会话落盘、
  归档、恢复），全局一个容器、一个页面，每个插槽名一个视图，界面只跟当前会话。宿主按名字声明插槽
  （`AppAgentWorkspaceSlot`），插槽铺满 H5 下方、同一时间显示一个；H5 与各插槽各自显隐，state 都是 String→String。
  `workspace` 工具 op：read / write / edit / delete / set_state / clear / show / hide（`target` 不传 = 整体，h5，或插槽名）。
  页面 JS 为 `window.appAgent.workspace` 与 `window.hostApp.invoke`。宿主只实现 `AppAgentWorkspaceHost`
  （开关、容器层级、插槽、页面动作）。页面动作两种：`hostApp.invoke` 等宿主返回（同一时间一个，12 秒超时），
  `hostApp.send` 单向发出不等结果；都不要求用户点击；动作前是否收起工作区由宿主按动作决定
  （`workspacePageActionHidesWorkspace`，默认收起）。
- 对话面板档位归会话：`AISession.chatPanel`（collapsed / half / full），切会话恢复各自档位；`session` 工具 op='chat_panel'
  （原 op='ui'）。输入栏小球/展开仍是全局状态。
- 展示状态相关 API 统一用 UI 命名：`AppAgentUIDelegate`、`AppAgentUIState`、`AppAgentViewController.uiState`
  （原 `presentationDelegate` / `presentationState`）。
- 宿主业务工具与 SDK 内置工具分开注册。宿主把工具打包成 `HostToolSet`（namespace、显示名、一句话用途、工具），
  经 `ToolCentral.registerHost(_:)` 注册：工具写本地短名，模型看到 `<namespace>_<name>`；重名、非法名、
  namespace 与内置工具名前缀冲突时整组失败（`ToolRegistrationError`），不静默覆盖。`tool.origin` / `tool.localName`
  供宿主的权限与边界策略使用。系统提示词只多一行来源说明。
- 新增按需加载组：`ToolProtocol.deferredGroup` 非空的工具平时不发给模型，提示词每组一行；模型调新增的
  `load_tools(group:)` 后本会话才带上完整定义。SDK 预置 `debug` 组（`ToolGroups.debug`），
  `app_runtime_inspect`、`app_web_inspect`、`app_user_defaults` 已加入。
- `app_runtime_inspect` 拆成两个工具：`app_ui`（ui_hierarchy / view_tree / view_info / view_activate /
  page_navigate / page_scroll，常驻）与 `app_runtime_inspect`（内存对象读取、反射、写属性，debug 组），
  共用一个 provider。看界面的 `ui_hierarchy` / `view_tree` / `view_info` 两边都有：`app_ui` 用产品语言（页面名、
  用途、控件类别与文字，宿主没说明的页面才退回标题或类名），`app_runtime_inspect` 给类名并附页面说明。
  新增 `HostInspectionContext.presentation`（`.product` / `.implementation`，默认 `.implementation`）和
  `HostPageCatalog.describer`（宿主登记页面名与用途，返回 `HostPageDescription`）。
- 删除 `app_hook_capture`、`HookCaptureStore` 及诊断包里的 `msg-capture/`：桥消息采集口径属于宿主，由宿主自己实现。
- 决策卡片去掉倒计时，也去掉到时自动跳过：用户不选就一直等，会话保持「等用户选择」挂起。
  删除 `DecisionRequest.countdown` / `clarificationCountdown`。等待改挂在进程级
  `AppAgentDecisionPresenter.shared` 上，面板只 `attach(_:present:dismiss:)` 负责展示（原
  `init(present:dismiss:)` 删除）。面板被释放或换绑 agent 时请求不再被结清成拒绝，下一个面板 attach
  或切回该会话时重新贴出卡片。
- 切会话、换绑 agent、释放对话面板不再停掉正在跑的那一轮。之前它们会取消流消费者，取消顺着
  `onTermination` 停掉 run，等用户的卡片被结清成拒绝。现在只解除消费者（`detachStreamConsumer()`），
  停止只走停止按钮。
- 宿主状态协议重做：状态改成一组「key → 文本」，宿主不再维护版本号，也不再推送增量流。
  - `HostStateProvider` 只剩 `currentState() async throws -> [String: String]`，外加可选的 `fieldDescriptions()`。
    删除 `snapshot()`、`updates()`、`StateCursor`、`HostStateSnapshot`、`HostStateDelta`、`HostStateUpdate`、
    `HostPageDefinition`、`HostWorkspaceState`、`registerPageDefinition`，以及 `AIAgentMessage.stateCursor`。
  - `HostStateMirror` 改名 `HostStateReporter`（会话属性 `session.hostStateReporter`，错误类型 `HostStateReporterError`）：
    它不再同步一份宿主状态副本，职责是把宿主状态汇报给模型。
  - 新增 `HostStateStore`（OC 可用，任意线程读写）：宿主状态变了就 `setField(_:forKey:)`，事件用 `postEvent`，
    字段说明用 `setDescription`；`stableText(from:)` 把字典 / 数组转成固定格式文本。
  - SDK 每次请求模型前都读一次（之前只在每轮开始读），和模型已看到的字段逐个比对：每轮第一帧发全量
    （`HostState`），之后只发变了的字段（`HostStateChange`），没变就不发。单字段超过 4096 字符截断并注明。
  - 读取超时 3 秒（`setStateReadTimeout(_:)`），超时沿用上一份，记 `host_state_timeout` 失败日志；超过 0.5 秒打警告。
  - `app_state` 工具改读同一个来源（`AppStateTool()`，不再要参数），删除 `AppStateProvider`。
  - 消息类型 `host_state_snapshot` / `host_state_delta` 改为 `host_state` / `host_state_change`；旧版本落盘的
    宿主上下文解成空状态，不影响会话解码。
  - 本轮的提问和过程区在读宿主状态之前就上屏。
- 文件附件的暂存文件会被清理了，之前只拷进 `agent://workspace/attachments/`、从不删除。发送前移除（点 ×、或选新文件
  替换旧的）立即删除，inputBar 新增代理回调 `inputBar(_:didDiscardAttachments:)`。`AIAgent.restoreAll()` 之后在后台清扫
  一次：只看 `stage` 建的 UUID 目录，没有任何会话引用、且超过 24 小时的删掉；attachments 下别人放的目录不碰
  （`AttachmentFileStaging.sweep`、
  `AISessionManager.sweepStagedAttachments(workspaceRoot:)`），永久删除的会话的附件也由这里收走。存储读失败时整次跳过。
- 上下文压缩目标从窗口的 60% 降到 40%（触发阈值仍是 85%），压缩后留出更多余量，不会一两次工具往返又顶到阈值。
  模型报「上下文超长」（`ErrorClassifier.shouldCompress`）时，之前会原样重发同一个超长请求直到重试用完；
  现在压缩一次再发，同一轮再超就直接报错。两种压缩都会在过程区给用户一条提示
  （新增 `AIAgentEvent.notice`，持久化在 `AIAgentTurnRecord.notices`）。
- 单次回复撞到输出上限（`max_tokens`）不再直接当成答案结束：已完整收到的工具调用照常执行；
  没有工具调用时保留已输出的部分，插一条不展示的续写指令（`AIAgentMessage.agentNote`，措辞参照 Claude Code），
  每轮最多续写 3 次，正文直接拼接。Anthropic 半截工具参数在 `max_tokens` 时丢弃并续写（之前报
  `malformedToolCall` 被当成可重试错误，同一个请求重发 3 次）；Responses 的 `max_output_tokens`
  带工具调用时同样丢弃并续写（之前直接报错）。
- 续写细节（在真实模型上调出来的）：
  - 新增 `ProviderStreamEvent.discardedToolCall(name:)`，三种协议在撞上限时报出被丢弃的调用名，续写指令点名
    「这个调用没执行，拆小重发」。DeepSeek-V4-Flash 据此把一次 800 字的调用拆成 12 次小调用。
  - 连续两次撞上限都没有正文也没有被截断的调用（GLM-5.3、MiniMax-M3、Kimi K3 会把 300 tokens 全花在思考上）
    就停止续写，提示用户调高单次输出上限，不再白烧剩下的续写次数。
  - 拼接续写时去掉接缝处重复的 2～40 个字（DeepSeek 常把断点前几个字再写一遍）。
- 修 `SimpleContextCompressor` 丢掉最近几轮的问题：之前开头两条无条件保留，最新请求之前的内容全部丢弃。
  开头那条很大时（真实测试里是一段长材料），压缩后只剩「第一轮 + 最新问题」，问「最后一段的暗号」
  gpt-5.6-sol 答成了第一段的。现在开头只在不超过目标 1/4 时保留，其余预算从最新往回留，可以越过最新请求。
- 工具说明分两层：`ToolProtocol.usageGuide`（默认 nil）放详细用法，同一会话第一次调用该工具时由
  `LLMExecutor` 附在结果末尾（成功或报错都附），之后不再重复；上下文压缩后重新附一次。工具定义里的
  `description` 只留「做什么、什么时候用、什么时候别用」，每轮请求不再带整本手册，也不打乱 prompt 缓存。
  `app_runtime_inspect` 说明从约 3.9K 字符减到约 0.8K，`app_web_inspect` 从约 2.5K 减到约 0.5K，原内容移入手册。
- `app_runtime_inspect` 反射参数改为 typed 数组 `arguments`（如 `["Hi", 0]`），旧的 `argumentsJSON`
  字符串和把数组写成字符串的写法仍接受；`value` 写成数字或布尔也按同义文本处理。各参数说明写明归属的 op 与格式。
- 默认工具提示新增 `screenshot` 一条：报告画面变化前先截图确认，地图 / GPU 图层用宿主自己的截图能力。
- 发给模型的历史只保留最近 2 个带图工具结果的原图（`SimpleContextCompressor.retainingRecentImages`），
  更早的截图换成占位文字，提示需要时重新截。之前截图要等到上下文压缩阈值才会丢：真机一轮「看图画马」
  留了 7 张截图，请求体 4.7MB，单轮耗时从约 15 秒涨到约 75 秒。

- 模型探查与重测完成后，已选模型保留优先级并置前，未选模型按首 token 耗时升序排列；
  耗时相同保持原顺序，失败或耗时未知置后，无选择时不再自动勾选接口返回的第一项。
- 模型网络故障沿用有界重试，耗尽后显示请求 Host、脱敏后的系统错误及错误码，
  提示“网络错误，请稍后重试”；取消不误判为网络故障。
- `session(op: models)` 返回当前配置的脱敏接口地址与请求 URL，复用实际请求的 URL 构造规则，
  不暴露 API Key、认证头、URL 用户信息、查询参数或片段。
- 模型设置页新增确认清除，保存/清除检查持久化结果，失败保留草稿并提示；
  清除取消探查并通过 `onSave` 透传空配置。运行时清除取消会话执行、撤销模型选择与回退世代，
  新会话不再隐式采用宿主 Provider；保留聊天历史，配置注册与发布在同一 actor 操作内完成。
- 内置工具入口收敛为 `file`、`skill`、`session`、`device_info` 和 `host_info`，
  `app_action` 在注入 Provider 后自动装配；宿主开发能力继续由独立部署开关控制。
- 修复上下文压缩覆盖聊天历史、并发追加丢消息、并发准入超额、旧流取消污染新轮 UI、
  早期抢占误报内部失败及消息上下文注入丢元数据；循环检测改为 JSON 内容等值并修正乒乓误报。
- `web_fetch` 逐跳校验并授权重定向，补 IPv6/另类 IPv4 私网识别和 UTF-8 安全裁剪；
  工具整数参数统一检查有限值、溢出、小数与区间，修复文件分页溢出和文件名通配符。
- 修复记忆缓存迟到覆盖、瞬态读取失败被缓存为空、禁用记忆谎报成功和负数限额；
  技能 frontmatter 仅按独立分隔行结束，支持引号元数据并保留 CRLF 正文。
- Anthropic/Chat Completions 拒绝损坏工具参数，Chat 不再从 DONE 或非工具终止释放待执行调用；
  三种协议共用 Schema 编码，SSE 兼容冒号后无空格字段；端点/探测校验非正 token 上限和非法超时。
- 宿主状态上报（`HostStateReporter`）、聊天流消费者在静默等待时可释放；agent 换绑结清旧授权与观察，
  决策按 agent 归属路由，语音重启隔离迟到事件，清历史后不复用旧轮展开态，换展示代理补首通知。
- 设置页编辑端点/密钥或关闭后取消探查并按运行标识丢弃迟到模型、错误和可用性结果，
  防止旧端点结果污染新配置。
- 朗读工具等待支持取消与单次恢复，合成器在主线程启停，取消不再等系统回调或误报成功；
  模拟器自检同步受限属性拒绝断言、可见激活夹具与隐藏目标拒绝回归。
- 文档统一 Swift 6 / iOS、Catalyst 15 的要求和当前 Demo/API 路径，精简已完成及过时重构计划；
  当前审计证据、验证结果与后续方案集中到 `docs/OptimizationPlan.md`。
- `app_action` 的常规宿主动作改为 `.moderate`，与模拟用户操作、公开 OpenAPI 导航一致，默认无需 SDK 授权确认；保留只读限制与宿主执行门禁。
- Responses 流失败保留上游 type/code/message，接入既有有界重试与模型回退；未知流错误不默认重试。
  失败、不完整响应及 `[DONE]` 不再输出待执行工具调用，完整响应也拒绝损坏的工具参数。
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
- `app_runtime_inspect` 读取不再限制对象链：`property_value` 可穿过任意宿主对象、字典键与数组下标，
  集合与任意对象按 description 输出（2 万字符截断）；host 范围仍拒绝值里嵌套的 SDK 对象，写入仍限 UI 链与标量值。
  带 `class` 的读写会在控制器树里找最上层实例；未声明 key 报「not a declared property/ivar」，不再误报集合遍历受限。
- 属性观察改为按运行时声明直接读取 getter/ivar，保留明确允许的 UIKit 只读 getter；
  所有 scope 拒绝把普通方法或 KVC 的 `get<Key>` 猜测当成属性，堵住 `.safe` 读取的副作用入口。
- `AppNavigationProvider.navigate` 保留 Void API，正常返回仅承诺请求已受理/提交；
  `app_navigate` 返回 `submitted: true`、`completion: "unconfirmed"` 与明确的提交文案，
  `success` 仅表示提交成功，不再声称页面已呈现。提交后不得仅因呈现未确认而抛错，避免诱导重复请求。
- Endpoint Settings 默认地址、密钥、请求头和模型列表均为空，移除内置的默认端点、
  地址与请求头；宿主须显式提供自己的接入配置。
- 设置页保存、模型探查与 Provider 构造统一校验 HTTP(S) 根地址、非空 API Key 和模型 id，
  请求与模型引用使用去除首尾空白后的值；任一启用模型 id 为空即拒绝整份配置。
- 无效配置不生成 Provider / ModelPolicy；应用或注册设置会清理旧的 Settings Provider，
  保留宿主自行注册的其他 Provider。

### Added
- 诊断包新增宿主补充时机 `AppAgentDiagnostics.registerHostContributor(name:contribute:)`：导出时在后台队列调用，
  宿主把导出时刻的关键信息（开关、计数、状态摘要）写进自己的 `host/<name>/`，返回值作为清单说明；
  补充方抛错只在清单记失败，不中断导出。可与同名的 `registerHostDirectory` 共用目录。
- 输入栏加号面板：点加号后面板顶替键盘出现在输入栏下方，内含「图片」「文件」两个方格；面板展开时加号变成叉，
  点叉收起。图片走系统 PHPicker
  （一次最多 4 张，无需相册权限），长边缩到 1568px 并转 JPEG；文件走系统文件选择器（一次 1 个，上限 20MB），
  拷进 `agent://workspace/attachments/`，64KB 以内的 UTF-8 文本直接内联给模型。选好的附件以缩略图排在
  输入栏最上面一行（右上角的叉可移除，图片不满 4 张时末尾有加号格可继续添加），与文字一起发送；用户气泡上方同样显示缩略图。
  Core 新增 `AIAgentMessage.Content.attachment`、`AIAgentMessage.Attachment` 和
  `AISession.sendMessage(_:attachments:)`，三种 wire 格式都把用户图片映射成多模态块。
- 诊断包新增 `host/<name>/`：宿主可用
  `AppAgentDiagnostics.registerHostDirectory(name:url:maxBytes:)` 登记自己的排查目录，导出时按修改时间从新到旧拷贝到限额为止。
- 语音识别引擎可切换：新增 `AppAgentVoiceRecognitionCentral`（内置「系统识别」，可注册其他引擎），
  `AppAgentVoiceRecognitionProviding` 与识别事件上下文的构造器改为 public。设置页新增「语音识别」入口
  （注册了不止一个引擎才出现），用户选择持久化，下一次语音输入起生效；选中的引擎没打包进来或没配凭据时回退系统识别。
- `AppAgentViewController.navigationAccessory` / `onNavigationAccessoryTapped`：宿主可在对话面板顶栏
  （会话设置按钮左侧）挂一个配套页面开关；读屏读出「已展开 / 已收起」。nil 隐藏，状态由宿主维护。
  `AppAgentNavigationAccessory` 只剩 `isActive` 与 `accessibilityName`，图形不再由宿主传 SF Symbol。
- 新增公开控件 `AppAgentPageToggleButton`（`.bar` / `.floating` 两种底）：一个小窗口图形，展开时上格占大半并着强调色，
  收起时折成顶端一条强调色细线，切换带弹簧动画（减弱动态效果时直接切换），视觉 36pt、点按区域 44pt。
  顶栏开关用它，宿主页面里的收起按钮也用它，两处长得一样。
- `AppAgentViewController.hostReservedBottomHeight`：宿主底部控件占用、要求让出的高度（叠加在系统安全区之上，
  不属于安全区）。对话面板收在 peek 时输入栏据此抬高；向半屏展开的过程中输入栏随面板底部延伸同步回到安全区位置，
  半屏及以上面板铺到屏幕底部。键盘弹起时仍贴键盘，收起态胶囊不受影响。
  对话面板四角在任何展示高度都保持圆角，展开到半屏以上不再变成直角。
  输入框获得焦点时，收起（peek）的对话面板自动弹到半屏。
- 输入栏支持多行草稿：`AppAgentInputBar.textField`（`UITextField`）换成 `textView`（`AppAgentTextView`，
  `UITextView` 子类，取代 `AppAgentTextField`）。草稿按行长高，最多 7 行（`AppAgentTextView.maximumVisibleLineCount`），超出后框内滚动；
  两侧按钮贴底。新增 `expandedHeight(forWidth:)` 与代理回调 `inputBarDidChangeExpandedHeight(_:)`，
  只在行数等真正改变高度时触发重排。有草稿时语音按钮让出的那一格并入输入区，不再留白。
- 修复多行输入的三个问题：文字区宽度与排版宽度不一致（输入源按钮显隐改变输入区宽度后按旧宽度折行）、
  换行瞬间文字区没有跟着长高（首行以下被裁掉）、长高瞬间用未更新的 `contentSize` 判断滚动把首行滚掉。
  现在文字容器宽度跟随 frame，草稿变化先重排文字区再通知宿主，滚动判定改用内容排版高度。
- 输入栏最多展开高度从 3 行放宽到 7 行（`AppAgentTextView.maximumVisibleLineCount`），超出后框内滚动。
- 宿主底部预留高度改为「宿主提供、SDK 拉取」：`hostReservedBottomHeight` 对宿主只读，值来自新增的
  `AppAgentPresentationDelegate.appAgentHostReservedBottomHeight()`（默认 0）。设置 `presentationDelegate` 时取一次，
  宿主页面切换后调用 `AppAgentViewController.invalidateHostReservedBottomHeight()` 重新取，值变了才重排。
  配套页面展开（`navigationAccessory.isActive`）期间输入栏不让出预留高度，收起后恢复，宿主不必再为工作区自己归零。
  生效值变化时输入栏与停在 peek 的面板一起用 0.2 秒过渡；修复面板停在 peek 时预留高度变小，面板仍停在旧高度、
  比输入栏高出一截。
- 修复：宿主挂上 overlay 后、首次布局前调用 `setInputBarCollapsed(true, animated:)`，首帧布局会按默认展开态
  覆盖掉这次收起，导致悬浮球启动时是展开的。现在首次布局前的请求一律记到 `startsInputBarCollapsed`，由首帧按它落位。
- 统一 `file` 资源工具和 `FileResourceRegistry`：通过 `agent://` / `host://` 逻辑 URI
  发现、读取、写入、搜索、删除和按需解析真实地址；宿主可以注册源码、文档、日志等资源。
- 统一 `session` 工具，合并历史搜索与会话生命周期；Skill Runtime 先返回 metadata，
  正文和 linked resources 只在明确 `load` 时读取。
- `app_web_inspect` 正式 `highlight` / `clear_highlight`：原生透传红框、滚动/布局跟随与导航/离屏清理，
  支持同源 iframe / open shadow 路径、节点 attributes 和坐标说明；补充真实 WKWebView 回归测试。
- 通用 `ToolExecutionGate` 与 `AIAgentProfile.toolExecutionGate`（默认 nil，运行时依赖、不持久化）：
  授权前和执行前检查完整工具参数；拒绝作为工具错误，不申请授权、不执行。
  子任务继承父 gate，发送任务前调用 `prepareDelegation`，供宿主固定子任务权限上限。
- 按类别的权限授权：宿主经 `AIAgentProfile.toolPermissionPolicy`（`ToolPermissionPolicy`）登记权限类别
  （`AppAgentPermission`）和每次调用需要的权限；未授权时弹 `DecisionRequest.permission` 卡，
  选项为允许单次 / 在本会话中允许 / 始终允许 / 拒绝（新增 `DecisionOutcome.allowAlways`）。
  本会话授权记在 `AISession.permissionGrants` 并随 `SessionSnapshot.permissionGrants` 落盘，
  始终允许记在设备级 `AppAgentPermissionStore`；委派任务继承父会话授权但不能申请新权限。
  对话页顶部栏新增「会话设置」按钮，列出当前会话的权限状态并可修改或撤销。
- 决策卡片改为「先选中、再点确定/提交」；长选项默认两行并可展开/收起。提问卡（`clarify`）最后一项固定为
  「其他（自己输入）」（`DecisionOption.customAnswerID`），可跳过；授权卡只给有效选项。两种卡都一直等用户。新增
  `ToolProtocol.waitsForUser`：为 true 的工具（`clarify`）不再被通用 `toolTimeout` 掐断。

### Removed
- 内置工具旧名不再存在（模型提示词、宿主 `disabledBuiltInTools` 需改用新名）：`file_read` / `file_write` / `file_search` /
  `app_sandbox_file` 合并为 `file`，`session_manage` / `session_search` 合并为 `session`，`app_device_info` 改名 `device_info`，
  `app_hook_capture` 删除。
- 类型与字段：`AppStateProvider`（由 `HostStateStore` / `HostStateProvider.currentState()` 取代）、`HostStateMirror`
  （改名 `HostStateReporter`）、`HostStateSnapshot` / `HostStateDelta` / `StateCursor` 与消息上的 `stateCursor`、
  `DecisionRequest.countdown` / `clarificationCountdown`、`AppAgentTextField`（输入框改为 `AppAgentTextView`）。

### Fixed
- 无参工具调用（如 `screenshot`）经 Chat Completions / Responses 网关回传 `"arguments":""` 时按 `{}` 处理，
  不再判为坏 JSON 终止整轮。其余残缺工具调用改抛 `ModelError.malformedToolCall`，归类为可重试，
  重发同一请求而不是直接失败。
- `SimpleContextCompressor`：图片按每张约 1.6k tokens 估算，不再按 base64 长度（1MB 截图曾被估成 ~345k tokens
  误触发压缩）；压缩时必保用户最新一条请求，旧截图先于文字被替换为占位；摘要不再要求「只回答最新用户消息」。
  压缩事件写入 `AppAgentDebugLog`，诊断包可见。
- 紧挨当前轮之前、被中断且无回复的那一轮，发给模型时保留用户原话并补一条中断说明，
  用户的补充或纠正不再失去指代；更早的孤儿轮仍然丢弃。
- `screenshot` 内联图片改用 JPEG（落盘仍为 PNG），减小请求体积。
- `file` 访问 `host://` 资源时补回存储过滤：`list` / `search` 逐条过 `HostStoragePolicy`，SDK 的会话、记忆、
  日志、诊断导出等受保护文件连名字都不会列出或被搜出内容；`search` / `reveal_path` 也做目标检查；
  `search` 满额即停；`agent://workspace/./.` 等价根路径不再能删掉整个资源根。
- 上下文压缩在保住最新用户请求的同时，也必保最新一个单元（通常是刚拿到的工具结果），
  不再因结果超预算被丢、导致模型反复调用同一工具。
- 只发附件不带文字时，当前时间与宿主上下文包在这条消息上，不再落到上一轮的文字消息。
- `session` 默认提示补回「delete 只归档、工具不能永久删除」；`skill` 的 `uncategorized` 分类可展开；
  附件拷贝后按实际大小复核 20MB 上限；`registerHostDirectory` 拒绝 `.` / `..`。
- 换备用模型、宿主上下文提交失败两条路径不再把发给模型的历史重置成原始版本：换模型时重新整理
  （剔孤儿轮、中断说明、上下文包装），提交失败只丢这次的宿主上下文。
- 用户附图只在当前轮发给模型，更早轮次换成占位文字（会话里的原图与界面显示不变），不再每轮整批重发。
- 选图片 / 文件后、读完之前切换了会话，附件不再被塞进新会话的输入框，拷进工作区的文件随之删除。

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
