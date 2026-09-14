//
//  DemoConfig.swift
//  AppAgentDemo
//

import Foundation

/// JSON-based demo app configuration.
/// Reads values from `config.json` bundled in the app.
///
/// Supports two JSON layouts:
/// - **New (recommended)**: nested `"providers"` dictionary + `"agents"` section (see config.json.example).
/// - **Legacy**: flat top-level fields (`baseUrl`, `apiKey`, `api`, `headers`, `models`).
///
/// Setup:
///   cp Examples/iOS/Resources/config.json.example Examples/iOS/Resources/config.json
///   Then edit config.json with your actual values.
struct DemoConfig {

    // MARK: - JSON Shape

    struct ModelEntry: Decodable {
        let id: String
        let name: String?
        let reasoning: Bool?
        let input: [String]?
        let contextWindow: Int?
        let maxTokens: Int?
    }

    struct ProviderEntry: Decodable {
        let baseUrl: String?
        let apiKey: String?
        let api: String?
        let headers: [String: String]?
        let models: [ModelEntry]?
    }

    struct ModelSelection: Decodable {
        let primary: String
        let fallbacks: [String]?
    }

    struct AIAgentDefaults: Decodable {
        let model: ModelSelection?
    }

    struct AgentsSection: Decodable {
        let defaults: AIAgentDefaults?
    }

    struct ConfigFile: Decodable {
        /// New nested format: { "providers": { "name": { ... } } }
        let providers: [String: ProviderEntry]?
        /// New agents section: { "agents": { "defaults": { "model": { ... } } } }
        let agents: AgentsSection?
        /// Legacy flat fields (backward compatibility).
        let baseUrl: String?
        let apiKey: String?
        let api: String?
        let headers: [String: String]?
        let models: [ModelEntry]?
    }

    // MARK: - Loaded values

    /// The parsed config, or nil if config.json is missing / malformed.
    static let loaded: ConfigFile? = {
        guard let url = bundledConfigURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ConfigFile.self, from: data)
    }()

    private static func bundledConfigURL() -> URL? {
        Bundle.main.url(forResource: "config", withExtension: "json")
            ?? Bundle.main.url(forResource: "config.json", withExtension: "example")
    }

    static var hasUsableProviderConfig: Bool {
        providerEntries.contains { entry in
            let apiKey = entry.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !apiKey.isEmpty
        }
    }

    private static var providerEntries: [ProviderEntry] {
        if let providers = loaded?.providers {
            return Array(providers.values)
        }
        return primaryProvider.map { [$0] } ?? []
    }

    /// The first provider entry (new format), or a synthesized entry from legacy flat fields.
    static var primaryProvider: ProviderEntry? {
        if let providers = loaded?.providers, let first = providers.values.first {
            return first
        }
        // Legacy fallback: treat the flat top-level as a single provider
        guard let loaded = loaded else { return nil }
        return ProviderEntry(
            baseUrl: loaded.baseUrl,
            apiKey: loaded.apiKey,
            api: loaded.api,
            headers: loaded.headers,
            models: loaded.models
        )
    }

    /// The raw `api` field from config.json (e.g. "anthropic-messages").
    static var api: String {
        primaryProvider?.api ?? ""
    }

    /// API key for the provider.
    static var apiKey: String {
        primaryProvider?.apiKey ?? ""
    }

    /// Base URL for the provider.
    /// AnthropicProvider appends "/v1/messages" itself, so we strip that suffix if present.
    static var baseURL: String {
        guard let raw = primaryProvider?.baseUrl, !raw.isEmpty else { return "" }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if trimmed.hasSuffix("/v1/messages") {
            return String(trimmed.dropLast("/v1/messages".count))
        }
        return trimmed
    }

    /// Custom HTTP headers.
    static var customHeaders: [String: String] {
        primaryProvider?.headers ?? [:]
    }

    /// All model configurations from the primary provider, converted to SDK type.
    static var modelConfigs: [ModelSpec] {
        guard let entries = primaryProvider?.models, !entries.isEmpty else {
            return [ModelSpec(id: "claude-sonnet-4-20250514")]
        }
        return entries.map { entry in
            ModelSpec(
                id: entry.id,
                reasoning: entry.reasoning ?? false,
                inputModalities: entry.input ?? ["text"],
                contextWindow: entry.contextWindow ?? 200_000,
                maxTokens: entry.maxTokens ?? 64_000
            )
        }
    }

    /// The first model ID from the models array (convenience for display).
    static var model: String {
        modelConfigs.first?.id ?? "claude-sonnet-4-20250514"
    }

    /// All model IDs from the config (convenience for display).
    static var allModels: [String] {
        modelConfigs.map(\.id)
    }

    // MARK: - Multi-provider support

    /// Build named providers from all entries in the config.
    /// Returns tuples of (name, provider) for registration with ModelProviderCentral.
    static var allProviders: [(name: String, provider: any ModelProvider)] {
        guard let providers = loaded?.providers else {
            // Legacy fallback: synthesize a single "default" provider
            guard primaryProvider != nil else { return [] }
            let provider = AnthropicProvider(
                baseURL: baseURL,
                apiKey: apiKey,
                apiProtocol: .anthropicMessages,
                customHeaders: customHeaders,
                models: modelConfigs
            )
            return [(name: "default", provider: provider)]
        }

        return providers.compactMap { (name, entry) in
            guard let models = entry.models, !models.isEmpty else { return nil }

            let modelConfigs = models.map { m in
                ModelSpec(
                    id: m.id,
                    reasoning: m.reasoning ?? false,
                    inputModalities: m.input ?? ["text"],
                    contextWindow: m.contextWindow ?? 200_000,
                    maxTokens: m.maxTokens ?? 64_000
                )
            }

            // Clean base URL
            var cleanedBaseURL = entry.baseUrl ?? ""
            if cleanedBaseURL.hasSuffix("/") { cleanedBaseURL = String(cleanedBaseURL.dropLast()) }
            if cleanedBaseURL.hasSuffix("/v1/messages") {
                cleanedBaseURL = String(cleanedBaseURL.dropLast("/v1/messages".count))
            }

            let provider = AnthropicProvider(
                baseURL: cleanedBaseURL,
                apiKey: entry.apiKey ?? "",
                apiProtocol: APIProtocol(rawValue: entry.api ?? "anthropic-messages") ?? .anthropicMessages,
                customHeaders: entry.headers ?? [:],
                models: modelConfigs
            )
            return (name: name, provider: provider)
        }
    }

    // MARK: - Model Policy

    /// The model policy from the agents section, if present.
    static var modelPolicy: ModelPolicy? {
        guard let selection = loaded?.agents?.defaults?.model else { return nil }
        return ModelPolicy(
            primary: selection.primary,
            fallbacks: selection.fallbacks ?? []
        )
    }
}
