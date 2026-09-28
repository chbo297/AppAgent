//
//  TurnJournal.swift
//  AppAgent
//

import Foundation

/// 一轮（turn）状态的**唯一写入方**。
///
/// 叫 journal 而不是 reporter：它不是旁观者，而是决定 `.answered` / `.empty` / `.cancelled`、
/// 关闭记录、并保证「每轮恰好一个终止事件」的那一方。只追加、恰好关一次。
///
/// ## 一轮的状态写往四个地方，门控条件是三套不是一套
///
/// - **UI 面**：`session.updateMessages` / `uiState.*` / `agent.sessionDid*`
///   —— 受 `isActive()` 门控。被新 run 抢占之后不许再动界面。
/// - **记录面**：`session.closeTurnRecord` / `persist`
///   —— **无条件执行**。即使已不是 active run，也要关掉**自己的** turnID，
///   否则重启后只剩一条无声空轮（`markUnfinishedTurnsAsInterrupted` 会把它标成中断）。
/// - **事件面**：`continuation.yield(.completed/.error)`
///   —— 过 `claimTerminal()` 去重后无条件发。流的消费者是发起这次 run 的调用方，
///   它有权知道结果，与「谁是 active run」无关。
///
/// 三层写死在这里，调用方就没法只写其中一层。
///
/// **阶段推进是例外**：`advanceStage` 把 uiState 与记录**整体**放在门控内
/// （阶段信息对已被抢占的 run 没有意义），别按终局那三层去改它。
///
/// ## 为什么去重是一个 Bool
///
/// 「这一轮发过终止事件了吗」是 **per-run** 的事实。以前它放在长寿的 `LLMExecutor` 上，
/// 于是必须以 runID 为键、必须有条数上限、必须有淘汰策略 —— 并且真的因为淘汰策略出过一次
/// bug（按 `Set.first` 淘汰，有概率删掉刚登记的当前 run，`defer` 兜底随即误判「没人发过」
/// 补发第二个 `.error`，界面上正常答案后面莫名多一条错误）。
/// journal 本身就是 per-run 的，一个 `Bool` 就够，那套容器连同它的 bug 类别一起消失。
///
/// ## 刻意不做协议
///
/// `contentDelta` 在**每 token** 的路径上，协议会引入 witness table 间接调用。
/// 依赖通过闭包注入，所以测试可以直接 `TurnJournal(session: …, isActive: { true }, persist: { _, _ in })`，
/// 不需要造 `LLMExecutor`。
final class TurnJournal: @unchecked Sendable {

    // MARK: - 依赖（单向：executor → journal，journal 不认识 executor）

    private weak var session: AISession?
    private let continuation: AsyncStream<AIAgentEvent>.Continuation
    /// 「我还是当前那个 run 吗」。runID 已绑进闭包，journal 不必知道它。
    private let isActive: () -> Bool
    /// 写盘。节流口径是 per-session（别太频繁写整份会话 JSON），所以留在 executor，
    /// 不搬进 per-run 的 journal —— 否则两个并发 run 会各写一次/秒。
    private let persist: (AISession, Bool) -> Void

    // MARK: - 可变状态（一律走锁）

    private let lock = ReadersWriterLock()
    private var _hasTerminated = false
    /// `addUserMessage` 之后才有；`nil` 表示这一轮还没登记，记录面整层跳过。
    private var _turnID: Int?
    /// 构造时 agent 还没从 `agentMask` 里解析出来（`run` 要先重置 UI 再校验），所以后置注入。
    /// `nil` 意味着「没有 agent 可回调」，与原先那条出口的行为一致。
    private weak var _agent: AIAgent?

    init(
        session: AISession?,
        continuation: AsyncStream<AIAgentEvent>.Continuation,
        isActive: @escaping () -> Bool,
        persist: @escaping (AISession, Bool) -> Void
    ) {
        self.session = session
        self.continuation = continuation
        self.isActive = isActive
        self.persist = persist
    }

    var turnID: Int? { lock.read { _turnID } }

    func attach(agent: AIAgent) {
        lock.writeSync { _agent = agent }
    }

    /// 登记「终止事件由我发」。返回 false 表示已经发过了，调用方别再发第二个。
    private func claimTerminal() -> Bool {
        lock.writeSync {
            guard !_hasTerminated else { return false }
            _hasTerminated = true
            return true
        }
    }

    // MARK: - 开场

    /// 把 UI 拨到「这一轮刚开始」。
    ///
    /// 必须在校验 provider 之前做，这样早期失败也能在界面上显示出来。
    func prepareUI() {
        guard let session else { return }
        session.uiState.resetStreamingText()
        session.uiState.resetReasoningText()
        session.uiState.setError(nil)
        session.uiState.setRunStage(.preparing)
        session.uiState.setStreaming(true)
    }

    /// 登记这一轮并立刻落盘。
    ///
    /// `outcome == nil` 就是「还在跑」，进程被杀之后恢复时会被标成 `.interrupted`，
    /// 界面上有据可查（见 `AIAgentTurnRecord`）。
    ///
    /// 顺序不必额外守：turnID 只能来自 `session.addUserMessage` 的返回值，
    /// 所以「先落用户消息再开记录」已被类型强制。
    func openTurn(turnID: Int) {
        lock.writeSync { _turnID = turnID }
        session?.openTurnRecord(turnID: turnID, modelRef: nil)
    }

    // MARK: - 阶段

    /// 阶段推进：uiState（给正在看的 UI）与 turnRecord（落盘的事实）一起写。
    ///
    /// 整体受 `isActive()` 门控 —— 与终局那三层不对称门控**刻意不同**：
    /// 阶段信息对已被抢占的 run 没有意义，而终局必须留下交代。
    func advanceStage(_ stage: AIAgentRunStage) {
        guard let session, let turnID, isActive() else { return }
        session.uiState.setRunStage(stage)
        session.advanceTurnStage(turnID: turnID, stage: stage)
        persist(session, false)
    }

    /// 记下这一轮实际使用的模型。
    ///
    /// **不受门控且强制落盘**：模型选择是既成事实，抢占与否都要进记录，
    /// 否则诊断包里看不出这一轮到底打到了哪个端点。
    func recordModel(_ modelRef: String, stage: AIAgentRunStage) {
        guard let session, let turnID else { return }
        session.advanceTurnStage(turnID: turnID, stage: stage, modelRef: modelRef)
        persist(session, true)
    }

    /// 执行循环的轮次计数（只增不减，终局后冻结）。
    func advanceRound(_ round: Int) {
        guard let session, let turnID else { return }
        session.advanceTurnRound(turnID: turnID, roundCount: round)
        persist(session, false)
    }

    // MARK: - 流式内容

    /// 正文 delta。
    ///
    /// 三步顺序是契约，别调：`yield` → `advanceStage(.streaming)` → `uiState.append`。
    /// `advanceStage` 会触发 UI 的一次重建，而那次重建读到的 `streamingText`
    /// **不包含**当前这个 delta —— 顺序换了就改变了首帧行为。
    func contentDelta(_ delta: String) {
        continuation.yield(.streamingContent(delta))
        advanceStage(.streaming)
        if let session, isActive() {
            session.uiState.appendStreamingText(delta)
        }
    }

    /// 思考 delta：只用于展示，不写进消息历史。顺序同 `contentDelta`。
    func reasoningDelta(_ delta: String) {
        continuation.yield(.reasoningContent(delta))
        advanceStage(.streaming)
        if let session, isActive() {
            session.uiState.appendReasoningText(delta)
        }
    }

    /// 重试 / 模型回退前丢掉上一次尝试已经吐出来的正文。
    ///
    /// 不清的话，换模型重跑这一轮时界面上会把两次尝试的正文接在一起。
    func attemptDiscarded() {
        guard let session, isActive() else { return }
        session.uiState.resetStreamingText()
        session.uiState.resetReasoningText()
    }

    // MARK: - 终局（三个唯一出口）

    /// 正常收尾。有正文是 `.answered`，一个字都没有是 `.empty`
    /// （UI 显示「本轮没有返回任何内容」，而不是一个空气泡）。
    func answered(_ result: AIAgentFinish) {
        let turnID = self.turnID
        if let session, isActive() {
            session.updateMessages(result.updatedMessages)
            session.uiState.setRunStage(.finished)
            session.uiState.setStreaming(false)
            session.uiState.resetStreamingText()
            lock.read { _agent }?.sessionDidCompleteRun(session, result: result)
        }
        if let session, let turnID {
            session.closeTurnRecord(
                turnID: turnID,
                outcome: result.text.isEmpty ? .empty : .answered,
                stage: .finished
            )
            persist(session, true)
        }
        guard claimTerminal() else { return }
        continuation.yield(.completed(result))
    }

    /// 失败收尾。`messages == nil` 表示「别动消息列表」（请求还没发出去的早期失败）。
    ///
    /// 失败阶段停在出错的那一步，**不推进 `.finished`**：UI 只把那一格标红，
    /// 「卡在哪一步」是排查里最有用的一条信息。
    func failed(_ error: Error, messages: [AIAgentMessage]? = nil) {
        let turnID = self.turnID
        let stage = currentStage(turnID: turnID)

        if let session, isActive() {
            if let messages {
                session.updateMessages(messages)
            }
            session.uiState.setFailedStage(stage)
            session.uiState.setStreaming(false)
            session.uiState.setError(error)
            lock.read { _agent }?.sessionDidEncounterError(session, error: error)
        }
        if let session, let turnID {
            // 用户主动停止和真失败要分开：界面上一个是「（已停止）」，一个是红色的失败。
            let isCancelled: Bool
            if case .cancelled = (error as? AIAgentError) { isCancelled = true } else { isCancelled = false }
            session.closeTurnRecord(
                turnID: turnID,
                outcome: isCancelled
                    ? .cancelled
                    : .failed(stage: stage, message: error.localizedDescription)
            )
            persist(session, true)
        }
        guard claimTerminal() else { return }
        continuation.yield(.error(error))
    }

    /// `run` 的 `defer` 兜底：走到这里还没发过终止事件，说明有条出口漏了
    /// （或者中途抛了没人接的错）。这时必须把 UI 从「进行中」里拽出来并补一个 `.error`，
    /// 否则界面会永远停在 "…" —— 真机上踩过。
    ///
    /// 与 `failed` 的关键差别：**先**认领终止权。已经有正经终局的话这里一个字都不许写，
    /// 否则会把真实终局覆盖成「兜底失败」（`testManyRunsInOneSessionEmitExactlyOneTerminalEventEach`
    /// 的 `lastError == nil` 就锁这条）。
    func finalizeIfNeeded() {
        guard claimTerminal() else { return }
        let error = AIAgentError.runEndedWithoutResult
        Logger.error("TurnJournal", "run ended without a terminal event; synthesizing .error")
        AppAgentDebugLog.shared.record(
            .failure,
            message: "本轮没有产出终止事件，已兜底结束（stage=\(session?.uiState.runStage?.logLabel ?? "-")）",
            sessionId: session?.id,
            reason: "noTerminalEvent"
        )
        if let session, let turnID {
            let stage = session.turnRecord(turnID: turnID)?.stage ?? .preparing
            if isActive() {
                session.uiState.setFailedStage(stage)
                session.uiState.setStreaming(false)
                session.uiState.setError(error)
            }
            // 即使已不是 active run，也只能关闭**自己的** turnID，不能读 currentTurnID。
            session.closeTurnRecord(
                turnID: turnID,
                outcome: .failed(stage: stage, message: error.localizedDescription)
            )
            persist(session, true)
        }
        continuation.yield(.error(error))
    }

    /// 这一轮当前停在哪一步。没有 turnID（早期失败）就按 `.preparing` 算 ——
    /// 不能拿哨兵编号去查记录，编号策略一变就会误读到别的轮次。
    private func currentStage(turnID: Int?) -> AIAgentRunStage {
        guard let turnID, let record = session?.turnRecord(turnID: turnID) else { return .preparing }
        return record.stage
    }
}
