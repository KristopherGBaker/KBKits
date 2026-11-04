import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

/// The request body `OpenAIResponsesModel` sends: instructions, input items for a whole tool loop with its reasoning
/// sent back, flat tools, the reasoning and cache options, structured output, and the refusals. Offline.
@Suite struct OpenAIResponsesRequestTests {
    static let call = ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8))
    static let anthropicThinking = ReasoningBlock.thinking(text: "Claude's thought.", signature: "sig")

    /// A whole tool loop: a system prompt, a user turn with an image, the assistant's reasoning, text and call, its
    /// result, then a follow-up.
    static let loop = ModelRequest(
        messages: [
            Message(role: .system, text: "Be brief."),
            Message(role: .user, content: [
                .text("What is the weather here?"), .image(data: Data([1, 2, 3]), mimeType: "image/png")
            ]),
            Message(
                role: .assistant, content: [.text("Checking."), .toolCall(call)],
                reasoning: "Check the weather.", reasoningBlocks: [anthropicThinking, Fixtures.responsesReasoningBlock]
            ),
            Message(role: .tool, content: [
                .toolResult(
                    callID: "call_1",
                    ToolResult.success(toolName: "get_weather", content: Data(#"{"temp":"sunny"}"#.utf8))
                )
            ]),
            Message(role: .user, text: "Thanks")
        ],
        tools: [weatherTool],
        options: GenerationOptions(maxOutputTokens: 400)
    )

    private func body(_ transport: RecordingTransport) throws -> [String: Any] {
        let data = try #require(transport.requests.get().first?.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sent(
        _ request: ModelRequest,
        effort: OpenAIResponsesModel.ReasoningEffort? = nil,
        summary: OpenAIResponsesModel.ReasoningSummary? = nil,
        cacheKey: String? = nil
    ) async throws -> ([String: Any], RecordingTransport) {
        let (model, transport) = makeResponses(
            .replay(Fixtures.responsesText),
            reasoningEffort: effort, reasoningSummary: summary, promptCacheKey: cacheKey
        )
        _ = await collect(model, request)
        return (try body(transport), transport)
    }

    @Test func aToolLoopIsInstructionsAndInputItemsInOrder() async throws {
        let (sent, _) = try await sent(Self.loop)
        #expect(sent["model"] as? String == "gpt-6-astra")
        #expect(sent["stream"] as? Bool == true)
        #expect(sent["instructions"] as? String == "Be brief.")
        #expect(sent["max_output_tokens"] as? Int == 400)
        let input = try #require(sent["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [
            "message", "reasoning", "message", "function_call", "function_call_output", "message"
        ])
        #expect(input.map { $0["role"] as? String } == ["user", nil, "assistant", nil, nil, "user"])
        let parts = try #require(input[0]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["input_text", "input_image"])
        #expect(parts[1]["image_url"] as? String == "data:image/png;base64,AQID")
        #expect(input[2]["content"] as? String == "Checking.")
        #expect(input[3]["call_id"] as? String == "call_1")
        #expect(input[3]["name"] as? String == "get_weather")
        #expect(input[3]["arguments"] as? String == #"{"city":"Paris"}"#)
        #expect(input[4]["call_id"] as? String == "call_1")
        #expect(input[4]["output"] as? String == #"{"temp":"sunny"}"#)
        #expect(input[5]["content"] as? String == "Thanks")
    }

    @Test func theReasoningItemGoesBackUnchangedAndOnlyOpenAIs() async throws {
        let (sent, transport) = try await sent(Self.loop)
        let input = try #require(sent["input"] as? [[String: Any]])
        // Anthropic's thinking block on the same turn is not sent: one reasoning item, OpenAI's.
        #expect(input.filter { $0["type"] as? String == "reasoning" }.count == 1)
        let item = input[1]
        #expect(item["id"] as? String == "rs_1")
        #expect(item["encrypted_content"] as? String == Fixtures.responsesEncrypted)
        let summary = try #require(item["summary"] as? [[String: String]])
        #expect(summary == [
            ["type": "summary_text", "text": "Check the weather."], ["type": "summary_text", "text": "Then answer."]
        ])
        let bodyData = try #require(transport.requests.get().first?.body)
        let raw = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(raw.contains(Fixtures.responsesEncrypted))
        #expect(!raw.contains("Claude's thought."))
    }

    @Test func anEmittedReasoningItemRoundTripsIntoTheNextRequest() async throws {
        let (first, _) = makeResponses(.replay(Fixtures.responsesToolCall))
        let events = await collect(first, weatherRequest).events
        let blocks = events.compactMap { event -> ReasoningBlock? in
            if case let .reasoningBlock(block) = event { return block }
            return nil
        }
        var next = weatherRequest
        next.messages += [
            Message(role: .assistant, content: toolCallRecords(events).map { .toolCall($0) }, reasoningBlocks: blocks),
            Message(role: .tool, content: [
                .toolResult(callID: "call_1", ToolResult.success(toolName: "get_weather", content: Data("{}".utf8)))
            ])
        ]
        let (sent, _) = try await sent(next)
        let input = try #require(sent["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [
            "message", "reasoning", "function_call", "function_call_output"
        ])
        #expect(input[1]["encrypted_content"] as? String == Fixtures.responsesEncrypted)
        #expect(input[2]["call_id"] as? String == "call_1")
    }

    @Test func theAnthropicAdapterSkipsOpenAIReasoning() async throws {
        let (anthropic, transport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: "claude-opus-5-5")
        _ = await collect(anthropic, Self.loop)
        let messages = try #require(try body(transport)["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let content = try #require(assistant["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
    }

    @Test func toolsAreFlatFunctionTools() async throws {
        let (sent, _) = try await sent(weatherRequest)
        let tools = try #require(sent["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "get_weather")
        #expect(tools[0]["description"] as? String == "Look up the weather for a city")
        #expect(tools[0]["strict"] as? Bool == false)
        #expect(tools[0]["function"] == nil)
        let parameters = try #require(tools[0]["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["city"])
    }

    @Test func storeAndIncludeAlwaysAndTheOptionsOnlyWhenSet() async throws {
        let (plain, _) = try await sent(weatherRequest)
        #expect(plain["store"] as? Bool == false)
        #expect(plain["include"] as? [String] == ["reasoning.encrypted_content"])
        #expect(plain["reasoning"] == nil)
        #expect(plain["prompt_cache_key"] == nil)
        #expect(plain["instructions"] == nil)
        #expect(plain["max_output_tokens"] == nil)
        #expect(plain["text"] == nil)

        let (set, _) = try await sent(weatherRequest, effort: .xhigh, summary: .auto, cacheKey: "conversation-1")
        #expect(set["reasoning"] as? [String: String] == ["effort": "xhigh", "summary": "auto"])
        #expect(set["prompt_cache_key"] as? String == "conversation-1")
        let (empty, _) = try await sent(weatherRequest, effort: .minimal, cacheKey: "")
        #expect(empty["reasoning"] as? [String: String] == ["effort": "minimal"])
        #expect(empty["prompt_cache_key"] == nil)
        #expect(OpenAIResponsesModel.ReasoningEffort.allCases.map(\.rawValue) == [
            "none", "minimal", "low", "medium", "high", "xhigh", "max"
        ])
    }

    @Test func aStructuredRequestIsAStrictJSONSchemaTextFormat() async throws {
        let (sent, _) = try await sent(structuredRequest)
        let format = try #require((sent["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        #expect(format["name"] as? String == "structured_response")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func theSameRequestIsTheSameBytes() async throws {
        let (_, one) = try await sent(Self.loop, effort: .high)
        let (_, two) = try await sent(Self.loop, effort: .high)
        #expect(one.requests.get().first?.body == two.requests.get().first?.body)
    }

    @Test func webSearchAndASchemaWithToolsAreRefusedBeforeDispatch() async {
        var search = weatherRequest
        search.webSearch = WebSearchOptions()
        let (model, transport) = makeResponses(.replay(Fixtures.responsesText))
        guard case .invalidRequest(let field, _) = await collect(model, search).error else {
            Issue.record("expected .invalidRequest")
            return
        }
        #expect(field == "webSearch")
        guard case .invalidRequest(let both, _) = await collect(model, structuredPlusToolsRequest).error else {
            Issue.record("expected .invalidRequest")
            return
        }
        #expect(both == "responseSchema+tools")
        guard case .invalidRequest = await collect(model, malformedToolRequest).error else {
            Issue.record("expected .invalidRequest")
            return
        }
        #expect(transport.openCount.get() == 0)
        #expect(model.supportsWebSearch == false)
    }

    @Test func messageCodableKeepsTheOpenAIReasoningBlock() throws {
        let message = Message(
            role: .assistant, content: [.toolCall(Self.call)],
            reasoningBlocks: [Fixtures.responsesReasoningBlock, Self.anthropicThinking]
        )
        #expect(try JSONDecoder().decode(Message.self, from: try JSONEncoder().encode(message)) == message)
    }
}
