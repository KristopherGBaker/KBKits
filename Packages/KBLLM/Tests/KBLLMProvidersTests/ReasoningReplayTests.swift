import Foundation
import KBLLM
import KBLLMOpenAI
import Testing

/// The model's reasoning kept on the assistant turn (`Message.reasoning`) and, for an OpenAI-compatible adapter told to
/// replay it, sent back as `reasoning_content`: what DeepSeek's thinking mode requires once a request has tools. Also its
/// context-cache usage (`prompt_cache_hit_tokens`). Offline: every response is replayed bytes.
@Suite struct ReasoningReplayTests {
    static let thought = "The user wants Paris; call get_weather first."

    /// A conversation whose assistant tool-call turn carries the reasoning it was produced with.
    static let request = ModelRequest(
        messages: [
            Message(role: .system, text: "Be brief."),
            Message(role: .user, text: "What is the weather in Paris?"),
            Message(
                role: .assistant,
                content: [
                    .text("Checking."),
                    .toolCall(ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8)))
                ],
                reasoning: thought
            ),
            Message(role: .tool, content: [
                .toolResult(callID: "call_1", ToolResult.success(toolName: "get_weather", content: Data(#"{"temp":"sunny"}"#.utf8)))
            ]),
            Message(role: .assistant, content: [.text("Sunny.")], reasoning: ""),
            Message(role: .user, text: "Thanks")
        ],
        tools: [weatherTool]
    )

    private func messages(replays: Bool, _ request: ModelRequest = request) async throws -> [[String: Any]] {
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        let model = OpenAIModel(
            model: "deepseek-flash", credentialKey: "K", baseURL: "https://api.deepseek.com", replaysReasoning: replays,
            transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, request)
        let data = try #require(transport.requests.get().first?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(body["messages"] as? [[String: Any]])
    }

    @Test func replayedReasoningRidesOnTheAssistantToolCallMessageOnly() async throws {
        let wire = try await messages(replays: true)
        #expect(wire.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "assistant", "user"])
        let call = wire[2]
        #expect(call["reasoning_content"] as? String == Self.thought)
        #expect((call["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(call["content"] as? String == "Checking.")
        // An empty reasoning is no reasoning; and no other role ever carries the key.
        #expect(wire[4]["reasoning_content"] == nil)
        for index in [0, 1, 3, 5] {
            #expect(wire[index]["reasoning_content"] == nil, "message \(index)")
        }
    }

    @Test func withoutReplayTheBodyIsExactlyTheOneWithoutReasoning() async throws {
        let wire = try await messages(replays: false)
        #expect(wire.allSatisfy { $0["reasoning_content"] == nil })
        var stripped = Self.request
        stripped.messages = stripped.messages.map { Message(role: $0.role, content: $0.content) }
        let plain = try await messages(replays: false, stripped)
        let canonical = { (value: [[String: Any]]) in
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        #expect(try canonical(wire) == canonical(plain))
        // Replaying a conversation with no reasoning sends the same body too.
        #expect(try canonical(try await messages(replays: true, stripped)) == canonical(plain))
    }

    @Test func anthropicIgnoresReasoningOnAMessage() async throws {
        let with = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(with.0, Self.request)
        var stripped = Self.request
        stripped.messages = stripped.messages.map { Message(role: $0.role, content: $0.content) }
        let without = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(without.0, stripped)
        let first = try #require(with.1.requests.get().first?.body)
        let second = try #require(without.1.requests.get().first?.body)
        #expect(first == second)
        #expect(!String(decoding: first, as: UTF8.self).contains(Self.thought))
    }

    @Test func collectedResponseCarriesTheReasoning() async throws {
        let response = try await makeOpenAI(.replay(Fixtures.openAIReasoning)).0.complete(weatherRequest)
        #expect(response.reasoning == Fixtures.openAIReasoningText)
        #expect(!response.content.contains(Fixtures.openAIReasoningText))
        let plain = try await makeOpenAI(.replay(Fixtures.openAIWeather)).0.complete(weatherRequest)
        #expect(plain.reasoning.isEmpty)
    }

    @Test func messageCodableKeepsReasoningAndReadsOldJSON() throws {
        let message = Message(role: .assistant, content: [.text("hi")], reasoning: "thinking")
        let decoded = try JSONDecoder().decode(Message.self, from: try JSONEncoder().encode(message))
        #expect(decoded == message)
        // A message without reasoning encodes with no `reasoning` key, as it did before the field existed...
        let plain = try JSONEncoder().encode(Message(role: .assistant, text: "hi"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("reasoning"))
        // ...and JSON written before it decodes, with none.
        let old = try JSONDecoder().decode(Message.self, from: plain)
        #expect(old.reasoning == nil)
        #expect(old == Message(role: .assistant, text: "hi"))
    }

    /// DeepSeek's final streamed chunk: usage rides on the chunk with `finish_reason` (not a choice-less frame), with
    /// `prompt_tokens` = hits + misses and the hits also as `prompt_tokens_details.cached_tokens`.
    static let deepSeekUsage = Fixtures.bytes(
        Fixtures.frame(data: #"{"choices":[{"index":0,"delta":{"reasoning_content":"Short."},"finish_reason":null}]}"#)
        + Fixtures.frame(data: #"{"choices":[{"index":0,"delta":{"content":"Hi."},"finish_reason":null}]}"#)
        + Fixtures.frame(
            data: #"{"choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"#
                + #""completion_tokens":40,"total_tokens":1240,"prompt_tokens_details":{"cached_tokens":1024},"#
                + #""prompt_cache_hit_tokens":1024,"prompt_cache_miss_tokens":176,"#
                + #""completion_tokens_details":{"reasoning_tokens":12}}}"#
        )
        + Fixtures.frame(data: "[DONE]")
    )

    /// The same without `prompt_tokens_details`: only DeepSeek's own field names the hits.
    static let deepSeekHitsOnly = Fixtures.bytes(
        Fixtures.frame(data: #"{"choices":[{"index":0,"delta":{"content":"Hi."},"finish_reason":"stop"}],"#
            + #""usage":{"prompt_tokens":1200,"completion_tokens":40,"prompt_cache_hit_tokens":1024,"#
            + #""prompt_cache_miss_tokens":176}}"#)
        + Fixtures.frame(data: "[DONE]")
    )

    @Test func deepSeekCacheHitsAreCacheReadsCountedOnce() async throws {
        for bytes in [Self.deepSeekUsage, Self.deepSeekHitsOnly] {
            let response = try await makeOpenAI(.replay(bytes)).0.complete(weatherRequest)
            // `prompt_tokens` as reported (it includes the hits, as OpenAI's does), the hits as reads, no writes.
            #expect(response.usage == TokenUsage(inputTokens: 1200, outputTokens: 40, cacheReadTokens: 1024))
            #expect(response.content == "Hi.")
            #expect(response.finishReason == .stop)
        }
    }
}
