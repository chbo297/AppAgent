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
                inputBar.setInputEnabled(true)
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
                inputBar.setInputEnabled(true)
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

        inputBar.clearText()
        inputBar.setInputEnabled(false)

        let userMessage = ChatMessage(role: .user, text: trimmed)
        let assistantMessage = ChatMessage(role: .assistant, text: "", status: .streaming)
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
            for await _ in stream {
                // Events are handled via uiState.onChange binding
            }
        }
    }
}

#endif
