import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import KBLLMRuntime
import KBLLMTesting
import Testing

/// Anthropic's signed thinking blocks kept and sent back unchanged (`ModelEvent.reasoningBlock`,
/// `Message.reasoningBlocks`), the `thinking` and `output_config.effort` settings on `AnthropicModel`, and the
/// `thinking` switch and the wider `reasoning_effort` on `OpenAIModel`. Offline: every response is replayed bytes.
@Suite struct ThinkingBlockTests {
    static let signature = "EqQBCkYIBxgCKkA/sig+with/slashes=="

    /// A signed thinking block, a redacted one, then a tool call.
    static let signedThinking = Fixtures.bytes(
        Fixtures.frame(event: "message_start", data: #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}"#)
        + Fixtures.frame(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
        + Fixtures.frame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Check the "}}"#)
        + Fixtures.frame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weather."}}"#)
        + Fixtures.frame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCkYIBxgCKkA/sig+with/slashes=="}}"#)
        + Fixtures.frame(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#)
        + Fixtures.frame(event: "content_block_start", data: #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"ENCRYPTED/data"}}"#)
        + Fixtures.frame(event: "content_block_stop", data: #"{"type":"content_block_stop","index":1}"#)
        + Fixtures.frame(event: "content_block_start", data: #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"call_1","name":"get_weather","input":{}}}"#)
        + Fixtures.frame(event: "content_block_delta", data: #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Paris\"}"}}"#)
        + Fixtures.frame(event: "content_block_stop", data: #"{"type":"content_block_stop","index":2}"#)
        + Fixtures.frame(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#)
        + Fixtures.frame(event: "message_stop", data: #"{"type":"message_stop"}"#)
    )

    static let blocks: [ReasoningBlock] = [
        .thinking(text: "Check the weather.", signature: signature), .redacted(data: "ENCRYPTED/data")
    ]

    private func body(_ transport: RecordingTransport) throws -> [String: Any] {
        let data = try #require(transport.requests.get().first?.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func signedBlocksAreEmittedWholeAfterTheirDeltas() async throws {
        let (anth, _) = makeAnthropic(.replay(Self.signedThinking), model: "claude-sonnet-5-5")
        let result = await collect(anth, weatherRequest)
        #expect(result.error == nil)
        let kept = result.events.compactMap { event -> ReasoningBlock? in
            if case let .reasoningBlock(block) = event { return block }
            return nil
        }
        #expect(kept == Self.blocks)
        #expect(result.events.contains(.reasoningDelta("Check the ")))
        // A block ends before the tool call that follows it.
        let blockIndex = try #require(result.events.firstIndex(of: .reasoningBlock(Self.blocks[0])))
        let callIndex = try #require(result.events.firstIndex { if case .toolCall = $0 { true } else { false } })
        #expect(blockIndex < callIndex)
    }

    @Test func anUnsignedThinkingBlockIsShownButNotKept() async {
        let (anth, _) = makeAnthropic(.replay(Fixtures.anthropicReasoning))
        let result = await collect(anth, weatherRequest)
        #expect(result.events.contains(.reasoningDelta(Fixtures.anthropicReasoningText)))
        #expect(!result.events.contains { if case .reasoningBlock = $0 { true } else { false } })
    }

    @Test func blocksGoBackUnchangedAheadOfTheAssistantTurnsContent() async throws {
        let request = ModelRequest(messages: [
            Message(role: .user, text: "What is the weather in Paris?"),
            Message(
                role: .assistant,
                content: [.toolCall(ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8)))],
                reasoning: "Check the weather.", reasoningBlocks: Self.blocks
            ),
            Message(role: .tool, content: [
                .toolResult(callID: "call_1", ToolResult.success(toolName: "get_weather", content: Data(#"{"temp":"sunny"}"#.utf8)))
            ])
        ], tools: [weatherTool])
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: "claude-opus-5-5")
        _ = await collect(anth, request)
        let messages = try #require(try body(transport)["messages"] as? [[String: Any]])
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "redacted_thinking", "tool_use"])
        #expect(content[0]["thinking"] as? String == "Check the weather.")
        #expect(content[0]["signature"] as? String == Self.signature)
        #expect(content[1]["data"] as? String == "ENCRYPTED/data")
        // The signature's bytes go out as received, never with `\/`.
        let raw = String(decoding: try #require(transport.requests.get().first?.body), as: UTF8.self)
        #expect(raw.contains(Self.signature))
    }

    @Test func aSessionKeepsTheBlocksOnItsAssistantMessage() async throws {
        let model = ReplayModel(transcript: [
            .reasoningDelta("Check the weather."), .reasoningBlock(Self.blocks[0]), .reasoningBlock(Self.blocks[1]),
            .contentDelta("Sunny."), .completed(.stop)
        ])
        let result = try await AgentSession(model: model).run(weatherRequest)
        let assistant = try #require(result.messages.last { $0.role == .assistant })
        #expect(assistant.reasoningBlocks == Self.blocks)
        #expect(assistant.reasoning == "Check the weather.")
        // A turn without blocks keeps none.
        let plain = try await AgentSession(model: ReplayModel(transcript: [.contentDelta("Hi."), .completed(.stop)]))
            .run(weatherRequest)
        #expect(plain.messages.last?.reasoningBlocks == nil)
    }

    @Test func thinkingAndEffortReachTheWireOnlyWhenSet() async throws {
        let (plain, plainTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: "claude-opus-5-5")
        _ = await collect(plain, weatherRequest)
        let unset = try body(plainTransport)
        #expect(unset["thinking"] == nil)
        #expect(unset["output_config"] == nil)

        let cases: [(AnthropicThinking, [String: String])] = [
            (.adaptive(summarized: true), ["type": "adaptive", "display": "summarized"]),
            (.adaptive(summarized: false), ["type": "adaptive"]),
            (.betweenTools, ["type": "between_tools"]),
            (.disabled, ["type": "disabled"])
        ]
        for (thinking, expected) in cases {
            let transport = RecordingTransport(.replay(Fixtures.anthropicWithUsage))
            let model = AnthropicModel(
                model: "claude-haiku-5-5", credentialKey: "K", thinking: thinking, effort: .low,
                transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret))
            )
            _ = await collect(model, weatherRequest)
            let sent = try body(transport)
            #expect(sent["thinking"] as? [String: String] == expected)
            #expect((sent["output_config"] as? [String: Any])?["effort"] as? String == "low")
        }
    }

    @Test func effortSitsBesideAStructuredRequestsFormat() async throws {
        let transport = RecordingTransport(.replay(Fixtures.anthropicWithUsage))
        let model = AnthropicModel(
            model: "claude-sonnet-5-5", credentialKey: "K", effort: .max,
            transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        var request = ModelRequest(messages: [Message(role: .user, text: "Name a city.")])
        request.responseSchema = .object(properties: ["city": .string(description: nil)], required: ["city"], description: nil)
        _ = await collect(model, request)
        let config = try #require(try body(transport)["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "max")
        #expect(config["format"] != nil)
    }

    @Test func openAIThinkingSwitchAndHigherEffortsReachTheWire() async throws {
        let (unset, unsetTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(unset, weatherRequest)
        #expect(try body(unsetTransport)["thinking"] == nil)

        for (thinking, effort) in [(OpenAIModel.ThinkingSwitch.disabled, nil), (.enabled, OpenAIModel.ReasoningEffort.max)] {
            let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
            let model = OpenAIModel(
                model: "deepseek-flash", credentialKey: "K", baseURL: "https://api.deepseek.com", reasoningEffort: effort,
                thinking: thinking, transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret))
            )
            _ = await collect(model, weatherRequest)
            let sent = try body(transport)
            #expect(sent["thinking"] as? [String: String] == ["type": thinking.rawValue])
            #expect(sent["reasoning_effort"] as? String == effort?.rawValue)
        }
    }

    @Test func messageCodableKeepsReasoningBlocksAndReadsOldJSON() throws {
        let message = Message(role: .assistant, content: [.text("hi")], reasoning: "r", reasoningBlocks: Self.blocks)
        #expect(try JSONDecoder().decode(Message.self, from: try JSONEncoder().encode(message)) == message)
        let plain = try JSONEncoder().encode(Message(role: .assistant, text: "hi"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("reasoningBlocks"))
        #expect(try JSONDecoder().decode(Message.self, from: plain).reasoningBlocks == nil)
    }
}
