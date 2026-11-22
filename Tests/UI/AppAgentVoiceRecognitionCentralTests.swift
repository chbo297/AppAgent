#if canImport(UIKit)
import XCTest
@testable import AppAgent

/// 引擎选择的回退规则：选中的引擎没打包进来或没配好凭据时，语音输入必须仍然可用（回退系统识别）。
@MainActor
final class AppAgentVoiceRecognitionCentralTests: XCTestCase {

    private final class StubRecognizer: AppAgentVoiceRecognitionProviding {
        var preferredLocales: [Locale] = []
        var canPrewarmNow = false
        var isRecording = false

        func startRecording(locale: Locale?) -> AsyncStream<AppAgentVoiceRecognitionEvent> {
            AsyncStream { continuation in
                continuation.finish()
            }
        }

        func requestStopRecording(reason: AppAgentVoiceRecognitionEndReason) {
        }

        func requestFinishRecording(trailingCapture: TimeInterval, finalizationTimeout: TimeInterval) {
        }
    }

    func testSelectionFallsBackToSystemWhenEngineMissingOrUnconfigured() throws {
        let suiteName = "AppAgentVoiceRecognitionCentralTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // 上次选了第三方引擎，但这次打包没打进来：按系统识别处理。
        defaults.set("custom-engine", forKey: AppAgentVoiceRecognitionCentral.selectionKey)
        let central = AppAgentVoiceRecognitionCentral(defaults: defaults)
        XCTAssertEqual(central.selectedEngineID, AppAgentVoiceRecognitionCentral.systemEngineID)

        var configured = false
        let stub = StubRecognizer()
        central.register(AppAgentVoiceRecognitionEngine(
            id: "custom-engine",
            displayName: "第三方引擎",
            summary: "",
            recognizer: stub,
            isConfigured: {
                configured
            }
        ))
        XCTAssertEqual(central.selectedEngineID, "custom-engine")
        // 选中但没配凭据：实际仍用系统识别。
        XCTAssertEqual(central.activeEngine.id, AppAgentVoiceRecognitionCentral.systemEngineID)

        configured = true
        XCTAssertTrue(central.activeRecognizer === stub)
    }
}
#endif
