//
//  AppAgentSettingsStore.swift
//  AppAgent
//
//  AppAgentEndpointSettings 的本地持久化：非敏感字段走 UserDefaults，
//  apiKey 单独存 Keychain（吸纳宿主工程的安全做法）。
//

import Foundation

public enum AppAgentSettingsStore {
    /// UserDefaults key（存不含 apiKey 的设置 JSON）。
    public static let storageKey = "com.appagent.endpointSettings"
    /// Keychain account（存 apiKey）。
    public static let apiKeyAccount = "com.appagent.endpoint.apiKey"
    /// UserDefaults key：是否「总是显示思考过程」。这是纯 UI 展示偏好，和端点/模型无关，
    /// 所以单独存一个键，不塞进 `AppAgentEndpointSettings` 的 save 校验里。
    public static let alwaysShowThinkingKey = "com.appagent.alwaysShowThinkingProcess"

    private static var defaults: UserDefaults { .standard }

    /// 是否在成功给出最终结果后仍保留「处理过程」入口（小三角 + 标题）。
    ///
    /// 默认 `false`：成功的回复只显示最终结果，界面更干净；报错 / 异常回合不受此开关影响，
    /// 仍保留过程入口并在结果下方给出错误摘要。缺省键（新装）即默认值。
    public static var alwaysShowThinkingProcess: Bool {
        get { defaults.object(forKey: alwaysShowThinkingKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: alwaysShowThinkingKey) }
    }

    /// 读取已保存的设置；从未保存过时返回 nil。apiKey 从 Keychain 注入。
    public static func load() -> AppAgentEndpointSettings? {
        guard let data = defaults.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(AppAgentEndpointSettings.self, from: data)
        else { return nil }
        settings.apiKey = AppAgentKeychain.get(account: apiKeyAccount) ?? ""
        return settings
    }

    /// 读取设置，无保存记录时回落到 OneAPI 默认。
    public static func loadOrDefault() -> AppAgentEndpointSettings {
        load() ?? .oneAPIDefault
    }

    /// 保存设置：apiKey 写 Keychain，其余字段（apiKey 清空后）写 UserDefaults。
    public static func save(_ settings: AppAgentEndpointSettings) {
        AppAgentKeychain.set(settings.apiKey, account: apiKeyAccount)

        var sanitized = settings
        sanitized.apiKey = ""
        guard let data = try? JSONEncoder().encode(sanitized) else {
            Logger.error("AppAgentSettings", "save: encode failed")
            return
        }
        defaults.set(data, forKey: storageKey)
        Logger.info(
            "AppAgentSettings",
            "saved: base=\(settings.baseURL), models=\(settings.enabledModels.map { "\($0.modelId)@\($0.apiProtocol.rawValue)" }), hasKey=\(settings.hasUsableAPIKey)"
        )
    }
}
