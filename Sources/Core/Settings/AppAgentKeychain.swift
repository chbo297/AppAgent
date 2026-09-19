//
//  AppAgentKeychain.swift
//  AppAgent
//
//  轻量 Keychain 读写封装（Security 框架，iOS 15+ / macOS 12+）。
//  用于持久化敏感项（如大模型 apiKey），避免明文落 UserDefaults。
//

import Foundation
import Security

/// 极简 Keychain 存取工具（`kSecClassGenericPassword`）。
public enum AppAgentKeychain {
    /// service 命名空间，避免与宿主 app 其它 Keychain 项冲突。
    private static let service = "com.appagent.keychain"

    /// 写入字符串；传入空串或 nil 视为删除。
    @discardableResult
    public static func set(_ value: String?, account: String) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return delete(account: account) }

        var query = baseQuery(account: account)
        // 先删再加，避免 duplicate item。
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.error("AppAgentKeychain", "set failed: account=\(account), status=\(status)")
        }
        return status == errSecSuccess
    }

    /// 读取字符串；不存在返回 nil。
    public static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除指定项。
    @discardableResult
    public static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
