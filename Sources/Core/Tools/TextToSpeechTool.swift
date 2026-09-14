//
//  TextToSpeechTool.swift
//  AppAgent
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Tool for converting text to speech using iOS AVSpeechSynthesizer.
///
/// Reference: hermes-agent `text_to_speech` tool.
public struct TextToSpeechTool: ToolProtocol {
    public let name = "text_to_speech"
    public let description = """
        Convert text to speech audio. The text will be spoken aloud using the device's speech synthesizer.
        """
    public let parameters = Tool.Schema(
        properties: [
            "text": .string(description: "The text to speak. Keep under 4000 characters."),
            "language": .string(
                description: "BCP 47 language tag (e.g., 'en-US', 'zh-CN'). Default: device language.",
                defaultValue: .string("en-US")
            ),
            "rate": .number(
                description: "Speech rate (0.0 to 1.0, default: 0.5).",
                defaultValue: .number(0.5)
            )
        ],
        required: ["text"]
    )
    public let group: String = "media"
    public let safetyLevel: Tool.SafetyLevel = .safe

    public init() {}

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return .error("Missing required parameter: text")
        }

        if text.count > 4000 {
            return .error("Text exceeds maximum length of 4000 characters (\(text.count) provided).")
        }

        #if canImport(AVFoundation)
        let language = arguments["language"]?.stringValue ?? "en-US"
        let rate = Float(arguments["rate"]?.numberValue ?? 0.5)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = max(0, min(1, rate)) * AVSpeechUtteranceMaximumSpeechRate

        let synthesizer = AVSpeechSynthesizer()
        let speechDelegate = SpeechCompletionDelegate()
        synthesizer.delegate = speechDelegate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            speechDelegate.continuation = continuation
            synthesizer.speak(utterance)
        }

        return .json(.object([
            "success": .bool(true),
            "text_length": .number(Double(text.count)),
            "language": .string(language),
            "message": .string("Finished speaking text (\(text.count) chars)")
        ]))
        #else
        return .error("Text-to-speech is not available on this platform.")
        #endif
    }
}

#if canImport(AVFoundation)
/// Delegate that signals completion when speech finishes or is cancelled.
private final class SpeechCompletionDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }
}
#endif
