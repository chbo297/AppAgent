//
//  ModelProviderCentral.swift
//  AppAgent
//

import Foundation

/// Model selection policy with primary model and ordered fallbacks.
///
/// Both `primary` and `fallbacks` use compound "providerName/modelId" format.
/// The primary model is used by default when creating sessions. Fallbacks are
/// reserved for future runtime fallback support.
public struct ModelPolicy: Sendable, Codable, Equatable {
    /// Primary model reference (e.g., "anthropic/claude-sonnet-4-20250514").
    public var primary: String
    /// Ordered fallback model references, reserved for future use.
    public var fallbacks: [String]

    public init(primary: String, fallbacks: [String] = []) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    /// Convenience init from a bare model reference (no fallbacks).
    public init(_ modelReference: String) {
        self.primary = modelReference
        self.fallbacks = []
    }
}

/// Model Provider 总站 — 所有 ModelProvider 实例的注册中心。
///
/// Providers are registered with a unique name (e.g., "bdllm", "anthropic")
/// and resolved by compound model references in the format "providerName/modelId".
///
/// Usage:
///   await ModelProviderCentral.default.register(name: "bdllm", provider: myProvider)
///   let result = await ModelProviderCentral.default.resolve(modelReference: "bdllm/Claude sonnet 4.6")
public actor ModelProviderCentral {

    /// The default instance, used by most apps.
    public static let `default` = ModelProviderCentral()

    private var providers: [String: any ModelProvider] = [:]

    public init() {}

    // MARK: - Registration

    /// Register a provider under a given name.
    public func register(name: String, provider: any ModelProvider) {
        providers[name] = provider
        Logger.info("ModelProviderCentral", "registered: name=\(name), models=[\(provider.models.map(\.id).joined(separator: ", "))]")
    }

    /// Unregister a provider by name.
    public func unregister(name: String) {
        providers.removeValue(forKey: name)
        Logger.info("ModelProviderCentral", "unregistered: name=\(name)")
    }

    /// All registered provider names.
    public var registeredNames: [String] {
        StableSort.byName(Array(providers.keys))
    }

    /// Get a provider by name.
    public func provider(named name: String) -> (any ModelProvider)? {
        providers[name]
    }

    // MARK: - Resolution

    /// Resolve a compound model reference like "bdllm/Claude sonnet 4.6".
    ///
    /// The reference is split on the first "/" only, so model IDs containing "/"
    /// are supported (e.g., "provider/model/v2" resolves provider "provider" with model "model/v2").
    ///
    /// - Returns: A tuple of `(provider, modelId)` if both the provider name and model ID match,
    ///   or `nil` otherwise.
    public func resolve(modelReference: String) -> (provider: any ModelProvider, modelId: String)? {
        let parts = modelReference.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
            Logger.warning("ModelProviderCentral", "resolve: invalid reference format '\(modelReference)', expected 'providerName/modelId'")
            return nil
        }

        let providerName = String(parts[0])
        let modelId = String(parts[1])

        guard let provider = providers[providerName] else {
            Logger.warning("ModelProviderCentral", "resolve: provider '\(providerName)' not found")
            return nil
        }

        guard provider.models.contains(where: { $0.id == modelId }) else {
            Logger.warning("ModelProviderCentral", "resolve: model '\(modelId)' not found in provider '\(providerName)', available=[\(provider.models.map(\.id).joined(separator: ", "))]")
            return nil
        }

        return (provider: provider, modelId: modelId)
    }

    /// Resolve the default provider and model, ordered by `APIProtocol` case declaration order.
    /// Used as a fallback when no model is explicitly configured.
    public func resolveDefault() -> (provider: any ModelProvider, modelId: String)? {
        for proto in APIProtocol.allCases {
            for (_, provider) in providers where provider.apiProtocol == proto {
                if let model = provider.models.first {
                    return (provider: provider, modelId: model.id)
                }
            }
        }
        return nil
    }
}
