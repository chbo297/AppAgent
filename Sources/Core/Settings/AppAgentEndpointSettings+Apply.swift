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
    /// 空配置或无效配置取消所有会话的运行并清除模型选择，保留聊天历史和宿主注册项。
    func applyEndpointSettings(_ settings: AppAgentEndpointSettings) async {
        await providerCentral.applyEndpointSettings(settings, to: self)
    }
}

// A nil policy normally permits host defaults. Keep explicit endpoint ownership,
// without retaining agents or credentials, and revoke leases captured by running loops.
private struct EndpointRuntimeState: Sendable {
    let agent: WeakLocked<AIAgent>
    let revoked: Locked<Bool>
}

private let endpointRuntimeStates = Locked<[ObjectIdentifier: EndpointRuntimeState]>(wrappedValue: [:])

extension AIAgent {
    var isEndpointConfigurationCleared: Bool {
        endpointRuntimeStates.mutate {
            guard let state = $0[ObjectIdentifier(self)], state.agent.wrappedValue === self else {
                return false
            }
            return state.revoked.wrappedValue
        }
    }

    func endpointProviderForRun(_ provider: any ModelProvider) -> any ModelProvider {
        endpointRuntimeStates.mutate {
            guard let state = $0[ObjectIdentifier(self)], state.agent.wrappedValue === self else {
                return provider
            }
            return EndpointRunProvider(base: provider, revoked: state.revoked)
        }
    }

    fileprivate func setEndpointConfigurationCleared(_ cleared: Bool) {
        endpointRuntimeStates.mutate { states in
            states = states.filter {
                $0.value.agent.wrappedValue != nil
            }
            let id = ObjectIdentifier(self)
            if let state = states[id], state.agent.wrappedValue === self {
                if cleared {
                    state.revoked.wrappedValue = true
                    return
                }
                if !state.revoked.wrappedValue {
                    return
                }
            }
            states[id] = EndpointRuntimeState(
                agent: WeakLocked(wrappedValue: self),
                revoked: Locked(wrappedValue: cleared)
            )
        }
    }
}

/// A loop may suspend after capturing its provider. Clearing revokes that captured lease,
/// including after a subsequent valid save. Ordinary valid updates keep running leases alive.
private struct EndpointRunProvider: ModelProvider {
    let base: any ModelProvider
    let revoked: Locked<Bool>

    var name: String {
        base.name
    }
    var baseURL: String {
        base.baseURL
    }
    var apiKey: String {
        base.apiKey
    }
    var apiProtocol: APIProtocol {
        base.apiProtocol
    }
    var customHeaders: [String: String] {
        base.customHeaders
    }
    var models: [ModelSpec] {
        base.models
    }
    var requestTimeout: TimeInterval {
        base.requestTimeout
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        guard !Task.isCancelled, !revoked.wrappedValue else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AIAgentError.cancelled)
            }
        }
        return base.streamCompletion(messages: messages, system: system, tools: tools, modelId: modelId)
    }
}

extension ModelProviderCentral {
    // Registration, resolution and publication share one actor turn with no suspension.
    // An earlier valid apply cannot resume after a clear and republish its provider.
    fileprivate func applyEndpointSettings(_ settings: AppAgentEndpointSettings, to agent: AIAgent) {
        replaceEndpointProviders(settings)
        agent.setEndpointConfigurationCleared(!settings.isUsable)
        agent.modelPolicy = settings.modelPolicy
        guard settings.isUsable else {
            for session in agent.sessionManager.allSessions {
                session.resetModelSelection()
                session.cancel()
            }
            Logger.info("AIAgent", "applyEndpointSettings: model configuration cleared")
            return
        }
        if let reference = settings.primaryModelRef,
           let resolved = resolve(modelReference: reference) {
            _ = agent.applyProviderUpdate(
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
        replaceEndpointProviders(settings)
    }
}

private extension ModelProviderCentral {
    func replaceEndpointProviders(_ settings: AppAgentEndpointSettings) {
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
