import XCTest
@testable import AppAgent

final class AppAgentCoreTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueCodableRoundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("test"),
            "count": .number(42),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .null
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testJSONValueAccessors() {
        let value: JSONValue = .object([
            "name": .string("hello"),
            "count": .number(5)
        ])

        XCTAssertEqual(value["name"]?.stringValue, "hello")
        XCTAssertEqual(value["count"]?.numberValue, 5)
        XCTAssertNil(value["missing"])
    }

    // MARK: - Tool Types

    func testToolSchemaCreation() {
        let schema = Tool.Schema(
            properties: [
                "query": .string(description: "Search query")
            ],
            required: ["query"]
        )

        XCTAssertEqual(schema.properties.count, 1)
        XCTAssertEqual(schema.required, ["query"])
        if case .string(let desc, _, _) = schema.properties["query"] {
            XCTAssertEqual(desc, "Search query")
        } else {
            XCTFail("Expected .string schema")
        }
    }

    func testToolOutputStringValue() {
        XCTAssertEqual(Tool.Output.text("hello").stringValue, "hello")
        XCTAssertEqual(Tool.Output.error("bad").stringValue, "Error: bad")
    }

    // MARK: - AIAgentMessage

    func testMessageConvenienceInitializers() {
        let userMsg = AIAgentMessage.user("Hello")
        XCTAssertEqual(userMsg.role, .user)
        XCTAssertEqual(userMsg.text, "Hello")

        let assistantMsg = AIAgentMessage.assistant("Hi there")
        XCTAssertEqual(assistantMsg.role, .assistant)
        XCTAssertEqual(assistantMsg.text, "Hi there")
    }

    func testAgentMessageCodableRoundTrip() throws {
        // Text-only message
        let textMsg = AIAgentMessage.user("Hello world")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(textMsg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIAgentMessage.self, from: data)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.text, "Hello world")
    }

    func testAgentMessageWithToolCallsCodable() throws {
        let toolCall = AIAgentMessage.ToolCall(
            id: "call-1",
            name: "web_search",
            arguments: ["query": .string("Swift concurrency")]
        )
        let msg = AIAgentMessage(role: .assistant, content: [
            .text("Let me search for that."),
            .toolUse(toolCall)
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIAgentMessage.self, from: data)

        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.text, "Let me search for that.")
        XCTAssertEqual(decoded.toolCalls.count, 1)
        XCTAssertEqual(decoded.toolCalls.first?.name, "web_search")
    }

    func testAgentMessageWithToolResultCodable() throws {
        let result = AIAgentMessage.ToolCallResult(toolCallId: "call-1", content: "Found 10 results")
        let msg = AIAgentMessage(role: .user, content: [.toolResult(result)])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AIAgentMessage.self, from: data)

        XCTAssertEqual(decoded.content.count, 1)
        if case .toolResult(let r) = decoded.content.first {
            XCTAssertEqual(r.toolCallId, "call-1")
            XCTAssertEqual(r.content, "Found 10 results")
        } else {
            XCTFail("Expected toolResult content")
        }
    }

    // MARK: - Provider Configuration

    func testModelSpecDefaults() {
        let model = ModelSpec(id: "test-model")
        XCTAssertEqual(model.id, "test-model")
        XCTAssertFalse(model.reasoning)
        XCTAssertEqual(model.inputModalities, ["text"])
        XCTAssertEqual(model.contextWindow, 200_000)
        XCTAssertEqual(model.maxTokens, 64_000)
    }

    func testModelSpecCodable() throws {
        let model = ModelSpec(
            id: "Claude Opus 4.6",
            reasoning: false,
            inputModalities: ["text", "image"],
            contextWindow: 200_000,
            maxTokens: 64_000
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ModelSpec.self, from: data)
        XCTAssertEqual(decoded.id, model.id)
        XCTAssertEqual(decoded.reasoning, model.reasoning)
        XCTAssertEqual(decoded.inputModalities, model.inputModalities)
        XCTAssertEqual(decoded.contextWindow, model.contextWindow)
        XCTAssertEqual(decoded.maxTokens, model.maxTokens)
    }

    func testModelSpecMinimalJSON() throws {
        // Minimal JSON with only "id" — all other fields should use defaults
        let json = #"{"id":"fast-model"}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelSpec.self, from: data)
        XCTAssertEqual(decoded.id, "fast-model")
        XCTAssertFalse(decoded.reasoning)
        XCTAssertEqual(decoded.inputModalities, ["text"])
        XCTAssertEqual(decoded.contextWindow, 200_000)
        XCTAssertEqual(decoded.maxTokens, 64_000)
    }

    func testProviderConfigurationDefaults() {
        let model = ModelSpec(id: "test-model")
        let provider = AnthropicProvider(
            baseURL: "https://api.example.com",
            apiKey: "test-key",
            models: [model]
        )

        XCTAssertEqual(provider.apiKey, "test-key")
        XCTAssertEqual(provider.baseURL, "https://api.example.com")
        XCTAssertEqual(provider.apiProtocol, .anthropicMessages)
        XCTAssertEqual(provider.models.count, 1)
        XCTAssertEqual(provider.models.first?.id, "test-model")
        XCTAssertTrue(provider.customHeaders.isEmpty)
    }

    func testProviderMultipleModels() {
        let models = [
            ModelSpec(id: "fast-model", maxTokens: 4096),
            ModelSpec(id: "big-model", maxTokens: 64_000),
        ]
        let provider = AnthropicProvider(
            baseURL: "https://api.example.com",
            apiKey: "key",
            models: models
        )

        XCTAssertEqual(provider.models.count, 2)
        XCTAssertEqual(provider.models[0].id, "fast-model")
        XCTAssertEqual(provider.models[0].maxTokens, 4096)
        XCTAssertEqual(provider.models[1].id, "big-model")
        XCTAssertEqual(provider.models[1].maxTokens, 64_000)
    }

    func testAPIProtocolRawValues() {
        XCTAssertEqual(APIProtocol.anthropicMessages.rawValue, "anthropic-messages")
        XCTAssertEqual(APIProtocol.openaiCompletions.rawValue, "openai-completions")
        XCTAssertEqual(APIProtocol.openaiResponses.rawValue, "openai-responses")
        XCTAssertEqual(APIProtocol.googleGenerativeAI.rawValue, "google-generative-ai")
        XCTAssertEqual(APIProtocol.bedrockConverseStream.rawValue, "bedrock-converse-stream")
        XCTAssertEqual(APIProtocol.ollama.rawValue, "ollama")
    }

    // MARK: - SSE Parser

    func testSSEParserBasic() {
        var parser = SSEParser()

        let result1 = parser.processLine("event: content_block_delta")
        XCTAssertNil(result1)

        let result2 = parser.processLine("data: {\"type\":\"delta\"}")
        XCTAssertNil(result2)

        let result3 = parser.processLine("")
        XCTAssertNotNil(result3)
        XCTAssertEqual(result3?.event, "content_block_delta")
        XCTAssertEqual(result3?.data, "{\"type\":\"delta\"}")
    }

    func testSSEParserFlush() {
        var parser = SSEParser()
        _ = parser.processLine("event: message_stop")
        _ = parser.processLine("data: {}")

        let flushed = parser.flush()
        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed?.event, "message_stop")
    }

    func testSSEParserDataOnlyEvent() {
        var parser = SSEParser()
        _ = parser.processLine("data: {\"choices\":[]}")

        let parsed = parser.processLine("")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.event, "")
        XCTAssertEqual(parsed?.data, "{\"choices\":[]}")
    }

    func testOpenAIChatCompletionsParserTextDelta() {
        var activeToolCalls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
        let event = SSEEvent(
            event: "",
            data: #"{"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#
        )

        let events = OpenAIChatCompletionsMapper.parseSSEEvent(
            event,
            activeToolCalls: &activeToolCalls
        )

        XCTAssertEqual(events.count, 1)
        if case .textDelta(let text) = events[0] {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected text delta")
        }
    }

    func testOpenAIChatCompletionsParserToolCall() {
        var activeToolCalls: [Int: OpenAIChatCompletionsMapper.ActiveToolCall] = [:]
        let event = SSEEvent(
            event: "",
            data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"file_search","arguments":"{\"query\":\"Swift\"}"}}]},"finish_reason":"tool_calls"}]}"#
        )

        let events = OpenAIChatCompletionsMapper.parseSSEEvent(
            event,
            activeToolCalls: &activeToolCalls
        )

        XCTAssertEqual(events.count, 2)
        if case .toolCall(let call) = events[0] {
            XCTAssertEqual(call.id, "call_1")
            XCTAssertEqual(call.name, "file_search")
            XCTAssertEqual(call.arguments["query"]?.stringValue, "Swift")
        } else {
            XCTFail("Expected tool call")
        }
        if case .done(let stopReason) = events[1] {
            XCTAssertEqual(stopReason, .toolUse)
        } else {
            XCTFail("Expected done event")
        }
    }

    // MARK: - AISession Storage

    func testInMemorySessionStorage() async throws {
        let storage = InMemorySessionStorage()

        let snapshot = SessionSnapshot(
            id: "test-1",
            title: "Test AISession",
            createdAt: Date(),
            updatedAt: Date(),
            messages: [AIAgentMessage.user("Hello")]
        )

        try await storage.save(session: snapshot)
        let loaded = try await storage.load(id: "test-1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, "Test AISession")
        XCTAssertEqual(loaded?.messages.count, 1)
        XCTAssertEqual(loaded?.messages.first?.text, "Hello")

        let all = try await storage.loadAll()
        XCTAssertEqual(all.count, 1)

        try await storage.delete(id: "test-1")
        let deleted = try await storage.load(id: "test-1")
        XCTAssertNil(deleted)
    }

    // MARK: - Errors

    func testAgentErrorDescriptions() {
        XCTAssertNotNil(ModelError.invalidURL.errorDescription)
        XCTAssertNotNil(AIAgentError.maxIterationsReached.errorDescription)
        XCTAssertNotNil(AIAgentError.cancelled.errorDescription)
        XCTAssertTrue(ModelError.httpError(statusCode: 429, body: "rate limited")
            .errorDescription?.contains("429") ?? false)
    }

    // MARK: - AIAgent

    func testAgentCreation() async {
        let central = AIAgentCentral()
        let config = AIAgentProfile(identity: "Test AIAgent", additionalPromptBuilders: [PromptBuilder("Be helpful")])
        let agent = await central.create(
            name: "test",
            profile: config,
            sessionStorage: InMemorySessionStorage()
        )

        XCTAssertEqual(agent.id, "test")
        XCTAssertEqual(agent.profile.identity, "Test AIAgent")
        XCTAssertNil(agent.modelPolicy)
    }

    func testAgentCreateAndFindSession() async {
        let central = AIAgentCentral()
        let config = AIAgentProfile(identity: "Test AIAgent")
        let agent = await central.create(
            name: "test",
            profile: config,
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Test Chat")
        XCTAssertEqual(session.title, "Test Chat")
        XCTAssertNotNil(agent.session(id: session.id))
        XCTAssertEqual(agent.allSessions.count, 1)
    }

    func testAgentDeleteSession() async throws {
        let central = AIAgentCentral()
        let config = AIAgentProfile(identity: "Test AIAgent")
        let agent = await central.create(
            name: "test",
            profile: config,
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "To Delete")
        XCTAssertEqual(agent.allSessions.count, 1)

        try await agent.deleteSession(session.id)
        XCTAssertEqual(agent.allSessions.count, 0)
        XCTAssertNil(agent.session(id: session.id))
    }

    func testSessionSaveAndRestore() async throws {
        let storage = InMemorySessionStorage()
        let config = AIAgentProfile(identity: "Test AIAgent")
        let central = AIAgentCentral()

        // Create agent and session, add messages
        let agent1 = await central.create(name: "test1", profile: config, sessionStorage: storage)
        let session = await agent1.createSession(title: "Persistent Chat")
        session.addUserMessage("Hello")
        try await agent1.sessionManager.saveSession(session)

        // Create new agent and restore
        let agent2 = await central.create(name: "test2", profile: config, sessionStorage: storage)
        try await agent2.restoreAll()

        XCTAssertEqual(agent2.allSessions.count, 1)
        let restored = agent2.allSessions.first
        XCTAssertEqual(restored?.title, "Persistent Chat")
        XCTAssertEqual(restored?.messages.count, 1)
        XCTAssertEqual(restored?.messages.first?.text, "Hello")
    }

    // MARK: - ModelProviderCentral

    func testProviderCentralRegisterAndResolve() async {
        let central = ModelProviderCentral()
        let provider = AnthropicProvider(
            baseURL: "https://api.example.com",
            apiKey: "key",
            models: [
                ModelSpec(id: "model-a"),
                ModelSpec(id: "model-b", maxTokens: 4096)
            ]
        )
        await central.register(name: "test", provider: provider)

        let names = await central.registeredNames
        XCTAssertEqual(names, ["test"])

        // Resolve existing model
        let resolved = await central.resolve(modelReference: "test/model-b")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.modelId, "model-b")

        // Resolve non-existent model
        let missing = await central.resolve(modelReference: "test/model-z")
        XCTAssertNil(missing)

        // Resolve non-existent provider
        let missingProvider = await central.resolve(modelReference: "nope/model-a")
        XCTAssertNil(missingProvider)
    }

    func testProviderCentralUnregister() async {
        let central = ModelProviderCentral()
        await central.register(name: "temp", provider: AnthropicProvider(
            baseURL: "https://api.example.com",
            apiKey: "key",
            models: [ModelSpec(id: "model-a")]
        ))
        let namesAfterRegister = await central.registeredNames
        XCTAssertEqual(namesAfterRegister.count, 1)

        await central.unregister(name: "temp")
        let namesAfterUnregister = await central.registeredNames
        XCTAssertEqual(namesAfterUnregister.count, 0)
    }

    func testProviderCentralResolveDefault() async {
        let central = ModelProviderCentral()
        await central.register(name: "acme", provider: AnthropicProvider(
            baseURL: "https://api.example.com",
            apiKey: "key",
            models: [ModelSpec(id: "default-model")]
        ))

        let resolved = await central.resolveDefault()
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.modelId, "default-model")
    }

    func testProviderCentralInvalidFormat() async {
        let central = ModelProviderCentral()
        // No slash separator
        let result = await central.resolve(modelReference: "no-slash-here")
        XCTAssertNil(result)
    }

    // MARK: - ModelProviderCentral Resolution

    func testModelResolve() async {
        let central = ModelProviderCentral()
        await central.register(name: "acme", provider: AnthropicProvider(
            baseURL: "https://api.example.com",
            apiKey: "key",
            models: [
                ModelSpec(id: "fast"),
                ModelSpec(id: "smart")
            ]
        ))

        let resolved = await central.resolve(modelReference: "acme/smart")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.modelId, "smart")
    }

    func testModelResolveNotFound() async {
        let central = ModelProviderCentral()
        let resolved = await central.resolve(modelReference: "nope/nope")
        XCTAssertNil(resolved)
    }

    // MARK: - ModelPolicy

    func testModelPolicyInit() {
        let policy = ModelPolicy(
            primary: "provider1/model-a",
            fallbacks: ["provider1/model-b", "provider2/model-c"]
        )
        XCTAssertEqual(policy.primary, "provider1/model-a")
        XCTAssertEqual(policy.fallbacks.count, 2)
        XCTAssertEqual(policy.fallbacks[0], "provider1/model-b")
        XCTAssertEqual(policy.fallbacks[1], "provider2/model-c")
    }

    func testModelPolicyConvenienceInit() {
        let policy = ModelPolicy("provider/model")
        XCTAssertEqual(policy.primary, "provider/model")
        XCTAssertTrue(policy.fallbacks.isEmpty)
    }

    func testModelPolicyCodable() throws {
        let policy = ModelPolicy(primary: "p/model-a", fallbacks: ["p/model-b"])
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ModelPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }

    // MARK: - ToolCentral

    func testAgentToolCentralRegister() async {
        let central = ToolCentral()
        let tool = TodoTool()
        await central.register(tool)
        let tools = await central.resolveTools()
        XCTAssertTrue(tools.keys.contains("todo"))
    }

    // MARK: - AIAgent + Provider Resolution

    func testAgentResolveProviderFromCentral() async {
        // Create a local provider central for test isolation
        let providerCentral = ModelProviderCentral()
        await providerCentral.register(
            name: "testProvider",
            provider: AnthropicProvider(
                baseURL: "https://api.example.com",
                apiKey: "key",
                models: [ModelSpec(id: "test-model")]
            )
        )

        let agentCentral = AIAgentCentral()
        let agent = await agentCentral.create(
            name: "test",
            profile: AIAgentProfile(identity: "Test"),
            providerCentral: providerCentral,
            modelPolicy: ModelPolicy(primary: "testProvider/test-model"),
            sessionStorage: InMemorySessionStorage()
        )

        let resolved = await agent.resolveProvider()
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.modelId, "test-model")
    }

    func testAgentResolveProviderFallsBackToDefault() async {
        // Create a local provider central for test isolation
        let providerCentral = ModelProviderCentral()
        await providerCentral.register(
            name: "fallbackProvider",
            provider: AnthropicProvider(
                baseURL: "https://api.example.com",
                apiKey: "key",
                models: [ModelSpec(id: "fallback-model")]
            )
        )

        // AIAgent without defaultModel — should fall back to central's default
        let agentCentral = AIAgentCentral()
        let agent = await agentCentral.create(
            name: "test",
            profile: AIAgentProfile(identity: "Test"),
            providerCentral: providerCentral,
            sessionStorage: InMemorySessionStorage()
        )

        let resolved = await agent.resolveProvider()
        XCTAssertNotNil(resolved)
    }

    // MARK: - ConcurrencyLimiter

    func testConcurrencyLimiterBasic() async {
        let limiter = ConcurrencyLimiter(limit: 2)

        // First two should pass immediately
        await limiter.wait()
        await limiter.wait()

        // Signal to free a slot
        await limiter.signal()
        await limiter.signal()
    }

    // MARK: - Memory

    func testInMemoryMemoryStorage() async throws {
        let storage = InMemoryMemoryStorage()

        let entry = MemoryEntry(content: "User likes Swift", tags: ["preference"])
        try await storage.append(entry)

        let all = try await storage.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.content, "User likes Swift")

        try await storage.remove(id: entry.id)
        let afterRemove = try await storage.loadAll()
        XCTAssertTrue(afterRemove.isEmpty)
    }

    func testMemoryStoreAddAndSearch() async throws {
        let memConfig = MemoryConfig()
        let storage = InMemoryMemoryStorage()
        let store = MemoryStore(config: memConfig, storage: storage)

        try await store.addLongTerm(MemoryEntry(content: "User prefers dark mode", tags: ["preference", "ui"]))
        try await store.addLongTerm(MemoryEntry(content: "User's name is Alice", tags: ["personal"]))

        let results = await store.searchLongTerm(query: "dark mode")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.content, "User prefers dark mode")

        let all = await store.allLongTerm()
        XCTAssertEqual(all.count, 2)
    }

    func testMemoryStoreHotMemory() async {
        let memConfig = MemoryConfig()
        let store = MemoryStore(config: memConfig, storage: InMemoryMemoryStorage())

        await store.setHot(key: "location", value: "Tokyo")
        let value = await store.getHot(key: "location")
        XCTAssertEqual(value, "Tokyo")

        await store.removeHot(key: "location")
        let removed = await store.getHot(key: "location")
        XCTAssertNil(removed)
    }

    func testMemoryStoreAssemblePrompts() async throws {
        let memConfig = MemoryConfig()
        let store = MemoryStore(config: memConfig, storage: InMemoryMemoryStorage())

        // Add hot and long-term memory
        await store.setHot(key: "location", value: "Tokyo")
        try await store.addLongTerm(MemoryEntry(content: "User likes coffee", tags: ["preference"]))

        let prompts = await store.assembleMemoryPrompts()
        XCTAssertEqual(prompts.count, 2) // hot memory + long-term memory

        let texts = prompts.map { $0.text }
        XCTAssertTrue(texts.contains(where: { $0.contains("Tokyo") }))
        XCTAssertTrue(texts.contains(where: { $0.contains("coffee") }))
    }

    // MARK: - SessionUIState

    func testSessionUIState() {
        let state = SessionUIState()
        var changedKeys: [String] = []
        let expectation = XCTestExpectation(description: "onChange called")
        expectation.expectedFulfillmentCount = 4 // setStreaming(true), appendx2, setStreaming(false)
        state.onChange = { key in
            changedKeys.append(key)
            expectation.fulfill()
        }

        state.setStreaming(true)
        XCTAssertTrue(state.isStreaming)

        state.appendStreamingText("Hello ")
        state.appendStreamingText("world")
        XCTAssertEqual(state.streamingText, "Hello world")

        state.setStreaming(false)
        state.resetStreamingText()
        XCTAssertFalse(state.isStreaming)
        XCTAssertEqual(state.streamingText, "")

        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(changedKeys.contains("isStreaming"))
        XCTAssertTrue(changedKeys.contains("streamingText"))
    }

    func testSessionUIStateCustomState() {
        let state = SessionUIState()
        state.set("progress", value: 0.5)
        let progress: Double? = state.get("progress")
        XCTAssertEqual(progress, 0.5)

        state.remove("progress")
        let removed: Double? = state.get("progress")
        XCTAssertNil(removed)
    }

    // MARK: - PromptBuilder

    func testPromptBuilderStaticText() {
        let builder = PromptBuilder("Be helpful")
        XCTAssertNil(builder.name)
        if case .text(let text) = builder.content {
            XCTAssertEqual(text, "Be helpful")
        } else {
            XCTFail("Expected .text content")
        }
    }

    func testPromptBuilderNamedText() {
        let builder = PromptBuilder("rules", prompt: "Be helpful")
        XCTAssertEqual(builder.name, "rules")
        if case .text(let text) = builder.content {
            XCTAssertEqual(text, "Be helpful")
        } else {
            XCTFail("Expected .text content")
        }
    }

    func testPromptBuilderClosure() async {
        let builder = PromptBuilder("dynamic") { _ in
            return "Today is 2026-04-12"
        }
        XCTAssertEqual(builder.name, "dynamic")
        if case .closure(let resolver) = builder.content {
            let session = AISession(id: "test-prompt-builder", title: "Test")
            let result = await resolver(session)
            XCTAssertEqual(result, "Today is 2026-04-12")
        } else {
            XCTFail("Expected .closure content")
        }
    }

    // MARK: - AIAgentProfile

    func testAgentProfileDefaults() {
        let config = AIAgentProfile(identity: "Test")
        XCTAssertEqual(config.identity, "Test")
        XCTAssertEqual(config.promptBuilders.count, 1) // identity as promptBuilders[0]
        XCTAssertTrue(config.messageContextProviders.isEmpty)
        XCTAssertEqual(config.maxIterations, 10)
        XCTAssertTrue(config.autoPersist)
        XCTAssertTrue(config.memoryConfig.longTermEnabled)
    }

    // MARK: - MessageContextFormatter

    func testMessageContextFormatterWithEntries() {
        let entries = [
            MessageContextEntry(label: "Current time", value: "2026-04-11T14:30:00.000Z"),
            MessageContextEntry(label: "User location", value: "Tokyo, Japan")
        ]
        let result = MessageContextFormatter.format(entries: entries, userText: "What's the weather?")

        let expected = """
        --- CONTEXT ENTRY BEGIN ---
        Current time: 2026-04-11T14:30:00.000Z
        --- CONTEXT ENTRY END ---

        --- CONTEXT ENTRY BEGIN ---
        User location: Tokyo, Japan
        --- CONTEXT ENTRY END ---

        --- USER MESSAGE BEGIN ---
        What's the weather?
        --- USER MESSAGE END ---
        """
        XCTAssertEqual(result, expected)
    }

    func testMessageContextFormatterNoEntries() {
        let result = MessageContextFormatter.format(entries: [], userText: "Hello")
        XCTAssertEqual(result, "Hello", "Should return raw text when no context entries")
    }

    func testMessageContextFormatterSingleEntry() {
        let entries = [MessageContextEntry(label: "Current time", value: "2026-04-11")]
        let result = MessageContextFormatter.format(entries: entries, userText: "Hi")

        XCTAssertTrue(result.hasPrefix("--- CONTEXT ENTRY BEGIN ---"))
        XCTAssertTrue(result.contains("Current time: 2026-04-11"))
        XCTAssertTrue(result.contains("--- USER MESSAGE BEGIN ---\nHi\n--- USER MESSAGE END ---"))
    }

    // MARK: - BuiltInMessageContext

    func testBuiltInMessageContextReturnsTime() async {
        let builtIn = BuiltInMessageContext()
        let entries = await builtIn.messageContext()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.label, "Current time")

        let value = entries.first?.value ?? ""
        // Should match format "yyyy-MM-dd HH:mm:ss (TZ)"
        XCTAssertTrue(value.contains("("), "Expected timezone in parentheses, got: \(value)")
        XCTAssertTrue(value.contains(")"), "Expected timezone in parentheses, got: \(value)")
        // Verify 24-hour date-time pattern (e.g. "2026-04-11 23:16:36")
        let datePartRange = value.startIndex..<(value.firstIndex(of: "(") ?? value.endIndex)
        let datePart = value[datePartRange].trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(datePart.count, 19, "Expected 'yyyy-MM-dd HH:mm:ss' (19 chars), got: \(datePart)")
    }

    // MARK: - ClosureMessageContextProvider

    func testClosureMessageContextProvider() async {
        let provider = ClosureMessageContextProvider {
            [MessageContextEntry(label: "App version", value: "2.1.0")]
        }
        let entries = await provider.messageContext()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.label, "App version")
        XCTAssertEqual(entries.first?.value, "2.1.0")
    }

    func testClosureMessageContextProviderEmpty() async {
        let provider = ClosureMessageContextProvider { [] }
        let entries = await provider.messageContext()
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - AIAgentCentral

    func testAgentCentralCreateAndRetrieve() async {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "alpha",
            profile: AIAgentProfile(identity: "A"),
            sessionStorage: InMemorySessionStorage()
        )

        let retrieved = await central.agent(named: "alpha")
        XCTAssertTrue(retrieved === agent)
        XCTAssertEqual(agent.id, "alpha")

        let names = await central.registeredNames
        XCTAssertEqual(names, ["alpha"])
    }

    func testAgentCentralRemove() async {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "beta",
            profile: AIAgentProfile(identity: "B"),
            sessionStorage: InMemorySessionStorage()
        )

        let removed = await central.remove(name: "beta")
        XCTAssertTrue(removed === agent)

        let after = await central.agent(named: "beta")
        XCTAssertNil(after)
    }

    func testAgentCentralMainLazyCreation() async {
        let central = AIAgentCentral()
        let main1 = await central.main
        XCTAssertNotNil(main1)
        XCTAssertEqual(main1.id, AIAgentCentral.mainName)

        let names = await central.registeredNames
        XCTAssertTrue(names.contains(AIAgentCentral.mainName))

        // Access again — same instance
        let main2 = await central.main
        XCTAssertTrue(main1 === main2)
    }

    func testAgentCentralMainExplicitCreation() async {
        let central = AIAgentCentral()
        let custom = await central.create(
            name: AIAgentCentral.mainName,
            profile: AIAgentProfile(identity: "Custom Main"),
            sessionStorage: InMemorySessionStorage()
        )

        let main = await central.main
        XCTAssertTrue(main === custom)
    }

    func testAgentCentralOverwrite() async {
        let central = AIAgentCentral()
        let _ = await central.create(
            name: "slot",
            profile: AIAgentProfile(identity: "First"),
            sessionStorage: InMemorySessionStorage()
        )
        let second = await central.create(
            name: "slot",
            profile: AIAgentProfile(identity: "Second"),
            sessionStorage: InMemorySessionStorage()
        )

        let retrieved = await central.agent(named: "slot")
        XCTAssertTrue(retrieved === second)
    }

    func testAgentCentralAllAgents() async {
        let central = AIAgentCentral()
        let a = await central.create(
            name: "alpha",
            profile: AIAgentProfile(identity: "A"),
            sessionStorage: InMemorySessionStorage()
        )
        let b = await central.create(
            name: "beta",
            profile: AIAgentProfile(identity: "B"),
            sessionStorage: InMemorySessionStorage()
        )

        let all = await central.allAgents
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].name, "alpha")
        XCTAssertEqual(all[1].name, "beta")
        XCTAssertTrue(all[0].agent === a)
        XCTAssertTrue(all[1].agent === b)
    }

    func testAgentCentralIsolation() async {
        let central1 = AIAgentCentral()
        let central2 = AIAgentCentral()
        let _ = await central1.create(
            name: "test",
            profile: AIAgentProfile(identity: "Isolated"),
            sessionStorage: InMemorySessionStorage()
        )

        let fromCentral2 = await central2.agent(named: "test")
        XCTAssertNil(fromCentral2)
    }

    // MARK: - Session ID Generation (via AISessionManager)

    func testSessionIDContainsAgentId() async {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "mybot",
            profile: AIAgentProfile(identity: "Test"),
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Chat")
        XCTAssertTrue(session.id.hasPrefix("mybot_"), "Session ID should start with agent id, got: \(session.id)")
    }

    // MARK: - LLMExecutor

    func testSessionHasExecutor() async {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "test",
            profile: AIAgentProfile(identity: "Test"),
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Test Chat")
        XCTAssertNotNil(session.executor, "Session should have a mounted LLMExecutor")
        XCTAssertFalse(session.executor.isRunning, "Executor should not be running initially")
        XCTAssertFalse(session.isRunning, "Session.isRunning should delegate to executor")
    }

    func testStandaloneSessionHasExecutor() {
        // Sessions created directly (like DelegateTaskTool sub-sessions) also get an executor
        let session = AISession(id: "standalone_test", title: "Standalone")
        XCTAssertNotNil(session.executor, "Standalone session should have executor")
        XCTAssertFalse(session.isRunning)
    }

    func testSessionCancelDelegatesToExecutor() async {
        let central = AIAgentCentral()
        let agent = await central.create(
            name: "test",
            profile: AIAgentProfile(identity: "Test"),
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Test")
        // Cancel should not crash even when nothing is running
        session.cancel()
        XCTAssertFalse(session.isRunning)
    }

    func testExecutorTracksAndCancelsActiveRun() async throws {
        let provider = BlockingModelProvider()
        let providerCentral = ModelProviderCentral()
        await providerCentral.register(name: "mock", provider: provider)

        let central = AIAgentCentral()
        let agent = await central.create(
            name: "test",
            profile: AIAgentProfile(
                identity: "Test",
                autoPersist: false,
                registerBuiltInTools: false
            ),
            providerCentral: providerCentral,
            modelPolicy: ModelPolicy(primary: "mock/blocking-model"),
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Running")
        let stream = session.sendMessage("Hello")
        let drain = Task {
            for await _ in stream {}
        }

        await provider.waitUntilStarted()
        XCTAssertTrue(session.isRunning)

        session.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.uiState.isStreaming)
        drain.cancel()
    }

    func testExecutorSetsUIErrorWhenProviderFails() async {
        let provider = FailingModelProvider(error: ModelError.invalidResponse)
        let providerCentral = ModelProviderCentral()
        await providerCentral.register(name: "mock", provider: provider)

        let central = AIAgentCentral()
        let agent = await central.create(
            name: "test",
            profile: AIAgentProfile(
                identity: "Test",
                autoPersist: false,
                registerBuiltInTools: false
            ),
            providerCentral: providerCentral,
            modelPolicy: ModelPolicy(primary: "mock/failing-model"),
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Failing")
        let stream = session.sendMessage("Hello")
        var sawError = false
        for await event in stream {
            if case .error = event {
                sawError = true
            }
        }

        XCTAssertTrue(sawError)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.uiState.isStreaming)
        XCTAssertNotNil(session.uiState.lastError)
    }

    func testToolLoopWarningCompletesStartedToolCall() async {
        let provider = RepeatingToolCallModelProvider()
        let providerCentral = ModelProviderCentral()
        await providerCentral.register(name: "mock", provider: provider)

        let central = AIAgentCentral()
        let agent = await central.create(
            name: "test",
            profile: AIAgentProfile(
                identity: "Test",
                maxIterations: 3,
                autoPersist: false,
                registerBuiltInTools: false
            ),
            providerCentral: providerCentral,
            modelPolicy: ModelPolicy(primary: "mock/repeating-model"),
            sessionStorage: InMemorySessionStorage()
        )

        let session = await agent.createSession(title: "Loop")
        let stream = session.sendMessage("Loop")
        var startedCount = 0
        var completedWarning = false
        for await event in stream {
            switch event {
            case .toolCallStarted:
                startedCount += 1
            case .toolCallCompleted(let toolCallId, _):
                completedWarning = toolCallId == "loop-call"
            default:
                break
            }
        }

        XCTAssertEqual(startedCount, 3)
        XCTAssertTrue(completedWarning)
    }
}

private final class BlockingModelProvider: ModelProvider, @unchecked Sendable {
    let name = "mock"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "blocking-model")]
    let requestTimeout: TimeInterval = 300

    private let started = ReadySignal()

    func waitUntilStarted() async {
        await started.wait()
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await started.signal()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private final class FailingModelProvider: ModelProvider, @unchecked Sendable {
    let name = "mock"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "failing-model")]
    let requestTimeout: TimeInterval = 300

    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

private final class RepeatingToolCallModelProvider: ModelProvider, @unchecked Sendable {
    let name = "mock"
    let baseURL = ""
    let apiKey = ""
    let apiProtocol: APIProtocol = .anthropicMessages
    let customHeaders: [String: String] = [:]
    let models = [ModelSpec(id: "repeating-model")]
    let requestTimeout: TimeInterval = 300

    func streamCompletion(
        messages: [AIAgentMessage],
        system: [ContentOrCacheControl<SystemPrompt>],
        tools: [ContentOrCacheControl<any ToolProtocol>],
        modelId: String
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let call = AIAgentMessage.ToolCall(
                id: "loop-call",
                name: "missing_tool",
                arguments: ["query": .string("same")]
            )
            continuation.yield(.toolCall(call))
            continuation.yield(.done(stopReason: .toolUse))
            continuation.finish()
        }
    }
}
