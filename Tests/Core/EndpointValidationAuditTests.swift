import XCTest
@testable import AppAgent

final class EndpointValidationAuditTests: XCTestCase {
    func testInvalidTokenLimitsCannotProduceUsableSettings() {
        for (context, output) in [(0, 8192), (-1, 8192), (200_000, 0), (200_000, -1)] {
            let settings = AppAgentEndpointSettings(
                baseURL: "https://example.com/v1", apiKey: "test",
                enabledModels: [.init(modelId: "m", apiProtocol: .openaiCompletions)],
                contextWindow: context, maxTokens: output
            )
            XCTAssertFalse(settings.isUsable)
            XCTAssertNil(settings.modelPolicy)
            XCTAssertTrue(settings.makeProviders().isEmpty)
        }
    }

    func testInvalidDiscoveryTimeoutsFailWithoutStartingRequest() async {
        for timeout in [Double.nan, .infinity, -1, 0, .greatestFiniteMagnitude] {
            let result = await AppAgentModelDiscovery.probeAvailability(
                candidate: .init(modelId: "m", apiProtocol: .openaiCompletions),
                baseURL: "https://example.com/v1", apiKey: "test", customHeaders: [:],
                contextWindow: 200_000, maxTokens: 8192, timeout: timeout
            )
            XCTAssertFalse(result.isAvailable)
            XCTAssertNotNil(result.failureReason)
        }
    }

    func testModelReferencesRejectEmptyComponentsAndPreserveSlashesInModelID() async {
        let central = ModelProviderCentral()
        await central.register(name: "provider", provider: AnthropicProvider(
            baseURL: "https://example.com", apiKey: "test", models: [ModelSpec(id: "m/v2")]
        ))
        for ref in ["/provider/m/v2", "provider/", "/m/v2"] {
            let resolved = await central.resolve(modelReference: ref)
            XCTAssertNil(resolved, "Invalid model reference: \(ref)")
        }
        let resolved = await central.resolve(modelReference: "provider/m/v2")
        XCTAssertEqual(resolved?.modelId, "m/v2")
    }
}
