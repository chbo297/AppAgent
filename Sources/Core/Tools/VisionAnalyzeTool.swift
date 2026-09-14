//
//  VisionAnalyzeTool.swift
//  AppAgent
//

import Foundation

/// Tool for analyzing images using a pluggable vision provider.
///
/// The host app provides a `VisionAnalyzeProvider` to handle actual analysis.
/// This allows flexibility: use LLM multimodal, iOS Vision framework, or a remote API.
///
/// Reference: hermes-agent `vision_analyze` tool.
public struct VisionAnalyzeTool: ToolProtocol {
    public let name = "vision_analyze"
    public let description = """
        Analyze an image and answer a question about its content. \
        Provide a local file path or URL to the image, plus a specific question.
        """
    public let parameters = Tool.Schema(
        properties: [
            "image_path": .string(description: "Image file path or URL to analyze."),
            "question": .string(description: "Your specific question about the image.")
        ],
        required: ["image_path", "question"]
    )
    public let group: String = "media"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: (any VisionAnalyzeProvider)?

    public init(provider: (any VisionAnalyzeProvider)? = nil) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let imagePath = arguments["image_path"]?.stringValue, !imagePath.isEmpty else {
            return .error("Missing required parameter: image_path")
        }
        guard let question = arguments["question"]?.stringValue, !question.isEmpty else {
            return .error("Missing required parameter: question")
        }

        guard let provider else {
            return .error("No vision provider configured. The host app must provide a VisionAnalyzeProvider.")
        }

        let analysis = try await provider.analyze(imagePath: imagePath, question: question)
        return .json(.object([
            "analysis": .string(analysis),
            "image_path": .string(imagePath)
        ]))
    }
}

/// Protocol for vision analysis backends.
public protocol VisionAnalyzeProvider: Sendable {
    func analyze(imagePath: String, question: String) async throws -> String
}
