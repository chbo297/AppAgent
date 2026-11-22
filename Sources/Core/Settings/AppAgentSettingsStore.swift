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
    /// Configuration changed; credentials are never included in the notification.
    public static let didChangeNotification = Notification.Name("AppAgentEndpointSettingsDidChange")
    private static let configurationLock = NSLock()

    /// Includes an explicitly cleared configuration, so hosts must not restore legacy defaults.
    public static var hasSavedConfiguration: Bool {
        configurationLock.lock()
        defer {
            configurationLock.unlock()
        }
        return defaults.data(forKey: storageKey) != nil
    }
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
        configurationLock.lock()
        defer {
            configurationLock.unlock()
        }
        guard let data = defaults.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(AppAgentEndpointSettings.self, from: data)
        else {
            return nil
        }
        settings.apiKey = AppAgentKeychain.get(account: apiKeyAccount) ?? ""
        return settings
    }

    /// 读取设置，无保存记录时返回未配置状态；宿主默认值由宿主自行注入。
    public static func loadOrDefault() -> AppAgentEndpointSettings {
        load() ?? AppAgentEndpointSettings()
    }

    /// 保存设置：apiKey 写 Keychain，其余字段（apiKey 清空后）写 UserDefaults。
    @discardableResult
    public static func save(_ settings: AppAgentEndpointSettings) -> Bool {
        let normalized = settings.normalized
        configurationLock.lock()
        let saved = persist(normalized, defaults: defaults) { key in
            AppAgentKeychain.set(key, account: apiKeyAccount)
        }
        configurationLock.unlock()
        guard saved else {
            return false
        }
        Logger.info(
            "AppAgentSettings",
            "configuration saved: usable=\(normalized.isUsable), hasKey=\(normalized.hasUsableAPIKey)"
        )
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return true
    }

    /// Separate persistence transaction allows failure testing without accessing real credentials.
    static func persist(
        _ settings: AppAgentEndpointSettings,
        defaults: UserDefaults,
        writeKey: (String) -> Bool
    ) -> Bool {
        let normalized = settings.normalized
        var sanitized = normalized
        sanitized.apiKey = ""
        guard let data = try? JSONEncoder().encode(sanitized),
              writeKey(normalized.apiKey) else {
            return false
        }
        defaults.set(data, forKey: storageKey)
        return true
    }

    /// Removes the credential and retains an empty configuration as an explicit clear marker.
    /// Chat history and UI preferences are unaffected.
    @discardableResult
    public static func clear() -> Bool {
        save(AppAgentEndpointSettings())
    }
}
