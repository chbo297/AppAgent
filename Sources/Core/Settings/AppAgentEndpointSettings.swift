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
/// 默认指向 OneAPI 网关；`apiKey` 建议由 `AppAgentSettingsStore` 存入 Keychain。
public struct AppAgentEndpointSettings: Codable, Sendable, Equatable {
    /// 接口地址（含 `/v1`）。
    public var baseURL: String
    /// API Key（运行期使用；持久化时由 store 拆分进 Keychain）。
    public var apiKey: String
    /// 附加请求头（OneAPI 需要 `comate_custom_header`）。
    public var customHeaders: [String: String]
    /// 启用模型（有序，`[0]` 为默认）。
    public var enabledModels: [AppAgentModelRef]
    /// 模型上下文窗口与最大输出，用于构造 `ModelSpec`。
    public var contextWindow: Int
    public var maxTokens: Int

    public init(
        baseURL: String = LijiConfig.oneAPIBaseURL,
        apiKey: String = "",
        customHeaders: [String: String] = LijiConfig.defaultOneAPIHeaders,
        enabledModels: [AppAgentModelRef] = [AppAgentModelRef(modelId: "gpt-5.6-sol", apiProtocol: .openaiCompletions)],
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

    /// 默认接入：OneAPI + 默认模型，`apiKey` 留空由用户在设置页填写。
    public static var oneAPIDefault: AppAgentEndpointSettings { AppAgentEndpointSettings() }

    /// 是否具备可用于真实请求的最小配置（已填 apiKey 且至少一个启用模型）。
    public var isUsable: Bool { hasUsableAPIKey && !enabledModels.isEmpty }

    public var hasUsableAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 某协议对应的 provider 注册名（同一接口按协议拆成多个 provider 实例）。
    public func providerName(for apiProtocol: APIProtocol) -> String {
        "appagent-\(apiProtocol.rawValue)"
    }

    /// 默认模型的模型引用（"providerName/modelId"），无启用模型时为 nil。
    public var primaryModelRef: String? {
        guard let first = enabledModels.first else { return nil }
        return "\(providerName(for: first.apiProtocol))/\(first.modelId)"
    }

    /// 全部启用模型的模型引用（按序，用于 ModelPolicy 的 primary + fallbacks）。
    public var orderedModelRefs: [String] {
        enabledModels.map { "\(providerName(for: $0.apiProtocol))/\($0.modelId)" }
    }
}
