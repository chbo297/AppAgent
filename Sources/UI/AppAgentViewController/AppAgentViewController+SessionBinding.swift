//
//  AppAgentViewController+SessionBinding.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

// MARK: - Session ↔ UI

extension AppAgentViewController {
    /// 从当前 session 重建唯一的 ChatPanel 消息列表。
    public func reloadFromSession() {
        guard let session = currentSession else {
            chatMessages = []
            if isViewLoaded { chatPanelView.listView.setMessages([]) }
            return
        }

        chatMessages = session.messages.map { Self.toChatMessage($0) }

        if session.isRunning {
            let streamText = session.uiState.streamingText
            chatMessages.append(ChatMessage(role: .assistant, text: streamText, status: .streaming))
        }

        // 复原最近一轮的过程区（只认当前会话的快照）。
        if let snapshot = lastTurnActivity,
           snapshot.sessionID == session.id,
           !snapshot.timeline.isEmpty,
           let index = chatMessages.lastIndex(where: { $0.role == .assistant }) {
            chatMessages[index].activity = snapshot.timeline
            chatMessages[index].isActivityExpanded = snapshot.expanded
        }

        if isViewLoaded {
            chatPanelView.listView.setMessages(chatMessages)
        }
    }

    /// Convert an AIAgentMessage to a UI ChatMessage.
    public static func toChatMessage(_ msg: AIAgentMessage) -> ChatMessage {
        let role: ChatMessage.Role = msg.role == .user ? .user : .assistant
        var text = msg.text
        var toolInfo: String?

        let calls = msg.toolCalls
        if !calls.isEmpty {
            let names = calls.map { $0.name }.joined(separator: ", ")
            toolInfo = "Tools: \(names)"
            if text.isEmpty {
                text = "[Tool call: \(names)]"
            }
        }

        let results = msg.content.compactMap { content -> String? in
            if case .toolResult(let r) = content {
                let preview = r.content.prefix(100)
                return "Result: \(preview)\(r.content.count > 100 ? "..." : "")"
            }
            return nil
        }
        if !results.isEmpty && text.isEmpty {
            text = results.joined(separator: "\n")
        }

        return ChatMessage(role: role, text: text, toolInfo: toolInfo)
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
            guard !chatMessages.isEmpty,
                  chatMessages[chatMessages.count - 1].status == .streaming else { return }
            chatMessages[chatMessages.count - 1].text = session.uiState.streamingText
            chatPanelView.listView.updateLastMessage(
                text: session.uiState.streamingText,
                status: .streaming
            )

        case "isStreaming":
            if !session.uiState.isStreaming {
                reloadFromSession()
            }

        case "lastError":
            if let error = session.uiState.lastError {
                guard !chatMessages.isEmpty,
                      chatMessages[chatMessages.count - 1].role == .assistant else { return }
                chatMessages[chatMessages.count - 1].text = "Error: \(error.localizedDescription)"
                chatMessages[chatMessages.count - 1].status = .error
                chatPanelView.listView.updateLastMessage(
                    text: "Error: \(error.localizedDescription)",
                    status: .error
                )
            }

        default:
            break
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

        let stream = session.sendMessage(trimmed)
        currentStreamTask = Task { @MainActor in
            for await event in stream {
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
            if timeline.isRunning {
                timeline.finish()
                self.applyActivity(timeline, expanded: false)
            }
        }
    }

    /// 把最新时间线写回当前流式消息并刷新那一行。
    private func applyActivity(_ timeline: AppAgentActivityTimeline, expanded: Bool? = nil) {
        guard let index = chatMessages.indices.last else { return }
        chatMessages[index].activity = timeline
        if let expanded = expanded {
            chatMessages[index].isActivityExpanded = expanded
        }
        if let sessionID = currentSessionId {
            lastTurnActivity = (
                sessionID: sessionID,
                timeline: timeline,
                expanded: expanded ?? chatMessages[index].isActivityExpanded
            )
        }
        chatPanelView.listView.updateLastActivity(timeline, expanded: expanded)
    }

    /// 工具参数 / 结果的一行预览（过长截断，避免过程区吃掉整屏）。
    static func preview(of arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "" }
        let text = arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.compact(String(describing: $0.value)))" }
            .joined(separator: ", ")
        return Self.compact(text)
    }

    static func preview(of output: Tool.Output) -> String {
        switch output {
        case .text(let text): return Self.compact(text)
        case .json(let value): return Self.compact(String(describing: value))
        case .error(let message): return "错误：\(Self.compact(message))"
        }
    }

    private static func compact(_ text: String, limit: Int = 160) -> String {
        let single = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count <= limit ? single : String(single.prefix(limit)) + "…"
    }
}


#endif
