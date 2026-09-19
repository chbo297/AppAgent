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

// MARK: - Session ↔ UI

extension AppAgentViewController {
    /// 从当前 session 重建唯一的 ChatPanel 消息列表。
    ///
    /// 列表不再按 wire 消息一条条铺开，而是按「一次提问」组装：用户气泡只放用户真的
    /// 说过的话，agent 的工具往返与中间思考全部收进它自己的过程区（见
    /// `ChatMessageAssembler`）。过程区直接由记录推导，所以切换会话、重启 App
    /// 之后历史里每一轮的过程都还在，可点开查看。
    ///
    /// 失败原因不在 wire 记录里，所以从 `uiState.lastError` 单独带给组装器——不然
    /// 「没配 API Key」这类一步都没跑起来的失败会因为那一轮空无一物而被丢掉。
    ///
    /// - Parameter forceScrollToBottom: 换会话 / 首次装载传 true；每轮结束的常规重建
    ///   传 false，避免把正在翻历史的用户拽回底部。
    public func reloadFromSession(forceScrollToBottom: Bool = false) {
        guard let session = currentSession else {
            chatMessages = []
            if isViewLoaded { chatPanelView.listView.setMessages([]) }
            return
        }

        chatMessages = ChatMessageAssembler.assemble(
            session.messages,
            streamingText: session.isRunning ? session.uiState.streamingText : "",
            isRunning: session.isRunning,
            errorText: session.uiState.lastError.map { "Error: \($0.localizedDescription)" },
            expandedTurnIDs: expandedActivityTurnIDs
        )

        if isViewLoaded {
            chatPanelView.listView.setMessages(
                chatMessages,
                forceScrollToBottom: forceScrollToBottom
            )
        }
    }

    /// 用户手动折叠 / 展开某一轮的过程区：记在 turnID 上，重建列表时照旧。
    func handleActivityToggled(_ message: ChatMessage) {
        if let index = chatMessages.firstIndex(where: { $0.id == message.id }) {
            chatMessages[index].isActivityExpanded = message.isActivityExpanded
        }
        guard let turnID = message.turnID else { return }
        if message.isActivityExpanded {
            expandedActivityTurnIDs.insert(turnID)
        } else {
            expandedActivityTurnIDs.remove(turnID)
        }
    }

    func bindUIState() {
        guard let session = currentSession else { return }
        session.uiState.onChange = { [weak self] key in
            Task { @MainActor [weak self] in
                self?.handleUIStateChange(key: key)
            }
        }
    }

    func handleUIStateChange(key: String) {
        guard let session = currentSession else { return }
        switch key {
        case "streamingText":
            // 定位口径和 `applyActivity` 一致：写「最后一条 assistant 气泡」，不是
            // 「最后一行」——本轮还没吐正文时列表末尾是刚插入的用户气泡。
            guard let index = chatMessages.lastIndex(where: { $0.role == .assistant }),
                  chatMessages[index].status == .streaming else { return }
            let streamingText = session.uiState.streamingText
            chatMessages[index].text = streamingText
            chatPanelView.listView.updateMessage(
                text: streamingText,
                status: .streaming,
                messageID: chatMessages[index].id
            )

        case "isStreaming":
            if !session.uiState.isStreaming {
                // 本轮结束：用组装器重建列表，走 errorText 参数把错误挂到最后一轮上。
                // 不用 forceScrollToBottom，让翻历史的用户不被拽回底部。
                reloadFromSession()
            }

        case "lastError":
            // 错误通过 assemble(errorText:) 挂进最后一轮的 assistant 气泡。
            // 若 `isStreaming` 已经先变为 false（通常是），上面的分支已经重建过了；
            // 但 `setStreaming(false)` 和 `setError` 是两次独立的 dispatchCallback，
            // 先后顺序不保证，也有「error 先到、isStreaming 后到」的可能——所以这里
            // 无条件再 reload 一遍，幂等无害。
            reloadFromSession()

        case SessionUIState.pendingDecisionKey:
            // 安全网：没人在等了但卡片还挂着（工具放弃等待 / 请求被别人答了），撤掉它。
            if session.uiState.pendingDecision == nil,
               let id = currentSessionId,
               pendingDecisions[id]?.isEmpty ?? true {
                chatPanelView.dismissDecision()
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

    /// VC 要销毁了：把还在排队的请求按兜底语义答复掉。
    ///
    /// 不做的话那些 `CheckedContinuation` 会带着未恢复状态析构（运行时报
    /// "leaked its continuation"），发起它们的那一轮 executor 永远回不来。
    func drainPendingDecisions() {
        let queues = pendingDecisions
        pendingDecisions.removeAll()
        for (_, queue) in queues {
            for pending in queue {
                pending.complete(Self.fallbackOutcome(for: pending.request))
            }
        }
    }

    /// 没人能回答时的结果，与 Core 的兜底保持一致：授权类拒绝，澄清类当作没回答。
    static func fallbackOutcome(for request: DecisionRequest) -> DecisionOutcome {
        switch request {
        case .privateNetworkAccess, .toolAuthorization: return .deny
        case .clarification: return .answer(nil)
        }
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
        chatPanelView.dismissDecision()
        presentPendingDecision(for: sessionId)
    }

    /// 把某个会话队首的卡片贴出来。呈现不了时返回 false（不动队列，下次切回来还能再试）。
    @discardableResult
    func presentPendingDecision(for sessionId: String) -> Bool {
        guard let pending = pendingDecisions[sessionId]?.first else { return false }
        return chatPanelView.presentDecision(pending.request) { [weak self] outcome in
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
    }

    func sendMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = currentSession else { return }

        // 并行上限预检：达到上限时在任何乐观 UI 之前硬阻断（既不追加气泡也不禁用输入）。
        // AISession.sendMessage 会作为权威闸门再次复检（防御性双重校验）。
        if let agent = agent, !agent.sessionManager.canAdmitRun(for: session) {
            let limit = agent.sessionManager.governor.limit
            Logger.info("AppAgentViewController", "sendMessage 被并行上限拦截: limit=\(limit)")
            return
        }

        // 模型运行中不禁用输入栏：用户可以继续输入、切换输入方式或打开菜单。
        inputBar.clearText()

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
                        argumentsPreview: Self.preview(of: call.arguments)
                    )
                    self.applyActivity(timeline)

                case .toolCallCompleted(let id, let result):
                    timeline.finishTool(id: id, resultPreview: Self.preview(of: result))
                    self.applyActivity(timeline)

                case .toolCallFailed(let id, let name, let error):
                    timeline.failTool(id: id, name: name, message: error.localizedDescription)
                    self.applyActivity(timeline)

                case .completed, .error:
                    // 本轮结束：过程折叠成「已思考 x 秒 · N 步」摘要，气泡里展示最终结果。
                    timeline.finish()
                    self.applyActivity(timeline, expanded: false)

                default:
                    break
                }
            }
            // 流提前断掉（取消 / 释放）时补一次收尾，但同样只在还属于这个会话时写。
            guard !Task.isCancelled, self.currentSessionId == boundSessionId else { return }
            if timeline.isRunning {
                timeline.finish()
                self.applyActivity(timeline, expanded: false)
            }
        }
    }

    /// 把最新时间线写回本轮的 agent 气泡并刷新那一行。
    ///
    /// 目标是**最后一条 assistant 消息**，不是最后一行：本轮还没有任何正文时，列表末尾
    /// 是刚插入的用户气泡，写上去过程区就挂到蓝色气泡上了。
    private func applyActivity(_ timeline: AppAgentActivityTimeline, expanded: Bool? = nil) {
        guard let index = chatMessages.lastIndex(where: { $0.role == .assistant }) else { return }
        chatMessages[index].activity = timeline
        if let expanded = expanded {
            chatMessages[index].isActivityExpanded = expanded
        }
        chatPanelView.listView.updateActivity(
            timeline,
            expanded: expanded,
            messageID: chatMessages[index].id
        )
    }

    /// 工具参数 / 结果的一行预览（实现见 `ChatMessageAssembler`，两处共用同一套截断规则）。
    static func preview(of arguments: [String: JSONValue]) -> String {
        ChatMessageAssembler.preview(arguments: arguments)
    }

    static func preview(of output: Tool.Output) -> String {
        ChatMessageAssembler.preview(output: output)
    }
}

#endif
