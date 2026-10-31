import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

// The transport-facing behaviors added in unit 4: the adapter "no usable stream" rule for
// BOTH providers, an injectable base URL (default and custom, malformed rejection, exact
// composed URL in a `.transport` error), and reasoning surfaced as a neutral event that never
// leaks into the collected content. Everything is driven through the recording fake transport,
// so no request reaches a real server.
@Suite struct ProviderTransportTests {
    // MARK: Assertion 6 - the adapter zero-events rule, pinned for BOTH adapters.

    @Test func legitimateStreamsProduceEventsAndNoDecodingError() async {
        let anth = await collect(makeAnthropic(.replay(Fixtures.anthropicWeather)).0, weatherRequest)
        #expect(anth.error == nil)
        #expect(!anth.events.isEmpty)

        let oai = await collect(makeOpenAI(.replay(Fixtures.openAIWeather)).0, weatherRequest)
        #expect(oai.error == nil)
        #expect(!oai.events.isEmpty)
    }

    @Test func openAIZeroEventDrainSurfacesDecodingNamingTheBody() async {
        // (b) A 200 whose body is a plain JSON error object, not a stream.
        let jsonError = await collect(makeOpenAI(.replay(Fixtures.openAIJSONError200)).0, weatherRequest)
        #expect(jsonError.events.isEmpty)
        guard case .decoding(let expected, let fragment) = jsonError.error else {
            Issue.record("expected .decoding, got \(String(describing: jsonError.error))")
            return
        }
        #expect(!expected.isEmpty)
        #expect(fragment.contains("error"))

        // (c) A 200 event-stream whose frames yield no usable event.
        let streamError = await collect(makeOpenAI(.replay(Fixtures.openAIStreamErrorNoEvents)).0, weatherRequest)
        #expect(streamError.events.isEmpty)
        guard case .decoding(_, let streamFragment) = streamError.error else {
            Issue.record("expected .decoding, got \(String(describing: streamError.error))")
            return
        }
        #expect(!streamFragment.isEmpty)
    }

    @Test func anthropicZeroEventDrainSurfacesDecodingNamingTheBody() async {
        // (d) A 200 body in Anthropic wire form that is an error object, not a stream.
        let result = await collect(makeAnthropic(.replay(Fixtures.anthropicJSONError200)).0, weatherRequest)
        #expect(result.events.isEmpty)
        guard case .decoding(let expected, let fragment) = result.error else {
            Issue.record("expected .decoding, got \(String(describing: result.error))")
            return
        }
        #expect(!expected.isEmpty)
        #expect(!fragment.isEmpty)
        #expect(fragment.contains("error"))
    }

    // MARK: Assertion 8 - default and custom base URLs, by exact request-URL equality.

    @Test func baseURLDefaultsToThePublicEndpointForBothAdapters() async {
        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, weatherRequest)
        #expect(anthTransport.requests.get().first?.url == "https://api.anthropic.com/v1/messages")

        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, weatherRequest)
        #expect(oaiTransport.requests.get().first?.url == "https://api.openai.com/v1/chat/completions")
    }

    @Test func customBaseURLComposesTheProviderPathForBothAdapters() async {
        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather), baseURL: "http://localhost:1234/v1")
        _ = await collect(oai, weatherRequest)
        #expect(oaiTransport.requests.get().first?.url == "http://localhost:1234/v1/chat/completions")

        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather), baseURL: "http://localhost:8080")
        _ = await collect(anth, weatherRequest)
        #expect(anthTransport.requests.get().first?.url == "http://localhost:8080/v1/messages")
    }

    // MARK: Assertion 9 - a malformed base URL is rejected without opening the transport.

    @Test func malformedBaseURLIsRejectedAndOpensTheTransportZeroTimes() async {
        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather), baseURL: "http://exa mple")
        let oaiResult = await collect(oai, weatherRequest)
        guard case .invalidRequest(let oaiField, let oaiReason) = oaiResult.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: oaiResult.error))")
            return
        }
        #expect(oaiField == "baseURL")
        #expect(oaiReason.contains("http://exa mple"))
        #expect(oaiTransport.openCount.get() == 0)

        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather), baseURL: "http://exa mple")
        let anthResult = await collect(anth, weatherRequest)
        guard case .invalidRequest(let anthField, let anthReason) = anthResult.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: anthResult.error))")
            return
        }
        #expect(anthField == "baseURL")
        #expect(anthReason.contains("http://exa mple"))
        #expect(anthTransport.openCount.get() == 0)
    }

    // MARK: Assertion 10 - a transport failure reports the EXACT composed URL used.

    @Test func transportErrorReportsTheExactComposedURL() async {
        let (oai, _) = makeOpenAI(.foreign(detail: "connection refused"), baseURL: "http://localhost:9/v1")
        let oaiResult = await collect(oai, weatherRequest)
        guard case .transport(let oaiURL, _) = oaiResult.error else {
            Issue.record("expected .transport, got \(String(describing: oaiResult.error))")
            return
        }
        #expect(oaiURL == "http://localhost:9/v1/chat/completions")

        let (anth, _) = makeAnthropic(.foreign(detail: "connection refused"), baseURL: "http://localhost:9")
        let anthResult = await collect(anth, weatherRequest)
        guard case .transport(let anthURL, _) = anthResult.error else {
            Issue.record("expected .transport, got \(String(describing: anthResult.error))")
            return
        }
        #expect(anthURL == "http://localhost:9/v1/messages")
    }

    // MARK: Assertion 11 - reasoning surfaces as `.reasoningDelta`, never into content.

    @Test func openAIReasoningSurfacesAsEventAndNeverInContent() async throws {
        let (oai, _) = makeOpenAI(.replay(Fixtures.openAIReasoning))
        let result = await collect(oai, weatherRequest)
        #expect(result.error == nil)
        #expect(result.events.contains(.reasoningDelta(Fixtures.openAIReasoningText)))

        let response = try await makeOpenAI(.replay(Fixtures.openAIReasoning)).0.complete(weatherRequest)
        #expect(response.content == "The weather in Paris is sunny.")
        #expect(!response.content.contains(Fixtures.openAIReasoningText))
    }

    @Test func anthropicReasoningSurfacesAsEventAndNeverInContent() async throws {
        let (anth, _) = makeAnthropic(.replay(Fixtures.anthropicReasoning))
        let result = await collect(anth, weatherRequest)
        #expect(result.error == nil)
        #expect(result.events.contains(.reasoningDelta(Fixtures.anthropicReasoningText)))

        let response = try await makeAnthropic(.replay(Fixtures.anthropicReasoning)).0.complete(weatherRequest)
        #expect(response.content == "The weather in Paris is sunny.")
        #expect(!response.content.contains(Fixtures.anthropicReasoningText))
    }
}
