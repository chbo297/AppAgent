//
//  LijiProviderFactory.swift
//  OpenAPP — Liji 集成层
//
//  由 LijiConfig 构造 ModelProvider。当前复用通用 HTTP+SSE 的 AnthropicProvider
//  （其内部按 apiProtocol 分派 anthropic-messages / openai-completions 两种线格式）。
//

import Foundation

public enum LijiProviderFactory {

    /// 依据配置构造 Provider。
    public static func makeProvider(from config: LijiConfig) -> ModelProvider {
        let spec = ModelSpec(
            id: config.model,
            reasoning: false,
            inputModalities: ["text"],
            contextWindow: config.contextWindow,
            maxTokens: config.maxTokens
        )
        return AnthropicProvider(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            apiProtocol: config.apiProtocol,
            customHeaders: config.customHeaders,
            models: [spec],
            defaultRequestMaxTokens: config.maxTokens
        )
    }

    /// 构造 Provider + 对应的 ModelPolicy（primary 指向配置模型）。
    /// 注意：AnthropicProvider.name 固定为 "anthropic"，故 ref 以 provider.name 为准。
    public static func makeProviderAndPolicy(from config: LijiConfig) -> (ModelProvider, ModelPolicy) {
        let provider = makeProvider(from: config)
        let policy = ModelPolicy(primary: "\(provider.name)/\(config.model)")
        return (provider, policy)
    }
}
