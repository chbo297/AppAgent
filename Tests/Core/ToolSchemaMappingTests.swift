import XCTest
@testable import AppAgent

final class ToolSchemaMappingTests: XCTestCase {
    func testEveryProtocolPreservesNestedToolSchema() throws {
        let tool = SchemaTool()
        let segments: [ContentOrCacheControl<any ToolProtocol>] = [.content(tool), .cacheControl]
        let anthropic = try XCTUnwrap(AnthropicMapper.toAnthropicTools(segments).first)
        let chat = try XCTUnwrap(OpenAIChatCompletionsMapper.toTools(segments).first?["function"] as? [String: Any])
        let responses = try XCTUnwrap(OpenAIResponsesMapper.toTools(segments).first)
        let expected: [String: Any] = [
            "type": "object", "required": ["nested"],
            "properties": [
                "nested": ["type": "object", "description": "nested", "required": ["items"], "properties": [
                    "items": ["type": "array", "maxItems": 2, "items": ["type": "string", "enum": ["a", "b"], "default": "a"]],
                    "count": ["type": "integer", "minimum": 0, "maximum": 9, "default": 1],
                    "score": ["type": "number", "minimum": 0.5, "maximum": 2.5, "default": NSNull()],
                    "flag": ["type": "boolean", "default": true]
                ]]
            ]
        ]
        for schema in [anthropic["input_schema"], chat["parameters"], responses["parameters"]] {
            XCTAssertEqual(try XCTUnwrap(schema as? NSDictionary), expected as NSDictionary)
        }
        XCTAssertNotNil(anthropic["cache_control"], "Protocol-specific cache metadata must remain intact")
    }
}

private struct SchemaTool: ToolProtocol {
    let name = "schema_test"
    let description = "Nested input"
    let parameters = Tool.Schema(properties: [
        "nested": .object(description: "nested", properties: [
            "items": .array(items: .string(enumValues: ["a", "b"], defaultValue: .string("a")), maxItems: 2),
            "count": .integer(minimum: 0, maximum: 9, defaultValue: .number(1)),
            "score": .number(minimum: 0.5, maximum: 2.5, defaultValue: .null),
            "flag": .boolean(defaultValue: .bool(true))
        ], required: ["items"])
    ], required: ["nested"])

    func execute(arguments: [String: JSONValue], session: AISession) async throws -> Tool.Output { .text("") }
}
