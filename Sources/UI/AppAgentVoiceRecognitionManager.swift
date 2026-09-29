//
//  AppAgentVoiceRecognitionManager.swift
//  AppAgentUI
//

#if canImport(AVFoundation) && canImport(Speech) && (os(iOS) || targetEnvironment(macCatalyst))
import AVFoundation
import Foundation
import Speech

public enum AppAgentVoiceRecognitionLoadingReason: Sendable {
    case requestingSpeechPermission
    case requestingMicrophonePermission
    case preparingAudioSession
    case waitingForRecognizer
}

public struct AppAgentVoiceRecognitionLoadingContext: Sendable {
    public let reason: AppAgentVoiceRecognitionLoadingReason
    public let timestamp: TimeInterval
}

public struct AppAgentVoiceRecognitionRecordingContext: Sendable {
    public let partialText: String
    public let finalText: String
    public let combinedText: String
    public let audioLevel: Double
    public let timestamp: TimeInterval
}

public enum AppAgentVoiceRecognitionEndReason: Sendable {
    case userStopped
    case cancelled
    case interrupted
    case permissionDenied
    case recognizerUnavailable
    case audioSessionUnavailable
    case failed(String)
}

public struct AppAgentVoiceRecognitionEndContext: Sendable {
    public let reason: AppAgentVoiceRecognitionEndReason
    public let finalText: String
    public let timestamp: TimeInterval
}

public enum AppAgentVoiceRecognitionEvent: Sendable {
    case loading(AppAgentVoiceRecognitionLoadingContext)
    case recording(AppAgentVoiceRecognitionRecordingContext)
    case ended(AppAgentVoiceRecognitionEndContext)
}

public enum AppAgentVoiceRecognitionStopResult: Sendable {
    case alreadyStopped
    case stopped(finalText: String, reason: AppAgentVoiceRecognitionEndReason)
}

/// 识别回调的**值快照**：`SFSpeechRecognitionResult` 是非 Sendable 的引用类型，
/// 直接塞进投给 `audioQueue` 的闭包等于把一个 AV 对象跨线程传递。回调线程上用得到的只有
/// 「当前最好文本 + 是否最终」，就地取完，队列里流转值类型。
private struct AppAgentSpeechTranscriptSnapshot: Sendable {
    let text: String
    let isFinal: Bool
}

/// 语音识别服务抽象：协调层依赖此协议，便于替身测试与替换实现。
/// 事件必须在主线程投递；识别热路径的实现细节（队列、权限、音频会话）由实现方自理。
protocol AppAgentVoiceRecognitionProviding: AnyObject {
    /// 识别语言优先级列表，按顺序取第一个系统可用的识别器。
    var preferredLocales: [Locale] { get set }

    /// 是否允许「预热」：只有系统语音 + 麦克风权限都已授权、且当前没有其他音频在播放时才允许。
    /// 预热会激活 `.record` 会话并 duck 其他音频，因此有其他音频在放时不预热。
    var canPrewarmNow: Bool { get }

    /// 当前是否已进入录音/识别阶段。预热会在面板展示前就就绪，UI 展示时需据此把初始态
    /// 直接置为「录音中」而不是「loading」（否则那条 `.recording` 事件在预热期被丢，面板卡在转圈）。
    var isRecording: Bool { get }

    /// 开始录音识别；locale 传 nil 时按 preferredLocales 解析。
    func startRecording(locale: Locale?) -> AsyncStream<AppAgentVoiceRecognitionEvent>

    /// 请求停止（异步清理，结束事件经事件流投递）。
    /// 立即停止、不等尾音——用于取消 / 系统中断。
    func requestStopRecording(reason: AppAgentVoiceRecognitionEndReason)

    /// 请求「优雅收尾」：继续采集 `trailingCapture` 秒尾音后停止喂音频，
    /// 再等识别器吐出 `isFinal` 最终结果（上限 `finalizationTimeout`）才结束，
    /// 保证松手前后的音频都转成文字。结束仍经事件流的 `.ended` 投递（携带最终文本）。
    /// 用于「松手发送 / 松手编辑」。
    func requestFinishRecording(trailingCapture: TimeInterval, finalizationTimeout: TimeInterval)
}

extension AppAgentVoiceRecognitionProviding {
    func startRecording() -> AsyncStream<AppAgentVoiceRecognitionEvent> {
        startRecording(locale: nil)
    }
}

// Mutable recognition state is isolated to `audioQueue`.
public final class AppAgentVoiceRecognitionManager: NSObject, @unchecked Sendable, AppAgentVoiceRecognitionProviding {
    public static let shared = AppAgentVoiceRecognitionManager()

    /// Enables direct console logs for voice-recognition state changes. 默认关闭，调试音频层时再手动打开。
    public var isConsoleLoggingEnabled: Bool {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _isConsoleLoggingEnabled
        }
        set {
            configLock.lock()
            _isConsoleLoggingEnabled = newValue
            configLock.unlock()
        }
    }

    /// 临时调试开关：开启后完全绕过真实音频/语音系统接口，只发出假的 loading/recording/ended 事件。
    ///
    /// 用于排查 `AVAudioSession` / `AVAudioEngine` / `SFSpeechRecognizer` 是否影响 UI 震动或手势反馈。
    /// 调试结束后应改回 `false`，否则不会真正录音和识别。
    public var isAudioSystemBypassForDebugEnabled: Bool {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _isAudioSystemBypassForDebugEnabled
        }
        set {
            configLock.lock()
            _isAudioSystemBypassForDebugEnabled = newValue
            configLock.unlock()
        }
    }

    /// 识别语言优先级列表：按顺序取第一个系统可用的识别器。
    ///
    /// 默认中文优先，其次系统当前语言。`SFSpeechRecognizer` 单次只能绑定一种语言，
    /// 这里的"多语言"指宿主可配置候选语言并按优先级回退（中文识别器本身也能容忍中英混说）。
    public var preferredLocales: [Locale] {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _preferredLocales
        }
        set {
            configLock.lock()
            _preferredLocales = newValue
            configLock.unlock()
        }
    }

    private let audioQueue = DispatchQueue(
        label: "com.appagent.voiceRecognition.audio",
        qos: .userInitiated
    )
    /// 配置项统一用这一把锁保护（日志/调试开关、语言列表）；识别热路径状态仍隔离在 audioQueue。
    private let configLock = NSLock()
    private var _isConsoleLoggingEnabled = false
    private var _isAudioSystemBypassForDebugEnabled = false
    private var _preferredLocales: [Locale] = [Locale(identifier: "zh-CN"), .current]
    /// `state == .recording` 的缓存镜像，供跨线程 `isRecording` 读取；由 `setState` 在 audioQueue 上更新。
    private var _isRecording = false
    /// 最近一次音频缓冲估算出的归一化音量（0…1），供录音态波形起伏用。
    /// 写在音频线程、读在 audioQueue，统一用 configLock 保护。
    private var _currentAudioLevel: Double = 0
    // 音量事件的节流计数**不在这里**：它是「一次 tap 装配的私有状态」，
    // 现在由 tap 闭包捕获的 `Locked` 盒子持有（见 `startAudioSession`）。
    // 曾经它是这里的一个裸 `var`，注释写「只在音频线程读写」，事实是音频渲染线程与
    // `audioQueue` 两个隔离域都在写它 —— 详见那边的注释。

    private enum InternalState {
        case idle
        case starting(UUID)
        case recording(UUID)
        /// 用户已松手请求「优雅收尾」：仍在采集尾音 / 等识别器吐出最终结果，尚未真正停止。
        case finalizing(UUID)
        case stopping(UUID)

        var sessionID: UUID? {
            switch self {
            case .idle:
                return nil
            case .starting(let id), .recording(let id), .finalizing(let id), .stopping(let id):
                return id
            }
        }
    }

    private var state: InternalState = .idle
    private var continuation: AsyncStream<AppAgentVoiceRecognitionEvent>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var finalText = ""
    private var partialText = ""
    private var activeSessionUsesDebugAudioBypass = false

    /// 是否允许「预热」：系统语音识别 + 麦克风权限都已授权、且当前没有其他音频在播放。
    /// 预热会激活 `.record` 会话并 duck 其他音频，所以有其他音频在放（或系统要求次要音频静音）时不预热。
    public var canPrewarmNow: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else { return false }
        if session.isOtherAudioPlaying { return false }
        if session.secondaryAudioShouldBeSilencedHint { return false }
        return true
    }

    /// 当前是否已进入录音/识别阶段。跨线程读取，用 `configLock` 保护。
    public var isRecording: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return _isRecording
    }

    /// 最近一次估算的归一化音量（0…1）。跨线程读取，用 `configLock` 保护。
    private var currentAudioLevel: Double {
        configLock.lock()
        defer { configLock.unlock() }
        return _currentAudioLevel
    }

    /// 开始录音识别。`locale` 传 nil 时按 `preferredLocales` 优先级自动解析识别语言。
    public func startRecording(locale: Locale? = nil) -> AsyncStream<AppAgentVoiceRecognitionEvent> {        let sessionID = UUID()
        log("startRecording requested locale=\(locale?.identifier ?? "auto") session=\(shortSessionID(sessionID))")

        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.audioQueue.async { [weak self] in
                    guard let self = self, self.state.sessionID == sessionID else { return }
                    self.log("stream terminated session=\(self.shortSessionID(sessionID))")
                    self.finishCurrentSession(reason: .cancelled)
                }
            }

            self.audioQueue.async { [weak self] in
                guard let self = self else {
                    DispatchQueue.main.async {
                        continuation.finish()
                    }
                    return
                }
                if self.state.sessionID != nil {
                    self.finishCurrentSession(reason: .cancelled)
                }

                self.continuation = continuation
                self.setState(.starting(sessionID), reason: "start recording")
                self.finalText = ""
                self.partialText = ""
                if self.isAudioSystemBypassForDebugEnabled {
                    self.startDebugFakeRecording(sessionID: sessionID)
                } else {
                    self.activeSessionUsesDebugAudioBypass = false
                    self.emitLoading(.requestingSpeechPermission, sessionID: sessionID)
                    self.requestSpeechPermission(sessionID: sessionID, locale: locale)
                }
            }
        }
    }

    public func stopRecording() async -> AppAgentVoiceRecognitionStopResult {
        await stopRecording(reason: .userStopped)
    }

    func requestStopRecording(reason: AppAgentVoiceRecognitionEndReason) {
        audioQueue.async { [weak self] in
            self?.finishCurrentRecording(reason: reason, resumes: nil)
        }
    }

    func requestFinishRecording(trailingCapture: TimeInterval, finalizationTimeout: TimeInterval) {
        audioQueue.async { [weak self] in
            self?.beginFinalizing(
                trailingCapture: max(0, trailingCapture),
                finalizationTimeout: max(0, finalizationTimeout)
            )
        }
    }

    /// 优雅收尾：从「录音中」切到「收尾中」，继续采集尾音，然后等最终识别结果。
    /// 必须在 `audioQueue` 上调用。
    private func beginFinalizing(trailingCapture: TimeInterval, finalizationTimeout: TimeInterval) {
        guard let sessionID = state.sessionID else {
            log("finalize ignored: already idle")
            return
        }
        // 只有真正在录音时才需要收尾；其余状态（仍在准备 / 已在停）直接按立即停止收尾。
        guard case .recording = state else {
            log("finalize while state=\(describe(state)) → immediate finish session=\(shortSessionID(sessionID))")
            finishCurrentSession(reason: .userStopped)
            return
        }

        setState(.finalizing(sessionID), reason: "finalize trailing=\(trailingCapture) timeout=\(finalizationTimeout)")

        // 调试假录音：没有真实识别器会吐 isFinal，直接用当前文本收尾。
        if activeSessionUsesDebugAudioBypass {
            finishCurrentSession(reason: .userStopped)
            return
        }

        // 1) 继续采集 trailingCapture 秒尾音，到点停止喂音频并请求最终结果。
        audioQueue.asyncAfter(deadline: .now() + trailingCapture) { [weak self] in
            guard let self = self, self.state.sessionID == sessionID else { return }
            guard case .finalizing = self.state else { return }
            self.stopAudioFeedRequestingFinal(sessionID: sessionID)
        }

        // 2) 兜底：最终结果迟迟不来（离线模型慢 / 网络差），到点用当前最好文本强制收尾，
        //    绝不把面板永久挂在收尾态。
        audioQueue.asyncAfter(deadline: .now() + trailingCapture + finalizationTimeout) { [weak self] in
            guard let self = self, self.state.sessionID == sessionID else { return }
            guard case .finalizing = self.state else { return }
            self.log("finalization timeout → finish with best text session=\(self.shortSessionID(sessionID))")
            self.finishCurrentSession(reason: .userStopped)
        }
    }

    /// 停止喂音频（停引擎 + `endAudio`），但**保留识别任务**等待 `isFinal`，不 `cancel`。
    /// 必须在 `audioQueue` 上调用。
    private func stopAudioFeedRequestingFinal(sessionID: UUID) {
        guard state.sessionID == sessionID, case .finalizing = state else { return }
        log("stop audio feed, request final session=\(shortSessionID(sessionID))")
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        recognitionRequest?.endAudio()
    }

    func stopRecording(reason: AppAgentVoiceRecognitionEndReason) async -> AppAgentVoiceRecognitionStopResult {
        await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                self?.finishCurrentRecording(reason: reason, resumes: continuation)
                    ?? continuation.resume(returning: .alreadyStopped)
            }
        }
    }

    private func finishCurrentRecording(
        reason: AppAgentVoiceRecognitionEndReason,
        resumes continuation: CheckedContinuation<AppAgentVoiceRecognitionStopResult, Never>?
    ) {
        log("stopRecording requested reason=\(describe(reason))")
        guard let sessionID = state.sessionID else {
            log("stopRecording ignored: already stopped")
            continuation?.resume(returning: .alreadyStopped)
            return
        }

        setState(.stopping(sessionID), reason: "stop requested reason=\(describe(reason))")
        let text = combinedText
        finishCurrentSession(reason: reason)
        continuation?.resume(returning: .stopped(finalText: text, reason: reason))
    }

    private func startDebugFakeRecording(sessionID: UUID) {
        guard state.sessionID == sessionID else {
            log("debug fake recording ignored for stale session=\(shortSessionID(sessionID)) current=\(shortSessionID(state.sessionID))")
            return
        }

        activeSessionUsesDebugAudioBypass = true
        log("debug fake recording enabled: bypass audio and speech system APIs session=\(shortSessionID(sessionID))")
        emitLoading(.waitingForRecognizer, sessionID: sessionID)
        setState(.recording(sessionID), reason: "debug fake recording started")
        emitRecording(sessionID: sessionID)
    }

    private func requestSpeechPermission(sessionID: UUID, locale: Locale?) {
        let status = SFSpeechRecognizer.authorizationStatus()
        log("speech permission status=\(describe(status)) session=\(shortSessionID(sessionID))")
        switch status {
        case .authorized:
            requestMicrophonePermission(sessionID: sessionID, locale: locale)
        case .denied, .restricted:
            finishSessionIfCurrent(sessionID, reason: .permissionDenied)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                self?.audioQueue.async { [weak self] in
                    guard let self = self, self.state.sessionID == sessionID else { return }
                    self.log("speech permission callback status=\(self.describe(status)) session=\(self.shortSessionID(sessionID))")
                    if status == .authorized {
                        self.requestMicrophonePermission(sessionID: sessionID, locale: locale)
                    } else {
                        self.finishSessionIfCurrent(sessionID, reason: .permissionDenied)
                    }
                }
            }
        @unknown default:
            finishSessionIfCurrent(sessionID, reason: .permissionDenied)
        }
    }

    private func requestMicrophonePermission(sessionID: UUID, locale: Locale?) {
        emitLoading(.requestingMicrophonePermission, sessionID: sessionID)
        let audioSession = AVAudioSession.sharedInstance()

        let permission = audioSession.recordPermission
        log("microphone permission status=\(describe(permission)) session=\(shortSessionID(sessionID))")
        switch permission {
        case .granted:
            startAudioSession(sessionID: sessionID, locale: locale)
        case .denied:
            finishSessionIfCurrent(sessionID, reason: .permissionDenied)
        case .undetermined:
            audioSession.requestRecordPermission { [weak self] granted in
                self?.audioQueue.async { [weak self] in
                    guard let self = self, self.state.sessionID == sessionID else { return }
                    self.log("microphone permission callback granted=\(granted) session=\(self.shortSessionID(sessionID))")
                    if granted {
                        self.startAudioSession(sessionID: sessionID, locale: locale)
                    } else {
                        self.finishSessionIfCurrent(sessionID, reason: .permissionDenied)
                    }
                }
            }
        @unknown default:
            finishSessionIfCurrent(sessionID, reason: .permissionDenied)
        }
    }

    private func startAudioSession(sessionID: UUID, locale: Locale?) {
        guard state.sessionID == sessionID else {
            log("startAudioSession ignored for stale session=\(shortSessionID(sessionID)) current=\(shortSessionID(state.sessionID))")
            return
        }
        emitLoading(.preparingAudioSession, sessionID: sessionID)

        let speechRecognizer = resolveSpeechRecognizer(explicitLocale: locale)
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            log("speech recognizer unavailable locale=\(locale?.identifier ?? "auto") session=\(shortSessionID(sessionID))")
            finishSessionIfCurrent(sessionID, reason: .recognizerUnavailable)
            return
        }
        log("speech recognizer ready locale=\(speechRecognizer.locale.identifier) session=\(shortSessionID(sessionID))")

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            do {
                try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
                log("audio session allows haptics and system sounds during recording session=\(shortSessionID(sessionID))")
            } catch {
                log("allow haptics during recording failed error=\(error.localizedDescription) session=\(shortSessionID(sessionID))")
            }
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            log("audio session active session=\(shortSessionID(sessionID))")
        } catch {
            log("audio session unavailable error=\(error.localizedDescription) session=\(shortSessionID(sessionID))")
            finishSessionIfCurrent(sessionID, reason: .audioSessionUnavailable)
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        recognizer = speechRecognizer
        audioEngine = engine
        recognitionRequest = request

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            // 在识别器回调线程上就地取值再往下传：`SFSpeechRecognitionResult` 和 `Error` 都是
            // 非 Sendable 的引用类型，塞进投给 `audioQueue` 的闭包就是把 AV 对象跨线程传递。
            // `error` 只用于写日志 + 拼失败原因，下游不需要 `Error` 本身做任何类型判断，
            // 所以这里直接定格成字符串，不把引用带过队列边界。
            let transcript = result.map {
                AppAgentSpeechTranscriptSnapshot(
                    text: $0.bestTranscription.formattedString,
                    isFinal: $0.isFinal
                )
            }
            let errorDescription = error?.localizedDescription
            self?.audioQueue.async { [weak self] in
                self?.handleRecognitionCallback(
                    sessionID: sessionID,
                    transcript: transcript,
                    errorDescription: errorDescription
                )
            }
        }

        inputNode.removeTap(onBus: 0)
        // 音量事件节流：约每 0.08s（≈12Hz）向 UI 投递一次音量，够反映声音变化又省 CPU。
        //
        // 节流计数是**这一次 tap 装配的私有状态**，所以放在 tap 闭包捕获的盒子里，不做实例属性：
        // tap 回调跑在 AVAudioEngine 的音频渲染线程，而会话装配 / 清理跑在 `audioQueue`，
        // 以前那个实例属性被两个隔离域各写一次（装 tap 前置 0、`cleanupAudioResources` 置 0），
        // 注释却声称「只在音频线程读写」—— 与事实相反。装盒之后跨域共享直接不存在：
        // 每装一次 tap 造一个新盒子，计数天然从 0 开始，换会话重装不会带上一轮的余数；
        // `Locked.mutate` 再把「累加 → 判阈 → 归零」收成一次原子读改写。
        let levelEmitIntervalFrames = AVAudioFramePosition(max(1, format.sampleRate * 0.08))
        let framesSinceLevelEmit = Locked<AVAudioFramePosition>(wrappedValue: 0)
        setAudioLevel(0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self = self else { return }
            // 估算音量并缓存（音频线程），按帧数节流后再切到 audioQueue 投递 .recording。
            self.setAudioLevel(self.normalizedAudioLevel(from: buffer))
            let reachedEmitInterval = framesSinceLevelEmit.mutate { frames -> Bool in
                frames += AVAudioFramePosition(buffer.frameLength)
                guard frames >= levelEmitIntervalFrames else { return false }
                frames = 0
                return true
            }
            guard reachedEmitInterval else { return }
            self.audioQueue.async { [weak self] in
                guard let self = self, self.state.sessionID == sessionID else { return }
                guard case .recording = self.state else { return }
                self.emitRecording(sessionID: sessionID)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioSessionInterruption(_:)),
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance()
            )
            setState(.recording(sessionID), reason: "audio engine started")
            emitRecording(sessionID: sessionID)
        } catch {
            inputNode.removeTap(onBus: 0)
            log("audio engine start failed error=\(error.localizedDescription) session=\(shortSessionID(sessionID))")
            finishSessionIfCurrent(sessionID, reason: .failed(error.localizedDescription))
        }
    }

    /// 解析识别器：显式 locale 最优先，其次按 preferredLocales 顺序取第一个可用识别器，最后回退系统默认。
    private func resolveSpeechRecognizer(explicitLocale: Locale?) -> SFSpeechRecognizer? {
        var candidates: [Locale] = []
        if let explicitLocale = explicitLocale {
            candidates.append(explicitLocale)
        }
        candidates.append(contentsOf: preferredLocales)

        for candidate in candidates {
            if let recognizer = SFSpeechRecognizer(locale: candidate), recognizer.isAvailable {
                log("speech recognizer resolved locale=\(candidate.identifier)")
                return recognizer
            }
            log("speech recognizer candidate unavailable locale=\(candidate.identifier)")
        }
        log("speech recognizer falling back to system default locale")
        return SFSpeechRecognizer()
    }

    private func handleRecognitionCallback(
        sessionID: UUID,
        transcript: AppAgentSpeechTranscriptSnapshot?,
        errorDescription: String?
    ) {
        guard state.sessionID == sessionID else {
            log("recognition callback ignored for stale session=\(shortSessionID(sessionID)) current=\(shortSessionID(state.sessionID))")
            return
        }

        switch state {
        case .recording:
            if let transcript = transcript {
                partialText = transcript.text
                if transcript.isFinal {
                    finalText = partialText
                }
                emitRecording(sessionID: sessionID)
            }
            if let errorDescription = errorDescription {
                log("recognition callback error=\(errorDescription) session=\(shortSessionID(sessionID))")
                finishSessionIfCurrent(sessionID, reason: .failed(errorDescription))
            }

        case .finalizing:
            // 收尾期：继续吸收识别结果；拿到最终结果（或出错）即用当前最好文本结束，
            // 不能像录音期那样把 error 当失败——收尾阶段的目标是「尽量不丢已识别内容」。
            if let transcript = transcript {
                partialText = transcript.text
                if transcript.isFinal {
                    finalText = partialText
                    log("final result received during finalize session=\(shortSessionID(sessionID))")
                    finishCurrentSession(reason: .userStopped)
                    return
                }
            }
            if let errorDescription = errorDescription {
                log("recognition error during finalize=\(errorDescription) session=\(shortSessionID(sessionID))")
                finishCurrentSession(reason: .userStopped)
            }

        case .stopping:
            return

        default:
            log("recognition callback ignored while state=\(describe(state)) session=\(shortSessionID(sessionID))")
        }
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: rawType) == .began else {
            return
        }
        audioQueue.async { [weak self] in
            guard let self = self, self.state.sessionID != nil else { return }
            self.log("audio session interrupted current=\(self.describe(self.state))")
            self.finishCurrentSession(reason: .interrupted)
        }
    }

    private func finishSessionIfCurrent(_ sessionID: UUID, reason: AppAgentVoiceRecognitionEndReason) {
        guard state.sessionID == sessionID else {
            log("finish ignored for stale session=\(shortSessionID(sessionID)) reason=\(describe(reason)) current=\(shortSessionID(state.sessionID))")
            return
        }
        finishCurrentSession(reason: reason)
    }

    private func finishCurrentSession(reason: AppAgentVoiceRecognitionEndReason) {
        guard let sessionID = state.sessionID else {
            log("finish ignored: already idle reason=\(describe(reason))")
            return
        }
        setState(.stopping(sessionID), reason: "finish reason=\(describe(reason))")

        let text = combinedText
        cleanupAudioResources()
        let endedEvent = AppAgentVoiceRecognitionEvent.ended(AppAgentVoiceRecognitionEndContext(
            reason: reason,
            finalText: text,
            timestamp: now
        ))
        log("event \(describe(endedEvent)) session=\(shortSessionID(sessionID))")
        let streamContinuation = continuation
        continuation = nil
        setState(.idle, reason: "finish complete")
        if let streamContinuation = streamContinuation {
            deliverOnMain(endedEvent, continuation: streamContinuation, finish: true)
        }
    }

    private func cleanupAudioResources() {
        log("cleanup audio resources state=\(describe(state))")
        if activeSessionUsesDebugAudioBypass {
            log("debug fake recording cleanup: skip audio system APIs")
            activeSessionUsesDebugAudioBypass = false
            recognitionTask = nil
            recognitionRequest = nil
            audioEngine = nil
            recognizer = nil
            return
        }

        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        recognizer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        activeSessionUsesDebugAudioBypass = false
        // 只清音量镜像。节流计数随 tap 闭包一起释放，不需要（也不该）在这里跨隔离域去写。
        setAudioLevel(0)
    }

    private func emitLoading(_ reason: AppAgentVoiceRecognitionLoadingReason, sessionID: UUID) {
        emit(.loading(AppAgentVoiceRecognitionLoadingContext(reason: reason, timestamp: now)), sessionID: sessionID)
    }

    private func emitRecording(sessionID: UUID) {
        emit(
            .recording(AppAgentVoiceRecognitionRecordingContext(
                partialText: partialText,
                finalText: finalText,
                combinedText: combinedText,
                audioLevel: currentAudioLevel,
                timestamp: now
            )),
            sessionID: sessionID
        )
    }

    /// 写入最近一次归一化音量（音频线程调用），供 UI 读取起伏。
    private func setAudioLevel(_ level: Double) {
        configLock.lock()
        _currentAudioLevel = level
        configLock.unlock()
    }

    /// 从音频缓冲估算归一化音量（0…1）。低采样（最多 256 点）估 RMS，再按 dB 映射，够反映响度变化即可。
    private func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let step = max(1, frameCount / 256)
        var sumSquares: Float = 0
        var count = 0
        var index = 0
        while index < frameCount {
            let sample = channel[index]
            sumSquares += sample * sample
            count += 1
            index += step
        }
        guard count > 0 else { return 0 }

        let rms = sqrt(sumSquares / Float(count))
        guard rms > 0 else { return 0 }
        // -50dB…0dB 线性映射到 0…1，弱声也有可见起伏。
        let db = 20 * log10(Double(rms))
        return min(1, max(0, (db + 50) / 50))
    }

    private func emit(_ event: AppAgentVoiceRecognitionEvent, sessionID: UUID) {
        guard state.sessionID == sessionID else {
            log("event dropped \(describe(event)) stale session=\(shortSessionID(sessionID)) current=\(shortSessionID(state.sessionID))")
            return
        }
        log("event \(describe(event)) session=\(shortSessionID(sessionID))")
        if let continuation = continuation {
            deliverOnMain(event, continuation: continuation)
        }
    }

    private func deliverOnMain(
        _ event: AppAgentVoiceRecognitionEvent,
        continuation: AsyncStream<AppAgentVoiceRecognitionEvent>.Continuation,
        finish: Bool = false
    ) {
        DispatchQueue.main.async {
            continuation.yield(event)
            if finish {
                continuation.finish()
            }
        }
    }

    private func setState(_ newState: InternalState, reason: String) {
        state = newState
        configLock.lock()
        if case .recording = newState {
            _isRecording = true
        } else {
            _isRecording = false
        }
        configLock.unlock()
        log("state -> \(describe(newState)) reason=\(reason)")
    }

    private func log(_ message: String) {
        guard isConsoleLoggingEnabled else { return }
        print("[AppAgentVoiceRecognition] \(message)")
    }

    private func shortSessionID(_ sessionID: UUID?) -> String {
        guard let sessionID = sessionID else { return "none" }
        return String(sessionID.uuidString.prefix(8))
    }

    private func describe(_ state: InternalState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .starting(let id):
            return "starting(\(shortSessionID(id)))"
        case .recording(let id):
            return "recording(\(shortSessionID(id)))"
        case .finalizing(let id):
            return "finalizing(\(shortSessionID(id)))"
        case .stopping(let id):
            return "stopping(\(shortSessionID(id)))"
        }
    }

    private func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private func describe(_ permission: AVAudioSession.RecordPermission) -> String {
        switch permission {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .undetermined:
            return "undetermined"
        @unknown default:
            return "unknown"
        }
    }

    private func describe(_ reason: AppAgentVoiceRecognitionLoadingReason) -> String {
        switch reason {
        case .requestingSpeechPermission:
            return "requestingSpeechPermission"
        case .requestingMicrophonePermission:
            return "requestingMicrophonePermission"
        case .preparingAudioSession:
            return "preparingAudioSession"
        case .waitingForRecognizer:
            return "waitingForRecognizer"
        }
    }

    private func describe(_ reason: AppAgentVoiceRecognitionEndReason) -> String {
        switch reason {
        case .userStopped:
            return "userStopped"
        case .cancelled:
            return "cancelled"
        case .interrupted:
            return "interrupted"
        case .permissionDenied:
            return "permissionDenied"
        case .recognizerUnavailable:
            return "recognizerUnavailable"
        case .audioSessionUnavailable:
            return "audioSessionUnavailable"
        case .failed(let message):
            return "failed(\(message))"
        }
    }

    private func describe(_ event: AppAgentVoiceRecognitionEvent) -> String {
        switch event {
        case .loading(let context):
            return "loading(reason=\(describe(context.reason)))"
        case .recording(let context):
            return "recording(textLength=\(context.combinedText.count), preview=\(preview(context.combinedText)))"
        case .ended(let context):
            return "ended(reason=\(describe(context.reason)), finalLength=\(context.finalText.count), preview=\(preview(context.finalText)))"
        }
    }

    private func preview(_ text: String) -> String {
        guard !text.isEmpty else { return "\"\"" }
        let limit = 24
        let prefix = text.prefix(limit)
        let suffix = text.count > limit ? "..." : ""
        return "\"\(prefix)\(suffix)\""
    }

    private var combinedText: String {
        partialText.isEmpty ? finalText : partialText
    }

    private var now: TimeInterval {
        Date.timeIntervalSinceReferenceDate
    }
}

#endif
