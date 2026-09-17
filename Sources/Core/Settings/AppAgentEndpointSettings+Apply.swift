//
//  AppAgentEndpointSettings+Apply.swift
//  AppAgent
//
//  把一份接口设置落到运行时：按协议把启用模型拆成多个 Provider 注册进 ModelProviderCentral，
//  并按用户排序设置 ModelPolicy（primary + 有序 fallbacks）。
//

import Foundation

public extension AppAgentEndpointSettings {
    /// 按「协议 → 该协议下的启用模型」构造 Provider 列表。
    /// 同一接口若混用多种协议，会生成多个 Provider 实例（共享 baseURL/apiKey）。
    func makeProviders() -> [(name: String, provider: any ModelProvider)] {
        // 保序分组：protocol -> [modelId]
        var order: [APIProtocol] = []
        var grouped: [APIProtocol: [String]] = [:]
        for ref in enabledModels {
            if grouped[ref.apiProtocol] == nil {
                grouped[ref.apiProtocol] = []
                order.append(ref.apiProtocol)
            }
            grouped[ref.apiProtocol]?.append(ref.modelId)
        }

        return order.compactMap { proto in
            guard let ids = grouped[proto], !ids.isEmpty else { return nil }
            let specs = ids.map { id in
                ModelSpec(
                    id: id,
                    reasoning: false,
                    inputModalities: ["text"],
                    contextWindow: contextWindow,
                    maxTokens: maxTokens
                )
            }
            let provider = AnthropicProvider(
                baseURL: baseURL,
                apiKey: apiKey,
                apiProtocol: proto,
                customHeaders: customHeaders,
                models: specs,
                defaultRequestMaxTokens: maxTokens
            )
            return (name: providerName(for: proto), provider: provider)
        }
    }

    /// 由启用模型顺序构造 ModelPolicy（`[0]` primary，其余 fallbacks）。
    var modelPolicy: ModelPolicy? {
        let refs = orderedModelRefs
        guard let primary = refs.first else { return nil }
        return ModelPolicy(primary: primary, fallbacks: Array(refs.dropFirst()))
    }
}

public extension AIAgent {
    /// 应用一份接口设置：注册/替换本接口的所有 Provider，并把 `modelPolicy` 指向启用模型。
    /// 之后创建的新会话会使用新配置（既有会话仍持有创建时快照的 provider）。
    func applyEndpointSettings(_ settings: AppAgentEndpointSettings) async {
        for entry in settings.makeProviders() {
            await providerCentral.register(name: entry.name, provider: entry.provider)
        }
        modelPolicy = settings.modelPolicy
        Logger.info(
            "AIAgent",
            "applyEndpointSettings: providers=\(settings.makeProviders().count), primary=\(settings.primaryModelRef ?? "nil")"
        )
    }
}

public extension ModelProviderCentral {
    /// 便捷：把一份接口设置的所有 Provider 注册进本中心（供宿主 app 启动时使用）。
    func register(settings: AppAgentEndpointSettings) async {
        for entry in settings.makeProviders() {
            await register(name: entry.name, provider: entry.provider)
        }
    }
}
