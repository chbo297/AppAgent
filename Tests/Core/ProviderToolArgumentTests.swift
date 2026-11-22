import XCTest
@testable import AppAgent

final class ProviderToolArgumentTests: XCTestCase {
    func testChatCompletionsRejectsMalformedArgumentsAtomically() throws {
        for raw in ["{", "[]", "null"] {
            var calls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [
                0: (id: "valid", name: "first", arguments: "{}"),
                1: (id: "broken", name: "second", arguments: raw)
            ]
            XCTAssertThrowsError(try OpenAIChatCompletionsMapper.parseSSEEvent(
                SSEEvent(event: "", data: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#),
                activeToolCalls: &calls
            ), "Invalid arguments must never become an empty-argument tool call: \(raw)")
            XCTAssertTrue(calls.isEmpty)
        }
    }

    /// 真机：网关把无参的 `screenshot` 转成 `"arguments":""` 且 `finish_reason=tool_calls`，
    /// 旧逻辑把它当坏 JSON，整轮终止。正常收尾的空参数等同 `{}`。
    func testChatCompletionsTreatsEmptyArgumentsAsNoArgumentCall() throws {
        var calls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [
            0: (id: "shot", name: "screenshot", arguments: "")
        ]
        let events = try OpenAIChatCompletionsMapper.parseSSEEvent(
            SSEEvent(event: "", data: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#),
            activeToolCalls: &calls
        )
        guard case .toolCall(let call)? = events.first else {
            return XCTFail("Missing no-argument call")
        }
        XCTAssertEqual(call.name, "screenshot")
        XCTAssertTrue(call.arguments.isEmpty)
    }

    /// 残缺工具调用在 mapper 层整体拒绝、没有工具执行过，重发同一请求即可；其他解码错误仍不重试。
    func testMalformedToolCallIsRetryable() {
        XCTAssertTrue(ErrorClassifier.classify(ModelError.malformedToolCall("broken")).retryable)
        XCTAssertFalse(ErrorClassifier.classify(ModelError.decodingError("broken")).retryable)
    }

    func testChatCompletionsDoesNotReleaseCallsAfterIncompleteFinish() throws {
        for payload in [
            "[DONE]",
            #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ] {
            var calls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [
                0: (id: "pending", name: "write", arguments: "{}")
            ]
            let events = try OpenAIChatCompletionsMapper.parseSSEEvent(
                SSEEvent(event: "", data: payload), activeToolCalls: &calls
            )
            XCTAssertFalse(events.contains { if case .toolCall = $0 { return true }; return false })
            XCTAssertTrue(calls.isEmpty, "Incomplete calls must not survive a terminal chunk")
        }
    }

    func testAnthropicRejectsMalformedArgumentsAndKeepsNoArgumentTools() throws {
        for raw in ["{", "[]", "null"] {
            var calls = [0: (id: "broken", name: "write", jsonAccumulator: raw)]
            // 参数不完整先挂起（可能是 max_tokens 截断），stop_reason 不是 max_tokens 才报错。
            XCTAssertTrue(try AnthropicMapper.parseSSEEvent(
                SSEEvent(event: "content_block_stop", data: #"{"index":0}"#),
                activeToolCalls: &calls
            ).isEmpty)
            XCTAssertThrowsError(try AnthropicMapper.parseSSEEvent(
                SSEEvent(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
                activeToolCalls: &calls
            ))
            XCTAssertTrue(calls.isEmpty)
        }
        for raw in ["", "{}"] {
            var calls = [0: (id: "valid", name: "read", jsonAccumulator: raw)]
            let events = try AnthropicMapper.parseSSEEvent(
                SSEEvent(event: "content_block_stop", data: #"{"index":0}"#),
                activeToolCalls: &calls
            )
            guard case .toolCall(let call)? = events.first else { return XCTFail("Missing no-argument call") }
            XCTAssertTrue(call.arguments.isEmpty)
        }
    }
}
