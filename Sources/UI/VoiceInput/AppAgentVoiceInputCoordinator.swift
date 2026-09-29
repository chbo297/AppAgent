//
//  AppAgentVoiceInputCoordinator.swift
//  AppAgentUI
//

#if canImport(UIKit)
import UIKit

/// 语音输入的渲染状态：手势阶段 overlay 所需的全部展示信息。
struct AppAgentVoiceInputRenderState {
    /// 手指状态：当前手指在宿主坐标系中的位置。
    var fingerLocation: CGPoint

    /// 识别状态：语音识别在 UI 上呈现为未开始、加载中或录音中。
    var recognitionState: AppAgentVoiceRecognitionVisualState = .loading

    /// 抬起行为：当前手指位置对应的松手后动作。
    var releaseAction: AppAgentVoiceInputReleaseAction = .send

    /// 识别文本：语音识别管理器实时返回的文本内容。
    var transcriptText = ""

    /// 实时音量（0…1）：录音态波形据此起伏，反映声音大小随时间变化。
    var audioLevel: Double = 0

    var showsTranscriptCursor: Bool {
        !transcriptText.isEmpty
    }
}

/// 语音输入时序参数：松手后继续采集的尾音时长、等待最终识别结果的上限。
struct AppAgentVoiceInputTimings {
    /// 松手后继续采集尾音的时长（send / edit 才等；cancel 不等）。
    var trailingCapture: TimeInterval

    /// 停止喂音频后，等识别器吐出最终结果的上限；到点用当前最好文本收尾。
    var finalizationTimeout: TimeInterval

    /// 预热后既没正式开始也没取消的看门狗时限：到点自动放弃预热，避免麦克风长挂。
    var prewarmWatchdog: TimeInterval

    /// 最终文本写进气泡后、关闭面板前的停留时长：至少覆盖一帧/一次 runloop，
    /// 保证用户能看到识别出来的那句话，而不是一闪而过。
    var finalTextRenderHold: TimeInterval = 0.02

    /// 面板亮起到松手的最短有效时长：比这还短就算误触，直接取消、不留尾音也不等最终结果。
    /// 0 表示不做这道闸（单测用）。
    var minimumValidPress: TimeInterval = 0.3

    /// 生产默认：松手后多录 0.3s 尾音，再等最终结果最多 1.2s（最坏 1.5s 关面板）；预热看门狗 1.5s；
    /// 面板亮起不足 0.3s 就松手按误触处理。
    static let standard = AppAgentVoiceInputTimings(trailingCapture: 0.3, finalizationTimeout: 1.2, prewarmWatchdog: 1.5)

    /// 仅「等最终结果、不延长尾音」——用于只验证「不丢」的场景与单测；不判误触，方便同步 begin → end。
    static let phase1 = AppAgentVoiceInputTimings(
        trailingCapture: 0, finalizationTimeout: 1.2, prewarmWatchdog: 1.5, minimumValidPress: 0
    )
}

/// 语音输入触觉反馈的抽象：协调器只表达“何时震动”，不关心震动如何实现。
protocol AppAgentVoiceInputFeedbackProviding {
    func prepare()
    func impact(reason: String)
}

/// 默认触觉反馈实现：UIImpactFeedbackGenerator，保留日志便于对照调试。
struct AppAgentVoiceInputHapticFeedback: AppAgentVoiceInputFeedbackProviding {
    let generator: UIImpactFeedbackGenerator

    func prepare() {
        generator.prepare()
    }

    func impact(reason: String) {
        print("[AppAgentVoiceInput] haptic impact reason=\(reason)")
        generator.prepare()
        generator.impactOccurred(intensity: 1)
    }
}

/// 协调器 → 宿主的输出：宿主负责把这些语义映射到 overlay / inputBar / session。
/// 纯 UI 协议：所有回调都在主线程发生，实现方也都是 UIViewController / UIView。
/// 标 `@MainActor` 之后，实现里访问视图才是编译器认可的，而不是靠约定。
@MainActor
protocol AppAgentVoiceInputCoordinatorDelegate: AnyObject {
    /// 手势开始：宿主应展示语音输入面板。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didBeginAt location: CGPoint)

    /// 渲染状态变化：宿主应把 renderState 同步给 overlay。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didUpdate renderState: AppAgentVoiceInputRenderState)

    /// 松手编辑：宿主应让 overlay 进入编辑态（面板保持展示）。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didEnterEditModeWith text: String)

    /// 松手发送 / 编辑态点击发送：宿主应把文本作为消息发出。
    func voiceInput(_ coordinator: AppAgentVoiceInputCoordinator, didRequestSend text: String)

    /// 本次语音输入结束：宿主应隐藏语音输入面板。
    func voiceInputDidFinish(_ coordinator: AppAgentVoiceInputCoordinator)
}

/// 语音输入协调器：一次语音输入（按下 → 移动 → 松手 → 可选编辑收尾）的唯一状态主人。
///
/// 边界约定：
/// - 输入：宿主转发的手势值事件、overlay 编辑态回调；
/// - 依赖：识别管理器（事件流）、releaseActionResolver（几何判定留在视图层）、触觉反馈抽象；
/// - 输出：delegate 语义回调，不直接触碰任何视图。
///
/// 主线程使用；识别事件流由管理器保证主线程投递。
@MainActor
final class AppAgentVoiceInputCoordinator {

    weak var delegate: AppAgentVoiceInputCoordinatorDelegate?

    /// 几何判定注入：手指位置 → 松手行为。由 overlay 提供（视图是自身几何的唯一权威）。
    var releaseActionResolver: ((CGPoint) -> AppAgentVoiceInputReleaseAction)?

    /// 手势阶段的渲染状态；nil 表示当前没有进行中的语音手势（含已交接给编辑态）。
    private(set) var renderState: AppAgentVoiceInputRenderState?

    var isActive: Bool {
        renderState != nil
    }

    private let recognitionManager: AppAgentVoiceRecognitionProviding
    private let feedback: AppAgentVoiceInputFeedbackProviding
    private let timings: AppAgentVoiceInputTimings
    private var recognitionTask: Task<Void, Never>?

    /// 预热中：识别已启动但面板未展示、尚未决定是否正式开始。
    private var isPrewarming = false
    private var prewarmWatchdogTask: Task<Void, Never>?

    /// 松手后正在等待最终识别结果的收尾动作；nil 表示当前没有在收尾。
    /// send / edit 松手后进入收尾（等 `.ended` 带最终文本），cancel 不进入。
    private var finalizeAction: AppAgentVoiceInputReleaseAction?

    /// 「最终文本已上屏、等一帧再关面板」的延时任务。
    private var finishHoldTask: Task<Void, Never>?

    /// 面板亮起（`begin`）的时刻，用来判定松手是不是快到算误触。
    private var gestureBeganAt: TimeInterval?

    /// 取时间的钩子：单测注入假时钟，生产用参考时间。
    private let now: () -> TimeInterval

    init(
        recognitionManager: AppAgentVoiceRecognitionProviding = AppAgentVoiceRecognitionManager.shared,
        feedback: AppAgentVoiceInputFeedbackProviding,
        timings: AppAgentVoiceInputTimings = .standard,
        now: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    ) {
        self.recognitionManager = recognitionManager
        self.feedback = feedback
        self.timings = timings
        self.now = now
    }

    deinit {
        recognitionTask?.cancel()
        prewarmWatchdogTask?.cancel()
        finishHoldTask?.cancel()
    }

    // MARK: - 预热（touchDown 抢跑）

    /// touchDown 预热：仅在系统权限已授权且没有其他音频在放时，提前启动识别，
    /// 面板不展示、不发任何 delegate 事件。正式开始（`begin`）会复用这条已起的识别。
    func prewarm(source: AppAgentInputBarVoiceInputSource) {
        guard !isActive, finalizeAction == nil, !isPrewarming else { return }
        guard recognitionManager.canPrewarmNow else { return }
        isPrewarming = true
        startRecognitionIfNeeded()
        prewarmWatchdogTask?.cancel()
        let deadline = timings.prewarmWatchdog
        prewarmWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isPrewarming else { return }
            self.abortPrewarm()
        }
    }

    /// 取消预热：短按等未转成正式语音输入时调用；停识别、丢弃预热文本，不发任何 delegate 事件。
    func abortPrewarm() {
        guard isPrewarming else { return }
        isPrewarming = false
        prewarmWatchdogTask?.cancel()
        prewarmWatchdogTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionManager.requestStopRecording(reason: .cancelled)
    }

    // MARK: - 手势输入

    /// 手势开始：建立本次语音输入状态、启动识别（复用预热），并请求宿主展示面板。
    func begin(source: AppAgentInputBarVoiceInputSource, location: CGPoint) {
        prewarmWatchdogTask?.cancel()
        prewarmWatchdogTask = nil
        isPrewarming = false
        // 上一次「等一帧再关面板」还没落地就又开始了新手势：直接作废，别让它把新面板关掉。
        finishHoldTask?.cancel()
        finishHoldTask = nil
        var state = AppAgentVoiceInputRenderState(fingerLocation: location)
        // 预热已让识别提前就绪时，那条 `.recording` 事件在预热期已被丢弃；展示面板时直接读当前录音状态，
        // 初始态就置为「录音中」，避免面板卡在 loading 转圈。
        if recognitionManager.isRecording {
            state.recognitionState = .recording
        }
        renderState = state
        gestureBeganAt = now()
        startRecognitionIfNeeded()
        delegate?.voiceInput(self, didBeginAt: location)
        render()
        feedback.impact(reason: beginHapticReason(for: source))
        // 预热选区切换反馈，让后续滑入取消/编辑/发送区域的震动更及时。
        feedback.prepare()
    }

    /// 手势移动：按当前位置重新判定“此刻抬起会执行什么行为”。
    func move(to location: CGPoint) {
        guard finalizeAction == nil else { return }
        refreshReleaseAction(location: location)
    }

    /// 手势抬起：用最终位置刷新行为后，按 send/cancel/edit 收尾。
    func end(at location: CGPoint) {
        guard isActive, finalizeAction == nil else { return }
        // 面板还没亮满 0.3s 就松手：算误触，这次交互当没发生过——直接取消识别、立刻关面板，
        // 既不走「多录尾音 + 等最终结果」的收尾，也不发送、不进编辑态。
        if isPressTooShortToBeValid {
            finishInvalidShortPress()
            return
        }
        refreshReleaseAction(location: location)

        switch renderState?.releaseAction ?? .cancel {
        case .send:
            finishSend()
        case .cancel:
            finishCancel()
        case .edit:
            finishEdit()
        }
    }

    /// 松手太快（面板展示不足 `timings.minimumValidPress`）= 误触，不算一次语音输入。
    private var isPressTooShortToBeValid: Bool {
        guard timings.minimumValidPress > 0, let began = gestureBeganAt else { return false }
        return now() - began < timings.minimumValidPress
    }

    /// 系统取消/手势失败：刷新位置保持 UI 一致后统一按取消收尾（取消不等尾音）。
    func systemCancel(at location: CGPoint) {
        guard isActive else { return }
        refreshReleaseAction(location: location)
        finishCancel()
    }

    /// 宿主 API：外部更新实时识别文本（不改变手指当前选择的抬起行为）。
    func updateTranscript(_ text: String) {
        guard var state = renderState else { return }
        state.transcriptText = text
        renderState = state
        render()
    }

    // MARK: - 编辑态收尾（overlay 回调经宿主转入）

    func editCancel() {
        feedback.impact(reason: "edit-cancel")
        delegate?.voiceInputDidFinish(self)
    }

    func editSend(text: String) {
        feedback.impact(reason: "edit-send")
        delegate?.voiceInputDidFinish(self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        delegate?.voiceInput(self, didRequestSend: trimmed)
    }

    // MARK: - 识别事件

    private func startRecognitionIfNeeded() {
        // 幂等：预热已起的识别，正式开始时直接复用，不重启（重启会丢掉预热已识别的音频）。
        guard recognitionTask == nil else { return }
        let events = recognitionManager.startRecording()
        recognitionTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.handleRecognitionEvent(event)
            }
        }
    }

    /// 识别事件只影响 loading/recording 展示与文本，不能覆盖手指当前选择的 send/cancel/edit。
    private func handleRecognitionEvent(_ event: AppAgentVoiceRecognitionEvent) {
        // 预热期：面板未展示，只维持识别；意外结束就清预热态，不触碰面板。
        if isPrewarming {
            if case .ended = event {
                isPrewarming = false
                prewarmWatchdogTask?.cancel()
                prewarmWatchdogTask = nil
                recognitionTask = nil
            }
            return
        }
        switch event {
        case .loading:
            guard var state = renderState else { return }
            state.recognitionState = .loading
            renderState = state
            render()
        case .recording(let context):
            guard var state = renderState else { return }
            state.recognitionState = .recording
            state.transcriptText = context.combinedText
            state.audioLevel = context.audioLevel
            renderState = state
            render()
        case .ended(let context):
            recognitionTask = nil
            // 松手发送 / 编辑正在等最终结果：用识别器给出的最终文本收尾，保证不丢。
            if let action = finalizeAction {
                finalizeAction = nil
                completeFinalize(action: action, finalText: context.finalText)
                return
            }
            // 手势仍进行中时识别意外结束（权限拒绝/中断等），按结束收尾；
            // 已交接给编辑态（renderState == nil）时不再干预面板。
            guard isActive else { return }
            finish()
        }
    }

    private func stopRecognition(reason: AppAgentVoiceRecognitionEndReason) {
        recognitionManager.requestStopRecording(reason: reason)
    }

    // MARK: - 收尾

    /// 松手落在发送区：不立即停止，先请求优雅收尾（继续采集尾音 + 等最终结果），
    /// 待识别器给出最终文本后再隐藏面板并发送（在 `.ended` → `completeFinalize` 里）。
    private func finishSend() {
        feedback.impact(reason: "stop-send")
        beginFinalize(action: .send)
    }

    private func finishCancel() {
        feedback.impact(reason: "stop-cancel")
        finalizeAction = nil
        stopRecognition(reason: .cancelled)
        finish()
    }

    /// 误触收尾：不刷新松手区域、不再补一次震动（按下那一下已经震过），识别按取消停掉，面板立即关闭。
    private func finishInvalidShortPress() {
        print("[AppAgentVoiceInput] invalid short press, dismiss without capture")
        finalizeAction = nil
        stopRecognition(reason: .cancelled)
        finish()
    }

    /// 松手落在编辑区：同样等最终结果，拿到最终文本后再进编辑态（面板保留）。
    private func finishEdit() {
        feedback.impact(reason: "stop-edit")
        beginFinalize(action: .edit)
    }

    /// 进入收尾：面板切到 loading（保持展示，冻结当前松手动作），请求识别器优雅收尾；
    /// 真正的发送/编辑在 `.ended` 到达后执行。
    private func beginFinalize(action: AppAgentVoiceInputReleaseAction) {
        finalizeAction = action
        if var state = renderState {
            state.recognitionState = .finalizing
            renderState = state
            render()
        }
        recognitionManager.requestFinishRecording(
            trailingCapture: timings.trailingCapture,
            finalizationTimeout: timings.finalizationTimeout
        )
    }

    /// 收尾完成：识别器已给出最终文本，按当初松手的动作发送或进编辑态。
    private func completeFinalize(action: AppAgentVoiceInputReleaseAction, finalText: String) {
        switch action {
        case .send:
            // 顺序刻意如此：先把最终文本刷到气泡上（让用户看到识别结果），同时把消息交给 agent，
            // 面板留到最终文本真正渲染出来之后再关——直接 finish() 会让最终结果一闪而过甚至完全看不到。
            presentFinalTranscript(finalText)
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                delegate?.voiceInput(self, didRequestSend: trimmed)
            }
            finishAfterFinalTranscriptRendered()
        case .edit:
            // 手势语音阶段结束；renderState 置空后识别 ended 事件不会再触发 didFinish，
            // 编辑态由 overlay 驱动、经 editCancel/editSend 收尾。
            renderState = nil
            delegate?.voiceInput(self, didEnterEditModeWith: finalText)
        case .cancel:
            // 不会进入收尾，保底按结束处理。
            finish()
        }
    }

    /// 把最终文本写进气泡并渲染：收尾波浪停下，气泡只剩识别出来的那句话。
    private func presentFinalTranscript(_ text: String) {
        guard var state = renderState else { return }
        state.recognitionState = .none
        state.transcriptText = text
        state.audioLevel = 0
        renderState = state
        render()
    }

    /// 等最终文本至少渲染一帧/一次 runloop 之后再关闭面板。
    private func finishAfterFinalTranscriptRendered() {
        let hold = max(0, timings.finalTextRenderHold)
        finishHoldTask?.cancel()
        finishHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func finish() {
        finishHoldTask?.cancel()
        finishHoldTask = nil
        gestureBeganAt = nil
        renderState = nil
        delegate?.voiceInputDidFinish(self)
    }

    // MARK: - 内部

    private func refreshReleaseAction(location: CGPoint) {
        guard var state = renderState else { return }
        let previousAction = state.releaseAction
        let nextAction = releaseActionResolver?(location) ?? previousAction
        state.fingerLocation = location
        state.releaseAction = nextAction
        renderState = state
        if previousAction != nextAction {
            print("[AppAgentVoiceInput] selectedAction \(previousAction) -> \(nextAction), location=\(location)")
            feedback.impact(reason: selectionHapticReason(for: nextAction))
        }
        render()
    }

    private func render() {
        guard let renderState else { return }
        delegate?.voiceInput(self, didUpdate: renderState)
    }

    private func beginHapticReason(for source: AppAgentInputBarVoiceInputSource) -> String {
        switch source {
        case .keyboardModeLongPress:
            return "start-keyboard-mode-long-press"
        case .voiceModePress:
            return "start-voice-mode-press"
        }
    }

    private func selectionHapticReason(for action: AppAgentVoiceInputReleaseAction) -> String {
        switch action {
        case .send:
            return "select-send"
        case .cancel:
            return "select-cancel"
        case .edit:
            return "select-edit"
        }
    }
}

#endif
