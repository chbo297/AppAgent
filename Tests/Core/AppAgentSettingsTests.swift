import XCTest
@testable import AppAgent

/// AppAgent 接口配置能力（AppAgentEndpointSettings）的纯逻辑单测：
/// 协议分组建 Provider、按序 ModelPolicy、模型引用。不触碰 UserDefaults/Keychain/网络。
final class AppAgentSettingsTests: XCTestCase {

    func testOneAPIDefault() {
        let s = AppAgentEndpointSettings.oneAPIDefault
        XCTAssertEqual(s.enabledModels.count, 1)
        XCTAssertEqual(s.enabledModels.first?.apiProtocol, .openaiCompletions)
        XCTAssertFalse(s.hasUsableAPIKey)
        XCTAssertFalse(s.isUsable) // 无 apiKey
    }

    func testModelRefsAndProviderName() {
        var s = AppAgentEndpointSettings.oneAPIDefault
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
        var s = AppAgentEndpointSettings.oneAPIDefault
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
        var s = AppAgentEndpointSettings.oneAPIDefault
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
        var s = AppAgentEndpointSettings.oneAPIDefault
        s.enabledModels = []
        XCTAssertNil(s.modelPolicy)
        XCTAssertNil(s.primaryModelRef)
        XCTAssertTrue(s.makeProviders().isEmpty)
    }

    /// 同一模型 id 两种协议都启用时，视为两个独立条目（各自 provider 前缀不同）。
    func testSameModelUnderTwoProtocolsAreTwoEntries() {
        var s = AppAgentEndpointSettings.oneAPIDefault
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

    /// base 已含 /v1 时不能再拼一个 /v1，否则 Anthropic 探查必然 404 —— 这正是
    /// OneAPI 场景下「只探到 OpenAI、探不到 Anthropic」的原因。
    func testAnthropicModelsURLDoesNotDoubleV1() {
        XCTAssertEqual(
            AppAgentModelDiscovery.modelsURL(
                baseURL: "https://oneapi-comate.baidu-int.com/v1", apiProtocol: .anthropicMessages
            )?.absoluteString,
            "https://oneapi-comate.baidu-int.com/v1/models"
        )
        XCTAssertEqual(
            AppAgentModelDiscovery.modelsURL(
                baseURL: "https://api.anthropic.com/", apiProtocol: .anthropicMessages
            )?.absoluteString,
            "https://api.anthropic.com/v1/models"
        )
        XCTAssertEqual(
            AppAgentModelDiscovery.modelsURL(
                baseURL: "https://oneapi-comate.baidu-int.com/v1", apiProtocol: .openaiCompletions
            )?.absoluteString,
            "https://oneapi-comate.baidu-int.com/v1/models"
        )
        XCTAssertNil(AppAgentModelDiscovery.modelsURL(baseURL: "  ", apiProtocol: .openaiCompletions))
    }
}
