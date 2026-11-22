import Foundation
import XCTest
@testable import AppAgent

final class EndpointSettingsPersistenceTests: XCTestCase {
    func testClearRemovesCredentialAndKeepsEmptyMarkerWithoutClearingPreferences() throws {
        let suite = "AppAgentPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        var credential = ""
        let configured = AppAgentEndpointSettings(
            baseURL: "https://example.invalid/v1",
            apiKey: "synthetic-test-credential",
            enabledModels: [
                AppAgentModelRef(modelId: "test", apiProtocol: .openaiCompletions)
            ]
        )
        defaults.set(true, forKey: AppAgentSettingsStore.alwaysShowThinkingKey)
        XCTAssertTrue(AppAgentSettingsStore.persist(configured, defaults: defaults) {
            credential = $0
            return true
        })
        let encoded = try XCTUnwrap(defaults.data(forKey: AppAgentSettingsStore.storageKey))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(credential))
        XCTAssertTrue(AppAgentSettingsStore.persist(AppAgentEndpointSettings(), defaults: defaults) {
            credential = $0
            return true
        })
        XCTAssertEqual(credential, "")
        let clearedData = try XCTUnwrap(defaults.data(forKey: AppAgentSettingsStore.storageKey))
        let cleared = try JSONDecoder().decode(AppAgentEndpointSettings.self, from: clearedData)
        XCTAssertEqual(cleared.baseURL, "")
        XCTAssertFalse(cleared.isUsable)
        XCTAssertTrue(defaults.bool(forKey: AppAgentSettingsStore.alwaysShowThinkingKey))
    }

    func testCredentialFailureDoesNotPublishSavedOrClearedConfiguration() throws {
        let suite = "AppAgentPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let original = AppAgentEndpointSettings(baseURL: "https://original.invalid/v1")
        XCTAssertTrue(AppAgentSettingsStore.persist(original, defaults: defaults) { _ in
            true
        })
        let before = defaults.data(forKey: AppAgentSettingsStore.storageKey)
        for replacement in [
            AppAgentEndpointSettings(baseURL: "https://replacement.invalid/v1", apiKey: "synthetic"),
            AppAgentEndpointSettings()
        ] {
            XCTAssertFalse(AppAgentSettingsStore.persist(replacement, defaults: defaults) { _ in
                false
            })
            XCTAssertEqual(defaults.data(forKey: AppAgentSettingsStore.storageKey), before)
        }
    }
}
