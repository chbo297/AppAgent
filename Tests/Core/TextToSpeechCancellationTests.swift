import XCTest
@testable import AppAgent

#if canImport(AVFoundation)
final class TextToSpeechCancellationTests: XCTestCase {
    func testAlreadyCancelledTaskDoesNotReportSpeechSuccess() async {
        let completed = expectation(description: "Cancelled speech terminates promptly")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await TextToSpeechTool().execute(arguments: ["text": .string("Cancelled")],
                                                        session: AISession(id: "cancelled-speech"))
                XCTFail("Cancelled speech must throw cancellation instead of reporting success")
            } catch is CancellationError {
                // Cancellation must not wait for a speech delegate callback.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        task.cancel()
    }

    func testCancellationBeforeAttachmentDoesNotStartSpeech() async {
        let completion = SpeechCompletionDelegate()
        completion.cancel()
        let started = Locked(wrappedValue: false)
        do {
            try await completion.wait(start: { started.wrappedValue = true }, stop: {})
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(started.wrappedValue)
    }

    func testCancellationWhileWaitingStopsPlaybackAndIgnoresLateCompletion() async {
        let completion = SpeechCompletionDelegate()
        let started = expectation(description: "Speech started")
        let stopped = expectation(description: "Playback stopped")
        let task = Task {
            try await completion.wait(start: { started.fulfill() }, stop: { stopped.fulfill() })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        completion.finish()
        completion.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation instead of late success")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [stopped], timeout: 1)
    }
}
#endif
