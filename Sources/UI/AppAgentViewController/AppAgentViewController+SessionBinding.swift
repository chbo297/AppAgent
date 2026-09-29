//
//  AppAgentViewController+SessionBinding.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 一个还没被回答的决策请求：卡片内容 + 回答通道。
struct AppAgentPendingDecision {
    /// 由 `AppAgentDecisionPresenter` 分配；请求被取消时靠它找回这一条。
    let id: UUID
    let request: DecisionRequest
    /// 只能调用一次（`AppAgentDecisionPresenter` 内部另有一道 settled 保险）。
    let complete: (DecisionOutcome) -> Void
}

/// 为什么要重建对话列表。
///
/// 这个参数**没有默认值**，是刻意的：两种语义对界面高度的处理相反，而默认值让
/// 「新加一条运行通知路径时忘了传」变成一个不会报错、只能靠眼睛发现的缩高 bug。
/// 去掉默认值之后，漏传编译不过。
public enum AppAgentChatReloadReason {
    /// 用户在重新浏览（换会话、展开面板、侧栏切换、显式刷新）：
    /// 已结束的尾回复恢复实际内容高度，释放占位留白。
    case browsing

    /// 运行中 / 终局事件引发的连续刷新：保住已分配高度，
    /// 否则终局折叠过程区时界面会缩一下。运行中的回复始终保留高度。
    case runningUpdate

    /// 是否保留当前回复已分配的高度。
    var preservesReplyHeight: Bool { self == .runningUpdate }
}

// MARK: - Session ↔ UI

extension AppAgentViewController {
    // MARK: - 用户发起的会话归档 / 废纸篓

    func promptArchiveSession(_ item: AppAgentSessionSidebarItem) {
        guard let id = item.sessionID, let agent,
              agent.session(id: id) != nil,
              sessionSidebarView.sessionListView.archivingSessionID == nil,
              presentedViewController == nil, !isBeingDismissed else { return }
        let alert = UIAlertController(
            title: "移入废纸篓",
            message: "将「\(item.title)」归档到废纸篓？归档后可在废纸篓中恢复，不会自动清空。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        var submitted = false
        alert.addAction(UIAlertAction(title: "移入废纸篓", style: .destructive) { [weak self] _ in
            guard !submitted, let self, self.agent === agent else { return }
            submitted = true
            Task { @MainActor [weak self] in
                guard let self, self.agent === agent else { return }
                await self.archiveSessionFromSidebar(id)
            }
        })
        present(alert, animated: true)
    }

    /// 仅在持久化成功后解绑 / 切换。注入闭包用于不建窗口的存储失败和两处 await 竞态测试。
    @nonobjc
    func archiveSessionFromSidebar(
        _ id: String,
        archive: (@MainActor (String) async throws -> Void)? = nil,
        createSession: (@MainActor () async -> AISession)? = nil
    ) async {
        guard let agent, let session = agent.session(id: id) else { return }
        let list = sessionSidebarView.sessionListView
        guard list.beginArchiving(id) else { return }
        let operationToken = UUID()
        archiveOperationToken = operationToken
        do {
            if let archive {
                try await archive(id)
            } else {
                try await agent.sessionManager.archiveSession(id)
            }
            // 宿主可能在 await 期间重新绑定 agent；旧任务不能操纵新 agent 的会话。
            guard self.agent === agent, archiveOperationToken == operationToken else { return }
            session.uiState.onChange = nil
            if currentSessionId == id {
                if let next = agent.allSessions.first(where: { $0.id != id }) {
                    switchSession(to: next.id)
                } else {
                    let fresh: AISession
                    if let createSession {
                        fresh = await createSession()
                    } else {
                        fresh = await agent.createSession(title: "对话")
                    }
                    // 新建也会挂起；不能把期间主动切换的用户拉回来。
                    guard self.agent === agent, archiveOperationToken == operationToken else { return }
                    if currentSessionId == id { switchSession(to: fresh.id) }
                }
            }
            // switchSession 的宿主回调也可能同步换绑，收尾同样必须检查所有权。
            guard self.agent === agent, archiveOperationToken == operationToken else { return }
            archiveOperationToken = nil
            list.finishArchiving()
            reloadSessionSidebarItems()
        } catch {
            guard self.agent === agent, archiveOperationToken == operationToken else { return }
            // 不清消息、草稿、观察者或 currentStreamTask；错误留在侧栏而非抢占其他弹窗。
            archiveOperationToken = nil
            list.finishArchiving(error: "移入废纸篓失败：\(error.localizedDescription)\n会话未移出，请重试。")
            if viewIfLoaded?.window != nil,
               presentedViewController == nil, !isBeingDismissed {
                // 等待期间侧栏可能被用户收起；失败必须仍然可见，而不是只留在隐藏标签里。
                showSessionSidebar(animated: true)
            }
        }
    }

    func presentSessionTrash() {
        guard let agent, sessionSidebarView.sessionListView.archivingSessionID == nil else { return }
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            if presented is AppAgentSessionTrashNavigationController { return }
            presenter = presented
        }
        guard !(presenter is UIAlertController),
              !presenter.isBeingDismissed, !presenter.isBeingPresented else { return }
        let trash = AppAgentSessionTrashViewController(sessionManager: agent.sessionManager)
        trash.onSessionsChanged = { [weak self] in
            guard let self, self.agent === agent else { return }
            // 恢复只回到正常列表，不抢走用户当前正在进行的会话。
            self.reloadSessionSidebarItems()
        }
        let nav = AppAgentSessionTrashNavigationController(rootViewController: trash)
        nav.modalPresentationStyle = .formSheet
        hideSessionSidebar(animated: false)
        presenter.present(nav, animated: true)
    }

    /// 从当前 session 重建唯一的 ChatPanel 消息列表。
    ///
    /// 列表不再按 wire 消息一条条铺开，而是按「一次提问」组装：用户气泡只放用户真的
    /// 说过的话，agent 的工具往返与中间思考全部收进它自己的过程区（见
    /// `ChatMessageAssembler`）。工具与中间发言由记录重建；未持久化的 reasoning
    /// 在当前会话的展示生命周期中保留，切换会话 / 重启不承诺恢复它。
    ///
    /// **每轮的状态一律来自 `session.turnRecords`**（落盘的 `AIAgentTurnRecord`）：
    /// 跑到哪一步、是否还在跑、最终答了/空了/失败了/被停了/上次中断了，都在里面。
    /// 不再从 `uiState.lastError` / `isStreaming` / `runStage` 另开一路——双源是
    /// 「loading 挂到上一条回复上」「转圈停不下来」「失败界面没反馈」的共同成因。
    ///
    /// - Parameters:
    ///   - forceScrollToBottom: 换会话 / 首次装载传 true；常规重建不强拉阅读位置。
    ///   - reason: **必填**。`.browsing` = 用户重新浏览，释放已结束回复的留白；
    ///     `.runningUpdate` = 运行 / 终局事件引发的连续刷新，保住已分配高度。
    ///     没有默认值，漏传编译不过（见 `AppAgentChatReloadReason`）。
    public func reloadFromSession(
        forceScrollToBottom: Bool = false,
        reason: AppAgentChatReloadReason
    ) {
        let preservingReplyHeight = reason.preservesReplyHeight
        guard let session = currentSession else {
            chatMessages = []
            if isViewLoaded { chatPanelView.listView.setMessages([]) }
            refreshInputBarRunState()
            return
        }

        // reasoning 不进 wire，工具在终局才写回；包括已结束的轮次，也要保留已展示内容。
        // switchSession 会清空 chatMessages；startedAt 再隔离清空历史后复用的 turnID。
        let records = session.turnRecords
        var displayedActivities: [Int: AppAgentActivityTimeline] = [:]
        for message in chatMessages where message.role == .assistant {
            if let turnID = message.turnID, let activity = message.activity,
               records[turnID]?.startedAt == activity.startedAt {
                displayedActivities[turnID] = activity
            }
        }
        var assembled = ChatMessageAssembler.assemble(
            session.messages,
            turnRecords: records,
            streamingText: session.isRunning ? session.uiState.streamingText : "",
            expandedTurnIDs: expandedActivityTurnIDs,
            collapsedTurnIDs: collapsedActivityTurnIDs,
            alwaysShowThinkingProcess: AppAgentSettingsStore.alwaysShowThinkingProcess
        )
        for index in assembled.indices where assembled[index].role == .assistant {
            guard let turnID = assembled[index].turnID,
                  let displayed = displayedActivities[turnID],
                  var activity = assembled[index].activity else { continue }
            activity.preserveDisplayedItems(from: displayed)
            assembled[index].activity = activity
        }

        // 【重新展示同一份内容不重建】收起后再展开、冗余刷新等场景，组装结果与当前展示逐条内容
        // 等价（仅 id 变）。整表重建会让行高缓存全 miss、在动画帧里全量重测——正是高度错乱的来源。
        // 只在「重新浏览」路径（preservingReplyHeight == false）短路：保留旧 id 与缓存命中，
        // 只释放终局回复留白，不 setMessages。运行 / 终局通知走 preservingReplyHeight == true，
        // 必须保留已分配高度，交给下面的正常 setMessages 处理。
        if !forceScrollToBottom, !preservingReplyHeight, !session.isRunning,
           assembled.count == chatMessages.count,
           zip(assembled, chatMessages).allSatisfy({ $0.hasEquivalentContent(to: $1) }) {
            if isViewLoaded { chatPanelView.listView.beginNewPresentation() }
            refreshInputBarRunState()
            return
        }

        chatMessages = assembled

        if isViewLoaded {
            chatPanelView.listView.setMessages(
                chatMessages,
                forceScrollToBottom: forceScrollToBottom,
                preservingReplyHeight: preservingReplyHeight
            )
        }
        // 换会话 / 重新装载也要让输入栏右侧的发送↔停止跟上这个会话的运行状态。
        refreshInputBarRunState()
    }

    // MARK: - 运行中的停止 / 打断

    /// 当前会话是否还在跑一轮。
    ///
    /// 口径是「执行器手上还有活」：`isRunning` 为准，加上「记录还没终局」兜住任务已摘、
    /// 记录还没关的那一小段。用户按过停止的那一轮直接按已结束算（见 `stoppedRunTurn`）。
    var isAgentRunActive: Bool {
        guard let session = currentSession else { return false }
        if let stopped = stoppedRunTurn,
           stopped.sessionId == session.id, stopped.turnID == session.currentTurnID {
            return false
        }
        if session.isRunning { return true }
        guard let record = session.turnRecord(turnID: session.currentTurnID) else { return false }
        return !record.isFinished
    }

    /// 把运行状态同步给输入栏：输入框为空时右侧加号↔停止按钮就靠这一条切换。
    func refreshInputBarRunState() {
        inputBar.setRunActive(isAgentRunActive)
    }

    /// 用户按停止：取消当前会话这一轮。
    ///
    /// Core 负责把 `turnRecord` 关成 `.cancelled`（界面上显示「（已停止）」），这里只记下
    /// 「这一轮已经被要求停了」并立刻把按钮切回去，不等执行器真的走到取消检查点。
    func stopCurrentRun() {
        guard let session = currentSession, isAgentRunActive else { return }
        Logger.info(
            "AppAgentViewController",
            "stopCurrentRun: session=\(session.id), turn=\(session.currentTurnID)"
        )
        stoppedRunTurn = (sessionId: session.id, turnID: session.currentTurnID)
        session.cancel()
        refreshInputBarRunState()
    }

    /// 用户手动折叠 / 展开某一轮的过程区：记在 turnID 上，重建列表时照旧。
    func handleActivityToggled(_ message: ChatMessage) {
        if let index = chatMessages.firstIndex(where: { $0.id == message.id }) {
            chatMessages[index].isActivityExpanded = message.isActivityExpanded
        }
        guard let turnID = message.turnID else { return }
        if message.isActivityExpanded {
            expandedActivityTurnIDs.insert(turnID)
            collapsedActivityTurnIDs.remove(turnID)
        } else {
            expandedActivityTurnIDs.remove(turnID)
            collapsedActivityTurnIDs.insert(turnID)
        }
    }

    func bindUIState() {
        guard let session = currentSession else { return }
        bindInspectionScene(to: session)
        let boundSessionId = session.id
        session.uiState.onChange = { [weak self] key in
            Task { @MainActor [weak self] in
                guard self?.currentSessionId == boundSessionId else { return }
                self?.handleUIStateChange(key: key)
            }
        }
    }

    func bindInspectionScene(to session: AISession) {
        if let scene = viewIfLoaded?.window?.windowScene {
            session.inspectionSceneIdentifier = scene.session.persistentIdentifier
        }
    }

    func handleUIStateChange(key: String) {
        guard let session = currentSession else { return }
        // 运行状态的每一次通知都顺手同步输入栏右侧的发送↔停止（切换本身会判等短路）。
        refreshInputBarRunState()
        switch key {
        case "streamingText":
            // 定位口径和 `applyActivity` 一致：写「最后一条 assistant 气泡」，不是
            // 「最后一行」——本轮还没吐正文时列表末尾是刚插入的用户气泡。
            guard let index = chatMessages.lastIndex(where: { $0.role == .assistant }),
                  chatMessages[index].status == .streaming else { return }
            let streamingText = session.uiState.streamingText

            // 最终结果第一次开始输出时：先让过程区按「总是显示思考过程」开关收起（开）或
            // 隐藏（关），再往下展示结果文案。组装器已据 `finalAnswerStarted` 得出目标态，
            // 这里只在「当前展示态和目标不一致」时做一次性重建触发它，避免每个 delta 全量重建。
            let hasFinalText = !streamingText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasFinalText,
               let turnID = chatMessages[index].turnID,
               !expandedActivityTurnIDs.contains(turnID),
               chatMessages[index].activity?.shouldDisplayActivity == true {
                let needsChange = AppAgentSettingsStore.alwaysShowThinkingProcess
                    ? chatMessages[index].isActivityExpanded          // 开：要从展开收成一行
                    : !chatMessages[index].suppressResolvedActivity   // 关：要把过程入口藏掉
                if needsChange {
                    // 重建会让组装器按 finalAnswerStarted 置 autoExpandWhileStreaming=false（收起）
                    // 或 suppressResolved=true（隐藏）；下一个 delta 目标态已达成，needsChange 即为
                    // false，不会反复重建。运行通知必须 preservingReplyHeight 保住已分配高度。
                    reloadFromSession(reason: .runningUpdate)
                    return
                }
            }

            chatMessages[index].text = streamingText
            chatPanelView.listView.updateMessage(
                text: streamingText,
                status: .streaming,
                messageID: chatMessages[index].id
            )

        case "isStreaming":
            if !session.uiState.isStreaming {
                // 本轮结束：用组装器根据 turnRecord 重建正文、过程和错误。
                // 不用 forceScrollToBottom，让翻历史的用户不被拽回底部。
                reloadFromSession(reason: .runningUpdate)
            }

        case "lastError":
            // 错误从 turnRecord 挂进所属轮次的 assistant 气泡。
            // 若 `isStreaming` 已经先变为 false（通常是），上面的分支已经重建过了；
            // 但 `setStreaming(false)` 和 `setError` 是两次独立的 dispatchCallback，
            // 先后顺序不保证，也有「error 先到、isStreaming 后到」的可能——所以这里
            // 无条件再 reload 一遍，幂等无害。
            reloadFromSession(reason: .runningUpdate)

        case SessionUIState.runStageKey:
            if let record = session.turnRecord(turnID: session.currentTurnID), !record.isFinished,
               let message = chatMessages.last(where: {
                   $0.role == .assistant && $0.turnID == record.turnID
               }), let activity = message.activity, activity.startedAt == record.startedAt {
                // 阶段通知同样走单行台阶刷新；慢工具/授权等待期间不重建整张表。
                applyActivity(activity)
            } else {
                // 初次 preparing 建立本轮气泡，终局则以已经写回的记录收尾。
                reloadFromSession(reason: .runningUpdate)
            }

        case SessionUIState.pendingDecisionKey:
            // 安全网：没人在等了但卡片还挂着（工具放弃等待 / 请求被别人答了），撤掉它。
            if session.uiState.pendingDecision == nil,
               let id = currentSessionId,
               pendingDecisions[id]?.isEmpty ?? true {
                dismissDecisionCard()
            }

        default:
            break
        }
    }

    // MARK: - 等用户拍板

    /// 收下一个决策请求。返回 false 表示「我现在没法呈现」，责任链会往下走到兜底。
    ///
    /// 不属于当前会话的请求也**收下**（返回 true）：否则责任链会兜底拒绝，等于替
    /// 用户做了决定；记着它，等用户切回那个会话再贴卡片。同一会话里并发来了第二个
    /// 请求也照样排队——卡片只有一张，但不能因此把谁的 continuation 丢掉。
    func enqueueDecision(
        _ request: DecisionRequest,
        sessionId: String,
        requestId: UUID,
        complete: @escaping (DecisionOutcome) -> Void
    ) -> Bool {
        let pending = AppAgentPendingDecision(id: requestId, request: request, complete: complete)
        pendingDecisions[sessionId, default: []].append(pending)

        guard sessionId == currentSessionId else {
            Logger.info("AppAgentViewController", "decisionQueuedForOtherSession: \(sessionId)")
            return true
        }
        // 前面还有没答完的：等那张答完自然会轮到它。
        if (pendingDecisions[sessionId]?.count ?? 0) > 1 { return true }

        guard presentPendingDecision(for: sessionId) else {
            pendingDecisions[sessionId]?.removeAll { $0.id == requestId }
            if pendingDecisions[sessionId]?.isEmpty == true {
                pendingDecisions.removeValue(forKey: sessionId)
            }
            return false
        }
        return true
    }

    /// 请求方不再等待（run 被取消）：把这一条摘掉；正在显示的话换下一张。
    ///
    /// 只做 UI 侧清理——continuation 已经由 `AppAgentDecisionPresenter` 在取消时恢复过了，
    /// 这里**不能**再调 `complete`。
    func cancelDecision(requestId: UUID) {
        guard let sessionId = pendingDecisions.first(where: { _, queue in
            queue.contains { $0.id == requestId }
        })?.key else { return }

        let wasShowing = pendingDecisions[sessionId]?.first?.id == requestId
        pendingDecisions[sessionId]?.removeAll { $0.id == requestId }
        if pendingDecisions[sessionId]?.isEmpty == true {
            pendingDecisions.removeValue(forKey: sessionId)
        }
        Logger.info("AppAgentViewController", "decisionCancelled: session=\(sessionId)")

        guard wasShowing, sessionId == currentSessionId, isViewLoaded else { return }
        dismissDecisionCard()
        presentPendingDecision(for: sessionId)
    }

    /// 撤卡片的唯一出口：撤完顺手把遮挡变化报给宿主（卡片贴在面板可见区里，占一块区域）。
    func dismissDecisionCard() {
        chatPanelView.dismissDecision()
        notifyPresentationChangeIfNeeded(reason: .visibility)
    }

    /// 把某个会话队首的卡片贴出来。呈现不了时返回 false（不动队列，下次切回来还能再试）。
    @discardableResult
    func presentPendingDecision(for sessionId: String) -> Bool {
        guard let pending = pendingDecisions[sessionId]?.first else { return false }
        let shown = chatPanelView.presentDecision(pending.request) { [weak self] outcome in
            guard let self else {
                pending.complete(outcome)
                return
            }
            if var queue = self.pendingDecisions[sessionId], !queue.isEmpty {
                queue.removeAll { $0.id == pending.id }
                self.pendingDecisions[sessionId] = queue.isEmpty ? nil : queue
            }
            pending.complete(outcome)
            // 同一会话里还排着的，接着弹下一张。
            if self.currentSessionId == sessionId {
                self.presentPendingDecision(for: sessionId)
            }
        }
        if shown {
            notifyPresentationChangeIfNeeded(reason: .visibility)
        }
        return shown
    }

    /// 并行上限提示。做成**返回 alert 的工厂**而不是直接在内部 present：用例能直接断言文案，
    /// 不必造窗口（与 `AppAgentSessionTrashViewController.makeDeletionConfirmation` 同一形态）。
    func makeConcurrencyLimitAlert(runningCount: Int) -> UIAlertController {
        let alert = UIAlertController(
            title: "暂时无法执行更多",
            message: "已经有 \(runningCount) 个会话在运行。停掉其中一个再回来发送即可，刚输入的内容仍留在输入栏里。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        return alert
    }

    func sendMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = currentSession else { return }
        // 归档提交期间用户可能收起侧栏回来发送；不能先清草稿再被 Core 的生命周期闸门拒绝。
        guard sessionSidebarView.sessionListView.archivingSessionID != session.id else { return }
        bindInspectionScene(to: session)

        // 并行上限预检：达到上限时在任何乐观 UI 之前硬阻断（既不追加气泡也不禁用输入），
        // 但**必须让用户看见** —— 只 return 的表现是「点了发送没反应」。草稿刻意留在输入栏里
        // （`finishInputBarAfterSend()` 排在这道闸之后），关掉弹窗去停一个正在跑的会话再回来发。
        // AISession.sendMessage 会作为权威闸门再次复检（防御性双重校验）。
        if let agent = agent, !agent.sessionManager.canAdmitRun(for: session) {
            let limit = agent.sessionManager.governor.limit
            let running = agent.sessionManager.runningSessionCount
            Logger.info(
                "AppAgentViewController",
                "sendMessage 被并行上限拦截: running=\(running), limit=\(limit)"
            )
            if presentedViewController == nil, !isBeingDismissed {
                present(makeConcurrencyLimitAlert(runningCount: running), animated: true)
            }
            return
        }

        // 模型运行中不禁用输入栏：用户可以继续输入、切换输入方式或打开菜单。
        finishInputBarAfterSend()

        // 运行中又发新内容（打字发送或语音转文字）= 默认打断上一轮。Core 的 `run` 自己也会
        // 取消上一个任务，但显式取消一次，上一轮才会明确记成 `.cancelled`（界面「（已停止）」），
        // 而不是等兜底补一个 runEndedWithoutResult。
        if isAgentRunActive {
            Logger.info(
                "AppAgentViewController",
                "sendMessage 打断进行中的一轮: session=\(session.id), turn=\(session.currentTurnID)"
            )
            session.cancel()
        }
        stoppedRunTurn = nil

        // 上一轮的流消费 Task 若还活着，它的事件会继续往列表末尾写过程区。先收掉。
        currentStreamTask?.cancel()
        currentStreamTask = nil

        let userMessage = ChatMessage(role: .user, text: trimmed)
        // 过程区：本轮的思考 / 工具执行时间线，进行中默认展开（参考 Codex CLI / ChatGPT app）。
        var timeline = AppAgentActivityTimeline()
        let assistantMessage = ChatMessage(
            role: .assistant,
            text: "",
            status: .streaming,
            activity: timeline,
            isActivityExpanded: true
        )
        chatMessages.append(userMessage)
        chatMessages.append(assistantMessage)
        chatPanelView.listView.append(
            contentsOf: [userMessage, assistantMessage],
            followLatest: false
        )
        revealChatPanelForNewMessagesIfNeeded()
        scrollToBottom(animated: true)

        // 这一轮的过程区只能写进「发起它的那个会话」的列表里。切走再切回来时列表已经
        // 由 reloadFromSession 重建，旧 Task 若还在跑，写进去的是上一个会话的时间线。
        let boundSessionId = session.id
        let stream = session.sendMessage(trimmed)
        // `run` 同步就把任务挂上了，所以这里已经能读到「在跑」，输入栏立刻可以给出停止按钮。
        refreshInputBarRunState()
        currentStreamTask = Task { @MainActor in
            for await event in stream {
                guard !Task.isCancelled, self.currentSessionId == boundSessionId else { return }
                switch event {
                case .reasoningContent(let delta):
                    timeline.appendThinking(delta)
                    self.applyActivity(timeline)

                case .toolCallStarted(let call):
                    timeline.startTool(
                        id: call.id,
                        name: call.name,
                        argumentsPreview: ChatMessageAssembler.activityDetail(arguments: call.arguments)
                    )
                    self.applyActivity(timeline)

                case .toolCallCompleted(let id, let result):
                    timeline.completeTool(id: id, result: result)
                    self.applyActivity(timeline)

                case .toolCallFailed(let id, let name, let error):
                    timeline.failTool(id: id, name: name, message: error.localizedDescription)
                    self.applyActivity(timeline)

                case .completed, .error:
                    // executor 已写回工具往返和 turnRecord。终局统一从记录重建，
                    // 避免 live timeline 与 isStreaming/runStage 的重建互相覆盖。
                    timeline.finish()
                    self.reloadFromSession(reason: .runningUpdate)

                default:
                    break
                }
            }
            // 流提前断掉（取消 / 释放）时补一次收尾，但同样只在还属于这个会话时写。
            guard !Task.isCancelled, self.currentSessionId == boundSessionId else { return }
            // 流关闭发生在执行器摘掉任务之后：这是「已经不在跑了」最可靠的那一刻。
            self.refreshInputBarRunState()
            if timeline.isRunning {
                timeline.finish()
                self.reloadFromSession(reason: .runningUpdate)
            }
        }
    }

    /// 把最新时间线写回本轮的 agent 气泡并刷新那一行。
    ///
    /// 目标是**最后一条 assistant 消息**，不是最后一行：本轮还没有任何正文时，列表末尾
    /// 是刚插入的用户气泡，写上去过程区就挂到蓝色气泡上了。
    func applyActivity(_ timeline: AppAgentActivityTimeline, expanded: Bool? = nil) {
        guard let session = currentSession,
              let record = session.turnRecord(turnID: session.currentTurnID) else { return }
        guard !record.isFinished else {
            // 事件可能排在终局通知之后被消费；已落盘的终局不能被旧增量覆盖。
            reloadFromSession(reason: .runningUpdate)
            return
        }
        if !chatMessages.contains(where: {
            $0.role == .assistant && $0.turnID == record.turnID && $0.activity?.startedAt == record.startedAt
        }) {
            // 工具事件可能先于 preparing 的主线程通知，先建立带正确 turnID 的气泡。
            reloadFromSession(reason: .runningUpdate)
        }
        guard let index = chatMessages.lastIndex(where: {
            $0.role == .assistant && $0.turnID == record.turnID
        }) else { return }
        // 流式期间写的是「活的」timeline，它自己不知道阶段；用本轮落盘的 turnRecord
        // 补一遍（和 `assemble` 走同一个 `apply`，两条路径口径一致）。不补的话指示条
        // 在每次事件刷新后就没了。
        var timeline = timeline
        if let furthest = chatMessages[index].activity?.furthestStage {
            timeline.setStage(furthest)
        }
        ChatMessageAssembler.apply(record, to: &timeline)
        chatMessages[index].activity = timeline
        // 用户的明确选择优先于自动收尾折叠；不能终止事件刚收起、重建又弹开。
        let turnID = chatMessages[index].turnID
        let preferredExpanded: Bool?
        if let turnID, collapsedActivityTurnIDs.contains(turnID) {
            preferredExpanded = false
        } else if let turnID, expandedActivityTurnIDs.contains(turnID) {
            preferredExpanded = true
        } else {
            preferredExpanded = expanded
        }
        if let expanded = preferredExpanded {
            chatMessages[index].isActivityExpanded = expanded
        }
        chatPanelView.listView.updateActivity(
            timeline,
            expanded: preferredExpanded,
            messageID: chatMessages[index].id
        )
    }

}

#endif
