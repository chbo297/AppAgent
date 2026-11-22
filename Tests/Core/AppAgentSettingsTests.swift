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
        XCTAssertEqual(result.failureReason, "接口地址、API Key、模型 id 或 token 上限无效")
    }

    func testClearCancelsRunAndRevokesExistingAndNewSessionsWithoutDeletingHistory() async throws {
        let entered = expectation(description: "Run captured its provider")
        let gate = ReadySignal()
        let preparations = Locked(wrappedValue: 0)
        let agent = makeAgent(profile: .init(
            additionalPromptBuilders: [PromptBuilder("hold-first-run") { _ in
                let first = preparations.mutate { count in
                    count += 1
                    return count == 1
                }
                if first {
                    entered.fulfill()
                    await gate.wait()
                }
                return nil
            }],
            autoPersist: false,
            registerBuiltInTools: false
        ))
        await agent.applyEndpointSettings(validSettings())
        let provider = SettingsCountingProvider()
        await agent.providerCentral.register(name: "host", provider: provider)
        let session = await agent.createSession(title: "Keep this history")
        XCTAssertTrue(session.switchModel(provider: provider, modelId: "a", reference: "host/a"))
        let stream = session.sendMessage("Keep this question")
        await fulfillment(of: [entered], timeout: 2)
        let history = session.messages.map(\.id)
        XCTAssertFalse(history.isEmpty)

        await agent.applyEndpointSettings(AppAgentEndpointSettings())
        await gate.signal()
        var cancellations = 0
        for await event in stream {
            if case .error(let error) = event, case .cancelled = error as? AIAgentError {
                cancellations += 1
            }
        }
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.messages.map(\.id), history)
        XCTAssertEqual(session.title, "Keep this history")
        XCTAssertNil(session.provider)
        XCTAssertNil(session.modelId)
        XCTAssertNil(agent.modelPolicy)
        let activeReference: String? = session.uiState.get(SessionUIState.activeModelKey)
        XCTAssertNil(activeReference)
        let registeredNames = await agent.providerCentral.registeredNames
        XCTAssertEqual(registeredNames, ["host"])

        let newSession = await agent.createSession()
        let explicitSession = await agent.createSession(modelReference: "host/a")
        for candidate in [session, newSession, explicitSession] {
            XCTAssertNil(candidate.provider, "Cleared agents must not select a host default")
            XCTAssertNil(candidate.modelId)
            var errors = 0
            for await event in candidate.sendMessage("No model configured") {
                if case .error = event {
                    errors += 1
                }
            }
            XCTAssertEqual(errors, 1)
        }
        XCTAssertEqual(provider.requests.wrappedValue, 0)
    }

    func testClearRejectsLateSelectionAndValidSaveReconfiguresSessions() async throws {
        let agent = makeAgent()
        await agent.applyEndpointSettings(validSettings())
        let session = await agent.createSession()
        let oldSelection = session.modelSelectionSnapshot()
        let oldProvider = try XCTUnwrap(oldSelection.provider)
        await agent.applyEndpointSettings(AppAgentEndpointSettings())
        XCTAssertFalse(session.switchModel(provider: oldProvider, modelId: "a", reference: "old/a"))

        var replacement = validSettings()
        replacement.enabledModels[0].modelId = "replacement"
        await agent.applyEndpointSettings(replacement)
        XCTAssertFalse(session.switchModel(
            provider: oldProvider, modelId: "a", reference: "old/a",
            expectedGeneration: oldSelection.generation
        ))
        XCTAssertEqual(session.modelId, "replacement")
        XCTAssertEqual(agent.modelPolicy, replacement.modelPolicy)
        let newSession = await agent.createSession()
        XCTAssertEqual(newSession.modelId, "replacement")
    }

    func testCapturedRunProviderStaysRevokedAfterNewValidConfiguration() async throws {
        let agent = makeAgent()
        await agent.applyEndpointSettings(validSettings())
        let provider = SettingsCountingProvider()
        let session = await agent.sessionManager.createSession(provider: provider, modelId: "a")
        let captured = try XCTUnwrap(session.modelSelectionSnapshot().provider)

        // Ordinary valid updates preserve the running snapshot.
        await agent.applyEndpointSettings(validSettings())
        for try await _ in captured.streamCompletion(messages: [], system: [], tools: [], modelId: "a") {
        }
        XCTAssertEqual(provider.requests.wrappedValue, 1)

        await agent.applyEndpointSettings(AppAgentEndpointSettings())
        await agent.applyEndpointSettings(validSettings())
        do {
            for try await _ in captured.streamCompletion(messages: [], system: [], tools: [], modelId: "a") {
            }
            XCTFail("A new valid configuration must not revive an old run's credentials")
        } catch {
            guard case .cancelled = error as? AIAgentError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(provider.requests.wrappedValue, 1)
    }

    func testOverlappingApplyThenClearCannotPublishLateProvider() async {
        let agent = makeAgent()
        let settings = validSettings()
        let session = await agent.createSession()
        for _ in 0..<40 {
            let applying = Task {
                await agent.applyEndpointSettings(settings)
            }
            // Observe registration before issuing clear, without waiting for apply's caller.
            var observedRegistration = false
            for _ in 0..<1000 {
                if await agent.providerCentral.provider(named: "appagent-openai-completions") != nil {
                    observedRegistration = true
                    break
                }
                await Task.yield()
            }
            XCTAssertTrue(observedRegistration)
            await agent.applyEndpointSettings(AppAgentEndpointSettings())
            await applying.value
            XCTAssertNil(session.provider)
            XCTAssertNil(session.modelId)
            XCTAssertNil(agent.modelPolicy)
            let names = await agent.providerCentral.registeredNames
            XCTAssertTrue(names.isEmpty)
        }
    }

    private func makeAgent(
        profile: AIAgentProfile = .init(autoPersist: false, registerBuiltInTools: false)
    ) -> AIAgent {
        AIAgent(
            id: "settings-\(UUID().uuidString)", profile: profile,
            toolCentral: ToolCentral(), providerCentral: ModelProviderCentral(),
            memoryStorage: InMemoryMemoryStorage(), sessionStorage: InMemorySessionStorage()
        )
    }

    private func validSettings() -> AppAgentEndpointSettings {
        AppAgentEndpointSettings(
            baseURL: "https://example.com/v1",
            apiKey: "test-key",
            enabledModels: [AppAgentModelRef(modelId: "a", apiProtocol: .openaiCompletions)]
        )
    }
}

private struct SettingsCountingProvider: ModelProvider {
    let name = "host"
    let baseURL = "https://example.com"
    let apiKey = "test-key"
    let apiProtocol: APIProtocol = .openaiCompletions
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "a")]
    let requestTimeout: TimeInterval = 1
    let requests = Locked(wrappedValue: 0)

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        requests.mutate {
            $0 += 1
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Unexpected request"))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}
