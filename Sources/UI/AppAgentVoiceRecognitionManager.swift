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

/// 语音识别服务抽象：协调层依赖此协议，便于替身测试与替换实现。
/// 事件必须在主线程投递；识别热路径的实现细节（队列、权限、音频会话）由实现方自理。
protocol AppAgentVoiceRecognitionProviding: AnyObject {
    /// 识别语言优先级列表，按顺序取第一个系统可用的识别器。
    var preferredLocales: [Locale] { get set }

    /// 开始录音识别；locale 传 nil 时按 preferredLocales 解析。
    func startRecording(locale: Locale?) -> AsyncStream<AppAgentVoiceRecognitionEvent>

    /// 请求停止（异步清理，结束事件经事件流投递）。
    func requestStopRecording(reason: AppAgentVoiceRecognitionEndReason)
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

    private enum InternalState {
        case idle
        case starting(UUID)
        case recording(UUID)
        case stopping(UUID)

        var sessionID: UUID? {
            switch self {
            case .idle:
                return nil
            case .starting(let id), .recording(let id), .stopping(let id):
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

    /// 开始录音识别。`locale` 传 nil 时按 `preferredLocales` 优先级自动解析识别语言。
    public func startRecording(locale: Locale? = nil) -> AsyncStream<AppAgentVoiceRecognitionEvent> {
        let sessionID = UUID()
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
            self?.audioQueue.async { [weak self] in
                self?.handleRecognitionCallback(sessionID: sessionID, result: result, error: error)
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        guard state.sessionID == sessionID else {
            log("recognition callback ignored for stale session=\(shortSessionID(sessionID)) current=\(shortSessionID(state.sessionID))")
            return
        }
        guard case .recording = state else {
            if case .stopping = state { return }
            log("recognition callback ignored while state=\(describe(state)) session=\(shortSessionID(sessionID))")
            return
        }

        if let result = result {
            partialText = result.bestTranscription.formattedString
            if result.isFinal {
                finalText = partialText
            }
            emitRecording(sessionID: sessionID)
        }

        if let error = error {
            log("recognition callback error=\(error.localizedDescription) session=\(shortSessionID(sessionID))")
            finishSessionIfCurrent(sessionID, reason: .failed(error.localizedDescription))
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
                audioLevel: 0,
                timestamp: now
            )),
            sessionID: sessionID
        )
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
