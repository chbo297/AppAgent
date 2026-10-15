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
        guard isUsable else {
            return []
        }
        let settings = normalized

        // 保序分组：protocol -> [modelId]
        var order: [APIProtocol] = []
        var grouped: [APIProtocol: [String]] = [:]
        for ref in settings.enabledModels {
            if grouped[ref.apiProtocol] == nil {
                grouped[ref.apiProtocol] = []
                order.append(ref.apiProtocol)
            }
            grouped[ref.apiProtocol]?.append(ref.modelId)
        }

        return order.compactMap { proto in
            guard let ids = grouped[proto], !ids.isEmpty else {
                return nil
            }
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
                baseURL: settings.baseURL,
                apiKey: settings.apiKey,
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
        guard let primary = refs.first else {
            return nil
        }
        return ModelPolicy(primary: primary, fallbacks: Array(refs.dropFirst()))
    }
}

public extension AIAgent {
    /// 应用一份接口设置：刷新本接口的 Provider 注册项，并把 `modelPolicy` 指向启用模型。
    /// 旧的 AppAgent endpoint provider 会被移除，避免失效模型继续留在注册表里。
    func applyEndpointSettings(_ settings: AppAgentEndpointSettings) async {
        // 注册入口统一校验并清理旧项；无效配置也必须清理同名 provider。
        await providerCentral.register(settings: settings)
        guard settings.isUsable else {
            modelPolicy = nil
            Logger.error(
                "AIAgent",
                "applyEndpointSettings: rejected unusable endpoint configuration"
            )
            return
        }
        modelPolicy = settings.modelPolicy
        if let reference = settings.primaryModelRef,
           let resolved = await providerCentral.resolve(modelReference: reference) {
            _ = applyProviderUpdate(
                provider: resolved.provider,
                modelId: resolved.modelId,
                reference: reference,
                modelPolicy: settings.modelPolicy
            )
        }
        Logger.info(
            "AIAgent",
            "applyEndpointSettings: providers=\(Set(settings.enabledModels.map(\.apiProtocol)).count), primary=\(settings.primaryModelRef ?? "nil")"
        )
    }
}

public extension ModelProviderCentral {
    /// 替换 Settings 管理的 Provider；无效配置移除旧项，保留宿主自行注册的 Provider。
    func register(settings: AppAgentEndpointSettings) async {
        let entries = settings.makeProviders()
        let desiredNames = Set(entries.map(\.name))
        let managedNames = Set(APIProtocol.allCases.map {
            settings.providerName(for: $0)
        })
        for name in registeredNames where managedNames.contains(name) && !desiredNames.contains(name) {
            unregister(name: name)
        }
        for entry in entries {
            register(name: entry.name, provider: entry.provider)
        }
    }
}
