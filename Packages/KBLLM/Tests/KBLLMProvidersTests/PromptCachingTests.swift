import Foundation
import KBLLM
import KBLLMAnthropic
import Testing

/// Where `AnthropicPromptCaching` puts `cache_control`, proved on the parsed request body: the
/// system prompt, the last tool when there is no system prompt, the newest message's last
/// cacheable block for a conversation, the one-hour form, and byte-stable serialization.
@Suite struct PromptCachingTests {
    private func send(_ caching: AnthropicPromptCaching, _ request: ModelRequest) async -> [String: Any] {
        let transport = RecordingTransport(.replay(Fixtures.anthropicWeather))
        let model = AnthropicModel(
            model: "claude-x",
            credentialKey: "K",
            promptCaching: caching,
            transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, request)
        let body = transport.requests.get().first?.body ?? Data()
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    private func blocks(_ body: [String: Any]) -> [[[String: Any]]] {
        (body["messages"] as? [[String: Any]] ?? []).map { $0["content"] as? [[String: Any]] ?? [] }
    }

    private func marks(_ body: [String: Any]) -> Int {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: "cache_control").count - 1
    }

    private var systemHistory: ModelRequest {
        ModelRequest(
            messages: [Message(role: .system, text: "You are terse.")] + historyRequest.messages,
            tools: [weatherTool]
        )
    }

    @Test func offSendsNoBreakpoint() async {
        let body = await send(.off, systemHistory)
        #expect(body["system"] as? String == "You are terse.")
        #expect(marks(body) == 0)
    }

    @Test func systemPromptMarksOnlyTheSystemPrompt() async {
        let body = await send(.systemPrompt, systemHistory)
        let system = body["system"] as? [[String: Any]]
        #expect(system?.last?["cache_control"] as? [String: String] == ["type": "ephemeral"])
        #expect(marks(body) == 1)
    }

    @Test func conversationAlsoMarksTheNewestMessage() async {
        let body = await send(.conversation, systemHistory)
        let last = blocks(body).last?.last
        #expect(last?["text"] as? String == "Thanks")
        #expect(last?["cache_control"] as? [String: String] == ["type": "ephemeral"])
        // The system prompt and the newest message: two of the four breakpoints a request may use.
        #expect(marks(body) == 2)
    }

    /// An agent loop's request ends on tool results, which are the block that must carry the mark.
    @Test func conversationMarksATrailingToolResult() async {
        let request = ModelRequest(messages: Array(systemHistory.messages.dropLast()), tools: [weatherTool])
        let body = await send(.conversation, request)
        let last = blocks(body).last?.last
        #expect(last?["type"] as? String == "tool_result")
        #expect(last?["cache_control"] != nil)
    }

    /// The API rejects `cache_control` on an empty text block, so the mark goes on the block before it.
    @Test func conversationSkipsAnEmptyTrailingTextBlock() async {
        let request = ModelRequest(messages: [
            Message(role: .user, content: [.text("Describe this."), .text("")])
        ])
        let body = await send(.conversation, request)
        let content = blocks(body).last ?? []
        #expect(content.first?["cache_control"] != nil)
        #expect(content.last?["cache_control"] == nil)
    }

    @Test func withoutASystemPromptTheLastToolCarriesTheBreakpoint() async {
        let body = await send(.systemPrompt, weatherRequest)
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.last?["cache_control"] as? [String: String] == ["type": "ephemeral"])
        #expect(marks(body) == 1)
    }

    @Test func oneHourLifetimeOnEveryBreakpoint() async {
        let caching = AnthropicPromptCaching(cachesSystemPrompt: true, cachesConversation: true, lifetime: .oneHour)
        let body = await send(caching, systemHistory)
        let hour = ["type": "ephemeral", "ttl": "1h"]
        #expect((body["system"] as? [[String: Any]])?.last?["cache_control"] as? [String: String] == hour)
        #expect(blocks(body).last?.last?["cache_control"] as? [String: String] == hour)
    }

    /// Keys are written sorted, so the same request has the same bytes in every process, whatever
    /// the hash seed: a cache entry is a byte-prefix match.
    @Test func bodyKeysAreSorted() async {
        let transport = RecordingTransport(.replay(Fixtures.anthropicWeather))
        let model = AnthropicModel(
            model: "claude-x", credentialKey: "K", promptCaching: .conversation,
            transport: transport, credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, systemHistory)
        let sent = transport.requests.get().first?.body ?? Data()
        let object = try? JSONSerialization.jsonObject(with: sent)
        let resorted = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        #expect(sent == resorted)
    }
}
