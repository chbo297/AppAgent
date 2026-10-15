import XCTest
@testable import AppAgent

/// AppAgent 接口配置能力（AppAgentEndpointSettings）的纯逻辑单测：
/// 协议分组建 Provider、按序 ModelPolicy、模型引用。不触碰 UserDefaults/Keychain/网络。
final class AppAgentSettingsTests: XCTestCase {

    func testDefaultIsUnconfigured() {
        let s = AppAgentEndpointSettings()
        XCTAssertEqual(s.baseURL, "")
        XCTAssertEqual(s.apiKey, "")
        XCTAssertTrue(s.customHeaders.isEmpty)
        XCTAssertTrue(s.enabledModels.isEmpty)
        XCTAssertFalse(s.hasUsableBaseURL)
        XCTAssertFalse(s.hasUsableAPIKey)
        XCTAssertFalse(s.isUsable)
        XCTAssertNil(s.modelPolicy)
        XCTAssertTrue(s.makeProviders().isEmpty)
    }

    func testModelRefsAndProviderName() {
        var s = AppAgentEndpointSettings()
        s.baseURL = "https://example.com/v1"
        s.apiKey = "k"
        s.enabledModels = [
            AppAgentModelRef(modelId: "gpt-4o", apiProtocol: .openaiCompletions),
            AppAgentModelRef(modelId: "claude-3", apiProtocol: .anthropicMessages)
        ]
        XCTAssertTrue(s.isUsable)
        XCTAssertEqual(s.primaryModelRef, "appagent-openai-completions/gpt-4o")
        XCTAssertEqual(s.orderedModelRefs, [
            "appagent-openai-completions/gpt-4o",
            "appagent-anthropic-messages/claude-3"
        ])
    }

    func testModelPolicyPrimaryAndOrderedFallbacks() {
        var s = AppAgentEndpointSettings(baseURL: "https://example.com/v1", apiKey: "k")
        s.enabledModels = [
            AppAgentModelRef(modelId: "a", apiProtocol: .openaiCompletions),
            AppAgentModelRef(modelId: "b", apiProtocol: .openaiCompletions),
            AppAgentModelRef(modelId: "c", apiProtocol: .anthropicMessages)
        ]
        let policy = s.modelPolicy
        XCTAssertEqual(policy?.primary, "appagent-openai-completions/a")
        XCTAssertEqual(policy?.fallbacks, [
            "appagent-openai-completions/b",
            "appagent-anthropic-messages/c"
        ])
    }

    func testMakeProvidersGroupsByProtocolPreservingOrder() {
        var s = AppAgentEndpointSettings()
        s.baseURL = "https://example.com/v1"
        s.apiKey = "k"
        s.enabledModels = [
            AppAgentModelRef(modelId: "a", apiProtocol: .openaiCompletions),
            AppAgentModelRef(modelId: "c", apiProtocol: .anthropicMessages),
            AppAgentModelRef(modelId: "b", apiProtocol: .openaiCompletions)
        ]
        let providers = s.makeProviders()
        // 两种协议 → 两个 provider（保序：先 openai 后 anthropic）。
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].name, "appagent-openai-completions")
        XCTAssertEqual(providers[1].name, "appagent-anthropic-messages")
        // openai provider 含 a、b 两个模型（保序）。
        XCTAssertEqual(providers[0].provider.models.map(\.id), ["a", "b"])
        XCTAssertEqual(providers[1].provider.models.map(\.id), ["c"])
    }

    func testEmptyModelsYieldNilPolicy() {
        var s = AppAgentEndpointSettings(baseURL: "https://example.com/v1", apiKey: "k")
        s.enabledModels = []
        XCTAssertNil(s.modelPolicy)
        XCTAssertNil(s.primaryModelRef)
        XCTAssertTrue(s.makeProviders().isEmpty)
    }

    /// 同一模型 id 两种协议都启用时，视为两个独立条目（各自 provider 前缀不同）。
    func testSameModelUnderTwoProtocolsAreTwoEntries() {
        var s = AppAgentEndpointSettings()
        s.baseURL = "https://example.com/v1"
        s.apiKey = "k"
        s.enabledModels = [
            AppAgentModelRef(modelId: "claude-4", apiProtocol: .anthropicMessages),
            AppAgentModelRef(modelId: "claude-4", apiProtocol: .openaiCompletions)
        ]
        XCTAssertEqual(s.orderedModelRefs, [
            "appagent-anthropic-messages/claude-4",
            "appagent-openai-completions/claude-4"
        ])
        XCTAssertEqual(s.makeProviders().count, 2)
    }

    /// base 已含 /v1 时不能再拼一个 /v1，否则 Anthropic 探查会 404。
    func testAnthropicModelsURLDoesNotDoubleV1() {
        XCTAssertEqual(
            AppAgentModelDiscovery.modelsURL(
                baseURL: "https://example.com/v1", apiProtocol: .anthropicMessages
            )?.absoluteString,
            "https://example.com/v1/models"
        )
        XCTAssertEqual(
            AppAgentModelDiscovery.modelsURL(
                baseURL: "https://api.anthropic.com/", apiProtocol: .anthropicMessages
            )?.absoluteString,
            "https://api.anthropic.com/v1/models"
        )
        XCTAssertEqual(
            AppAgentModelDiscovery.modelsURL(
                baseURL: "https://example.com/v1", apiProtocol: .openaiCompletions
            )?.absoluteString,
            "https://example.com/v1/models"
        )
        XCTAssertNil(AppAgentModelDiscovery.modelsURL(baseURL: "  ", apiProtocol: .openaiCompletions))
    }

    /// 同一校验约束覆盖 provider、模型引用和 policy，尤其不能接受空 primary + 有效 fallback。
    func testInvalidConfigurationsHaveNoRuntimeSelection() {
        let valid = validSettings()
        var invalid: [AppAgentEndpointSettings] = []
        for url in ["", " \n", "example.com/v1", "file:///tmp/models", "https://",
                    "https://example.com/v1?x=1", "https://example.com/v1#fragment",
                    "https://user:password@example.com/v1", "https://example.com/a b"] {
            var settings = valid
            settings.baseURL = url
            invalid.append(settings)
            XCTAssertFalse(settings.hasUsableBaseURL, url)
            XCTAssertNil(AppAgentModelDiscovery.modelsURL(baseURL: url, apiProtocol: .openaiCompletions))
        }
        var missingKey = valid
        missingKey.apiKey = " \n\t"
        invalid.append(missingKey)
        for ids in [[], [""], [" \n", "valid"], ["valid", " \t"]] {
            var settings = valid
            settings.enabledModels = ids.map {
                AppAgentModelRef(modelId: $0, apiProtocol: .openaiCompletions)
            }
            invalid.append(settings)
        }
        for settings in invalid {
            XCTAssertFalse(settings.isUsable)
            XCTAssertNil(settings.primaryModelRef)
            XCTAssertTrue(settings.orderedModelRefs.isEmpty)
            XCTAssertNil(settings.modelPolicy)
            XCTAssertTrue(settings.makeProviders().isEmpty)
        }
    }

    func testNormalizedProviderMatchesPolicyAndPreservesHostHeaders() async throws {
        var settings = validSettings()
        settings.baseURL = " \nhttps://example.com/v1 \t"
        settings.apiKey = " test-key \n"
        settings.enabledModels[0].modelId = " model/a \n"
        settings.customHeaders = ["X-Host-Header": "host-value"]
        let provider = try XCTUnwrap(settings.makeProviders().first?.provider as? AnthropicProvider)
        XCTAssertEqual(provider.baseURL, "https://example.com/v1")
        XCTAssertEqual(provider.apiKey, "test-key")
        XCTAssertEqual(provider.models.map(\.id), ["model/a"])
        XCTAssertEqual(provider.customHeaders, settings.customHeaders)
        XCTAssertEqual(settings.modelPolicy?.primary, "appagent-openai-completions/model/a")
        let central = ModelProviderCentral()
        await central.register(settings: settings)
        let resolved = await central.resolve(modelReference: try XCTUnwrap(settings.primaryModelRef))
        XCTAssertEqual(resolved?.modelId, "model/a")
    }

    /// 无效配置沿用同一协议时，也必须移除旧 provider；两个注册入口都锁住这个行为。
    func testInvalidApplyAndRegistrationRemoveOldProviders() async throws {
        let central = ModelProviderCentral()
        let agent = AIAgent(
            id: "endpoint-settings-test",
            profile: AIAgentProfile(registerBuiltInTools: false),
            toolCentral: ToolCentral(),
            providerCentral: central,
            memoryStorage: InMemoryMemoryStorage(),
            sessionStorage: InMemorySessionStorage()
        )
        let valid = validSettings()
        await agent.applyEndpointSettings(valid)
        XCTAssertEqual(agent.modelPolicy, valid.modelPolicy)
        var invalid = valid
        invalid.apiKey = " \n"
        await agent.applyEndpointSettings(invalid)
        let namesAfterApply = await central.registeredNames
        XCTAssertTrue(namesAfterApply.isEmpty)
        XCTAssertNil(agent.modelPolicy)
        let resolved = await agent.resolveProvider()
        XCTAssertNil(resolved)
        let session = await agent.createSession()
        XCTAssertNil(session.provider)

        let hostProvider = try XCTUnwrap(valid.makeProviders().first?.provider as? AnthropicProvider)
        await central.register(name: "appagent-host-custom", provider: hostProvider)
        var mixed = valid
        mixed.enabledModels.append(AppAgentModelRef(modelId: "b", apiProtocol: .anthropicMessages))
        await central.register(settings: mixed)
        await central.register(settings: valid)
        let namesAfterReplacement = await central.registeredNames
        XCTAssertEqual(Set(namesAfterReplacement), ["appagent-host-custom", "appagent-openai-completions"])
        await central.register(settings: invalid)
        let namesAfterInvalid = await central.registeredNames
        XCTAssertEqual(namesAfterInvalid, ["appagent-host-custom"])
        let host = await central.provider(named: "appagent-host-custom")
        XCTAssertTrue((host as? AnthropicProvider) === hostProvider)
    }

    func testDiscoveryRejectsMissingKeyAndBlankModelBeforeNetwork() async {
        do {
            _ = try await AppAgentModelDiscovery.probeProtocols(
                baseURL: "https://example.com/v1", apiKey: " \n",
                candidateProtocols: [.openaiCompletions], customHeaders: [:]
            )
            XCTFail("Missing key must be rejected before discovery")
        } catch {
            guard case AppAgentModelDiscovery.DiscoveryError.missingAPIKey = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        let result = await AppAgentModelDiscovery.probeAvailability(
            candidate: AppAgentModelCandidate(modelId: " \n", apiProtocol: .openaiCompletions),
            baseURL: "https://example.com/v1", apiKey: "test-key", customHeaders: [:],
            contextWindow: 1000, maxTokens: 100
        )
        XCTAssertFalse(result.isAvailable)
        XCTAssertEqual(result.failureReason, "接口地址、API Key 或模型 id 无效")
    }

    private func validSettings() -> AppAgentEndpointSettings {
        AppAgentEndpointSettings(
            baseURL: "https://example.com/v1",
            apiKey: "test-key",
            enabledModels: [AppAgentModelRef(modelId: "a", apiProtocol: .openaiCompletions)]
        )
    }
}
