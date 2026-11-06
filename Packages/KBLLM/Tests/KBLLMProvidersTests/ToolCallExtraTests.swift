import Foundation
import KBLLM
import KBLLMOpenAI
import Testing

/// Gemini over its OpenAI-compatible endpoint signs each tool call (`extra_content.google.thought_signature`) and
/// refuses a tool loop's next request without the signature on that call. The adapter keeps the call's
/// `extra_content` as a `ReasoningBlock.toolCallExtra` and sends it back unchanged; a server that sends none sees no
/// change. Offline: replayed bytes.
@Suite struct ToolCallExtraTests {
    static let signature = "EvEFCu4FAXLI2nx/sig+/=="

    /// A Gemini-shaped stream: one tool call whose first delta carries the signature, its arguments in two deltas.
    static let geminiToolCall = Fixtures.bytes(
        Fixtures.frame(data: Fixtures.openAIChoice(
            #"{"role":"assistant","tool_calls":[{"index":0,"id":"call_g1","type":"function","#
            + #""function":{"name":"get_weather","arguments":"{\"city\":"},"#
            + #""extra_content":{"google":{"thought_signature":"\#(signature)"}}}]}"#
        ))
        + Fixtures.frame(data: Fixtures.openAIChoice(
            #"{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}"#
        ))
        + Fixtures.frame(data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)
        + Fixtures.frame(data: "[DONE]")
    )

    private func model(_ transport: RecordingTransport) -> OpenAIModel {
        OpenAIModel(
            model: "gemini-3.8-flash", credentialKey: "K",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
    }

    @Test func aSignedToolCallYieldsItsExtraBeforeTheCallWithItsKeysAsSent() async throws {
        let events = await collect(model(RecordingTransport(.replay(Self.geminiToolCall))), weatherRequest).events
        let extras = events.compactMap { event -> ReasoningBlock? in
            if case let .reasoningBlock(block) = event { block } else { nil }
        }
        let json = #"{"google":{"thought_signature":"\#(Self.signature)"}}"#
        #expect(extras == [.toolCallExtra(callID: "call_g1", json: json)], "snake_case kept, not thoughtSignature")
        let blockIndex = try #require(events.firstIndex { if case .reasoningBlock = $0 { true } else { false } })
        let callIndex = try #require(events.firstIndex { if case .toolCall = $0 { true } else { false } })
        #expect(blockIndex < callIndex)
        guard case let .toolCall(record) = events[callIndex] else { return }
        #expect(String(bytes: record.arguments, encoding: .utf8) == #"{"city":"Paris"}"#)
    }

    @Test func theExtraGoesBackOnItsCallInTheNextRequest() async throws {
        let events = await collect(model(RecordingTransport(.replay(Self.geminiToolCall))), weatherRequest).events
        let blocks = events.compactMap { event -> ReasoningBlock? in
            if case let .reasoningBlock(block) = event { block } else { nil }
        }
        let calls = events.compactMap { event -> ToolCallRecord? in
            if case let .toolCall(record) = event { record } else { nil }
        }
        var next = weatherRequest
        next.messages += [
            Message(role: .assistant, content: calls.map { .toolCall($0) }, reasoningBlocks: blocks),
            Message(role: .tool, content: [
                .toolResult(callID: "call_g1", ToolResult.success(toolName: "get_weather", content: Data("{}".utf8)))
            ])
        ]
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        _ = await collect(model(transport), next)
        let data = try #require(transport.requests.get().first?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let call = try #require((assistant["tool_calls"] as? [[String: Any]])?.first)
        let google = (call["extra_content"] as? [String: Any])?["google"] as? [String: Any]
        #expect(google?["thought_signature"] as? String == Self.signature)
    }

    @Test func aStreamWithoutExtrasEmitsNoBlockAndSendsNoExtraContent() async throws {
        let events = await collect(model(RecordingTransport(.replay(Fixtures.openAIWeather))), weatherRequest).events
        #expect(!events.contains { if case .reasoningBlock = $0 { true } else { false } })
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        _ = await collect(model(transport), ReasoningReplayTests.request)
        let data = try #require(transport.requests.get().first?.body)
        #expect(!(String(bytes: data, encoding: .utf8) ?? "").contains("extra_content"))
    }
}
