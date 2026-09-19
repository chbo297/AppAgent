//
//  EndpointProviderFactory.swift
//  AppAgent — 端点配置 → ModelProvider
//
//  由「接口地址 + key + 协议 + 模型」这组通用端点参数构造 ModelProvider。
//  当前复用通用 HTTP+SSE 的 AnthropicProvider（其内部按 apiProtocol 分派
//  anthropic-messages / openai-completions 两种线格式）。
//
//  宿主自己的配置类型（某个 App 的 XxxConfig）只需把字段喂进来，AppAgent 不感知宿主类型。
//

import Foundation

public enum EndpointProviderFactory {

    /// 依据端点参数构造 Provider。
    public static func makeProvider(
        baseURL: String,
        apiKey: String,
        apiProtocol: APIProtocol,
        model: String,
        customHeaders: [String: String] = [:],
        contextWindow: Int = 200_000,
        maxTokens: Int = 8192
    ) -> ModelProvider {
        let spec = ModelSpec(
            id: model,
            reasoning: false,
            inputModalities: ["text"],
            contextWindow: contextWindow,
            maxTokens: maxTokens
        )
        return AnthropicProvider(
            baseURL: baseURL,
            apiKey: apiKey,
            apiProtocol: apiProtocol,
            customHeaders: customHeaders,
            models: [spec],
            defaultRequestMaxTokens: maxTokens
        )
    }

    /// 构造 Provider + 对应的 ModelPolicy（primary 指向给定模型）。
    /// 注意：AnthropicProvider.name 固定为 "anthropic"，故 ref 以 provider.name 为准。
    public static func makeProviderAndPolicy(
        baseURL: String,
        apiKey: String,
        apiProtocol: APIProtocol,
        model: String,
        customHeaders: [String: String] = [:],
        contextWindow: Int = 200_000,
        maxTokens: Int = 8192
    ) -> (ModelProvider, ModelPolicy) {
        let provider = makeProvider(baseURL: baseURL, apiKey: apiKey, apiProtocol: apiProtocol,
                                    model: model, customHeaders: customHeaders,
                                    contextWindow: contextWindow, maxTokens: maxTokens)
        let policy = ModelPolicy(primary: "\(provider.name)/\(model)")
        return (provider, policy)
    }
}
