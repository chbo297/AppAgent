//
//  AppAgentEndpointSettings.swift
//  AppAgent
//
//  用户可在「设置」面板内调整的大模型接入配置（AppAgent 自身能力，非宿主 app）。
//  一个「接口」= 一个 baseURL + apiKey，可同时支持多种协议（OpenAI / Anthropic）；
//  探查该接口后得到「模型 × 协议」候选，用户勾选、排序出一组启用模型，每项自带协议。
//

import Foundation

/// 单个启用模型的引用：模型 id + 该模型走的协议（同一接口可混用多种协议）。
public struct AppAgentModelRef: Codable, Sendable, Equatable {
    public var modelId: String
    public var apiProtocol: APIProtocol

    public init(modelId: String, apiProtocol: APIProtocol) {
        self.modelId = modelId
        self.apiProtocol = apiProtocol
    }
}

/// 一个大模型接口（endpoint）的完整配置。可 Codable 持久化。
///
/// - `enabledModels`：用户勾选并排序后的启用模型（每项自带协议），`[0]` 为默认（primary），
///   其余按序作为 fallback。同一模型 id 若两种协议都可用，可作为两项分别启用。
///
/// 默认不预设服务、请求头或模型；由宿主或用户配置。
/// `apiKey` 建议由 `AppAgentSettingsStore` 存入 Keychain。
public struct AppAgentEndpointSettings: Codable, Sendable, Equatable {
    /// 接口地址（含 `/v1`）。
    public var baseURL: String
    /// API Key（运行期使用；持久化时由 store 拆分进 Keychain）。
    public var apiKey: String
    /// 由宿主或用户提供的附加请求头。
    public var customHeaders: [String: String]
    /// 启用模型（有序，`[0]` 为默认）。
    public var enabledModels: [AppAgentModelRef]
    /// 模型上下文窗口与最大输出，用于构造 `ModelSpec`。
    public var contextWindow: Int
    public var maxTokens: Int

    public init(
        baseURL: String = "",
        apiKey: String = "",
        customHeaders: [String: String] = [:],
        enabledModels: [AppAgentModelRef] = [],
        contextWindow: Int = 200_000,
        maxTokens: Int = 8192
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.customHeaders = customHeaders
        self.enabledModels = enabledModels
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }

    /// 请求入口统一使用规范化配置，不静默丢弃无效模型。
    public var normalized: AppAgentEndpointSettings {
        var settings = self
        settings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.enabledModels = enabledModels.map { ref in
            AppAgentModelRef(
                modelId: ref.modelId.trimmingCharacters(in: .whitespacesAndNewlines),
                apiProtocol: ref.apiProtocol
            )
        }
        return settings
    }

    /// 只接受可作为 API 根地址的 HTTP(S) URL，不接受内嵌凭据或查询参数。
    public var hasUsableBaseURL: Bool {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.url != nil else {
            return false
        }
        return true
    }

    /// 所有入口共用的最低要求：有效地址、密钥及至少一个有效模型。
    public var isUsable: Bool {
        hasUsableBaseURL && hasUsableAPIKey && hasUsableModels
    }

    public var hasUsableModels: Bool {
        !enabledModels.isEmpty && enabledModels.allSatisfy { ref in
            !ref.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var hasUsableAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 某协议对应的 provider 注册名（同一接口按协议拆成多个 provider 实例）。
    public func providerName(for apiProtocol: APIProtocol) -> String {
        "appagent-\(apiProtocol.rawValue)"
    }

    /// 默认模型的模型引用（"providerName/modelId"），配置不可用时为 nil。
    public var primaryModelRef: String? {
        orderedModelRefs.first
    }

    /// 全部启用模型的模型引用（按序，用于 ModelPolicy 的 primary + fallbacks）。
    public var orderedModelRefs: [String] {
        guard isUsable else {
            return []
        }
        return normalized.enabledModels.map { ref in
            "\(providerName(for: ref.apiProtocol))/\(ref.modelId)"
        }
    }
}
