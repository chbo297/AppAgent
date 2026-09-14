//
//  WebSearchTool.swift
//  AppAgent
//

import Foundation

/// Tool for web search, backed by a pluggable provider.
///
/// The SDK does not bundle a search API. The host app provides a `WebSearchProvider`
/// implementation (e.g., wrapping a search API like Tavily, Exa, or a custom backend).
///
/// Reference: hermes-agent `web_search` tool.
public struct WebSearchTool: ToolProtocol {
    public let name = "web_search"
    public let description = """
        Search the web for information. Returns a list of results with titles, URLs, and snippets.
        """
    public let parameters = Tool.Schema(
        properties: [
            "query": .string(description: "Search query."),
            "limit": .integer(
                description: "Maximum number of results (default: 5).",
                maximum: 20,
                defaultValue: .number(5)
            )
        ],
        required: ["query"]
    )
    public let group: String = "web"
    public let safetyLevel: Tool.SafetyLevel = .safe

    private let provider: (any WebSearchProvider)?

    public init(provider: (any WebSearchProvider)? = nil) {
        self.provider = provider
    }

    public func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            return .error("Missing required parameter: query")
        }

        let limit = Int(arguments["limit"]?.numberValue ?? 5)

        guard let provider else {
            return .error("No web search provider configured. The host app must provide a WebSearchProvider.")
        }

        let results = try await provider.search(query: query, limit: limit)

        let items: [JSONValue] = results.map { result in
            .object([
                "title": .string(result.title),
                "url": .string(result.url),
                "snippet": .string(result.snippet)
            ])
        }

        return .json(.object([
            "results": .array(items),
            "count": .number(Double(items.count)),
            "query": .string(query)
        ]))
    }
}

/// A single web search result.
public struct WebSearchResult: Sendable {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Protocol for web search backends.
public protocol WebSearchProvider: Sendable {
    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}
