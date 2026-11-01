import Foundation
import KBLLM
import KBLLMOpenAI
import Testing

/// OpenAI's prompt cache, at the wire: the opt-in `prompt_cache_key` on the request, and the
/// cache-write count a model that bills writes reports beside its cache reads.
@Suite struct OpenAIPromptCacheTests {
    private func body(_ transport: RecordingTransport) throws -> [String: Any] {
        let data = try #require(transport.requests.get().first?.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func model(promptCacheKey: String?, transport: RecordingTransport) -> OpenAIModel {
        OpenAIModel(
            model: "gpt-5.6-terra",
            credentialKey: "K",
            promptCacheKey: promptCacheKey,
            transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
    }

    private func usage(_ events: [ModelEvent]) -> TokenUsage? {
        events.lazy.compactMap { event -> TokenUsage? in
            guard case let .usage(usage) = event else { return nil }
            return usage
        }.first
    }

    @Test func noKeyIsSentUnlessTheCallerSetsOne() async throws {
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        _ = await collect(model(promptCacheKey: nil, transport: transport), weatherRequest)
        #expect(try body(transport)["prompt_cache_key"] == nil)

        // An empty key is no key: sending "" would group every caller's requests together.
        let empty = RecordingTransport(.replay(Fixtures.openAIWeather))
        _ = await collect(model(promptCacheKey: "", transport: empty), weatherRequest)
        #expect(try body(empty)["prompt_cache_key"] == nil)
    }

    @Test func theKeyIsSentAsPromptCacheKeyOnEveryRequest() async throws {
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        let adapter = model(promptCacheKey: "conversation-1", transport: transport)
        _ = await collect(adapter, weatherRequest)
        _ = await collect(adapter, weatherRequest)
        let bodies = try transport.requests.get().map { spec in
            try #require(try JSONSerialization.jsonObject(with: spec.body ?? Data()) as? [String: Any])
        }
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["prompt_cache_key"] as? String == "conversation-1" })
    }

    @Test func cacheWritesAreReadBesideCacheReads() async throws {
        let result = await collect(makeOpenAI(.replay(Fixtures.openAIWithCacheWrites)).0, weatherRequest)
        #expect(result.error == nil)
        let reported = try #require(usage(result.events))
        // `prompt_tokens` as reported (it includes both), the reads as reads, the writes as writes.
        #expect(reported.inputTokens == 12000)
        #expect(reported.cacheReadTokens == 4000)
        #expect(reported.cacheWriteTokens == 7000)
        #expect(reported.outputTokens == 250)
        #expect(reported.cacheWrite1hTokens == 0)
    }

    @Test func aResponseWithoutTheWriteFieldReadsAsBefore() async throws {
        let result = await collect(makeOpenAI(.replay(Fixtures.openAIWithUsage)).0, weatherRequest)
        let reported = try #require(usage(result.events))
        #expect(reported == TokenUsage(inputTokens: 13, outputTokens: 21, cacheReadTokens: 8))
    }
}
