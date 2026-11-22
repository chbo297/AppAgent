//
//  AppAgentVoiceRecognitionCentral.swift
//  AppAgentUI
//
//  语音识别引擎注册中心：内置「系统识别」，其他引擎由宿主或可选模块注册进来；
//  用户在设置页选中的引擎持久化在 UserDefaults，每次开始语音输入时按当前选择解析。
//

#if canImport(AVFoundation) && canImport(Speech) && (os(iOS) || targetEnvironment(macCatalyst))
import Foundation
import UIKit

/// 一个可供用户选择的语音识别引擎。
@MainActor
public struct AppAgentVoiceRecognitionEngine {
    /// 稳定标识：持久化用户选择用，注册后不要改。
    public let id: String

    /// 设置页展示名，如「系统识别」。
    public let displayName: String

    /// 设置页副标题：一句话说明特点或计费方式。
    public let summary: String

    /// 识别实现：引擎生命周期内复用同一个实例（内部自行管理单次录音会话）。
    public let recognizer: AppAgentVoiceRecognitionProviding

    /// 引擎当前是否可用（如凭据已配置）。选中但不可用时，实际回退到系统识别。
    public let isConfigured: () -> Bool

    /// 引擎自己的配置页（如填写 API Key）；nil 表示无需配置。
    public let makeSettingsViewController: (() -> UIViewController)?

    public init(
        id: String,
        displayName: String,
        summary: String,
        recognizer: AppAgentVoiceRecognitionProviding,
        isConfigured: @escaping () -> Bool = {
            true
        },
        makeSettingsViewController: (() -> UIViewController)? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.recognizer = recognizer
        self.isConfigured = isConfigured
        self.makeSettingsViewController = makeSettingsViewController
    }
}

/// 语音识别引擎注册中心，`.default` 模式与 `ToolCentral` 一致。
@MainActor
public final class AppAgentVoiceRecognitionCentral {
    public static let `default` = AppAgentVoiceRecognitionCentral()

    /// 内置系统识别（`SFSpeechRecognizer`）的引擎标识。
    public static let systemEngineID = "system"

    /// UserDefaults key：用户选中的引擎标识。
    public static let selectionKey = "com.appagent.voiceRecognition.engineID"

    /// 已注册引擎列表或用户选择变化。
    public static let didChangeNotification = Notification.Name("AppAgentVoiceRecognitionEngineDidChange")

    /// 注册顺序即设置页展示顺序，系统识别恒在第一位。
    public private(set) var engines: [AppAgentVoiceRecognitionEngine] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engines = [
            AppAgentVoiceRecognitionEngine(
                id: Self.systemEngineID,
                displayName: "系统识别",
                summary: "iOS 自带语音识别，无需配置",
                recognizer: AppAgentVoiceRecognitionManager.shared
            )
        ]
    }

    /// 注册引擎；同 id 再注册会替换旧的（便于宿主更新凭据来源后重注册）。
    public func register(_ engine: AppAgentVoiceRecognitionEngine) {
        if let index = engines.firstIndex(where: { candidate in
            candidate.id == engine.id
        }) {
            engines[index] = engine
        } else {
            engines.append(engine)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 用户选中的引擎标识；未选过或选中的引擎没注册（这次打包没打进来）时为系统识别。
    public var selectedEngineID: String {
        get {
            guard let stored = defaults.string(forKey: Self.selectionKey),
                  engine(id: stored) != nil else {
                return Self.systemEngineID
            }
            return stored
        }
        set {
            defaults.set(newValue, forKey: Self.selectionKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// 实际生效的引擎：选中且已配置的引擎，否则回退系统识别。
    public var activeEngine: AppAgentVoiceRecognitionEngine {
        if let selected = engine(id: selectedEngineID), selected.isConfigured() {
            return selected
        }
        return systemEngine
    }

    /// 本次语音输入应使用的识别实现。
    public var activeRecognizer: AppAgentVoiceRecognitionProviding {
        activeEngine.recognizer
    }

    public func engine(id: String) -> AppAgentVoiceRecognitionEngine? {
        engines.first { candidate in
            candidate.id == id
        }
    }

    private var systemEngine: AppAgentVoiceRecognitionEngine {
        // init 里第一个注册的就是系统识别，且 register 只替换不删除，所以必然存在。
        engine(id: Self.systemEngineID) ?? engines[0]
    }
}

#endif
