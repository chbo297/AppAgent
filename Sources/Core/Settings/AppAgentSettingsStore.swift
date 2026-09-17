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

    private static var defaults: UserDefaults { .standard }

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
