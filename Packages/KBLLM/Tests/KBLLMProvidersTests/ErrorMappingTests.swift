import Foundation
import KBLLM
import KBLLMRuntime
import Testing

@Suite struct ErrorMappingTests {
    // MARK: Assertion 8 - non-success status surfaces as httpStatus, no events, unchanged.

    @Test func nonSuccessStatusSurfacesUnchangedWithNoEvents() async {
        let (anth, _) = makeAnthropic(.httpStatus(code: 429, message: "rate limited"))
        let (oai, _) = makeOpenAI(.httpStatus(code: 429, message: "rate limited"))
        for model in [anth as any LanguageModel, oai as any LanguageModel] {
            let result = await collect(model, weatherRequest)
            #expect(result.events.isEmpty)
            guard case .httpStatus(let code, let message) = result.error else {
                Issue.record("expected .httpStatus, got \(String(describing: result.error))")
                continue
            }
            #expect(code == 429)
            #expect(message == "rate limited")
        }
    }

    // MARK: Assertion 9 - missing credential names the caller-supplied key exactly.

    @Test func missingCredentialNamesTheCallerSuppliedKey() async {
        let (anth, _) = makeAnthropic(
            .replay(Fixtures.anthropicWeather),
            credentials: FakeCredentialStore(response: .missing),
            key: "ANTHROPIC_API_KEY"
        )
        let anthResult = await collect(anth, weatherRequest)
        #expect(anthResult.error == .missingCredential(key: "ANTHROPIC_API_KEY"))

        let (oai, _) = makeOpenAI(
            .replay(Fixtures.openAIWeather),
            credentials: FakeCredentialStore(response: .missing),
            key: "OPENAI_API_KEY"
        )
        let oaiResult = await collect(oai, weatherRequest)
        #expect(oaiResult.error == .missingCredential(key: "OPENAI_API_KEY"))
    }

    // MARK: Assertion 10 - error mapping is total AND precise per failure class.

    @Test func requestBuildingMapsMalformedToolArgumentsToInvalidRequest() async {
        let anth: any LanguageModel = makeAnthropic(.replay(Fixtures.anthropicWeather)).0
        let oai: any LanguageModel = makeOpenAI(.replay(Fixtures.openAIWeather)).0
        for model in [anth, oai] {
            let result = await collect(model, malformedToolRequest)
            #expect(result.events.isEmpty)
            guard case .invalidRequest(let field, let reason) = result.error else {
                Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
                continue
            }
            // The field names the offending tool-call arguments; the reason is non-empty.
            #expect(field.contains("arguments"))
            #expect(field.contains("call_1"))
            #expect(!reason.isEmpty)
        }
    }

    @Test func transportReachabilityFailureMapsToTransportWithEndpointURL() async {
        let (anth, _) = makeAnthropic(.foreign(detail: "connection refused"))
        let anthResult = await collect(anth, weatherRequest)
        guard case .transport(let anthURL, let anthUnderlying) = anthResult.error else {
            Issue.record("expected .transport, got \(String(describing: anthResult.error))")
            return
        }
        #expect(anthURL == "https://api.anthropic.com/v1/messages")
        #expect(!anthUnderlying.isEmpty)

        let (oai, _) = makeOpenAI(.foreign(detail: "connection refused"))
        let oaiResult = await collect(oai, weatherRequest)
        guard case .transport(let oaiURL, let oaiUnderlying) = oaiResult.error else {
            Issue.record("expected .transport, got \(String(describing: oaiResult.error))")
            return
        }
        #expect(oaiURL == "https://api.openai.com/v1/chat/completions")
        #expect(!oaiUnderlying.isEmpty)
    }

    @Test func undecodablePayloadMapsToDecodingWithNonEmptyFragment() async {
        let (anth, _) = makeAnthropic(.replay(Fixtures.anthropicUndecodable))
        let anthResult = await collect(anth, weatherRequest)
        guard case .decoding(let anthExpected, let anthFragment) = anthResult.error else {
            Issue.record("expected .decoding, got \(String(describing: anthResult.error))")
            return
        }
        #expect(!anthExpected.isEmpty)
        #expect(!anthFragment.isEmpty)
        #expect(anthFragment.contains("content_block_delta"))

        let (oai, _) = makeOpenAI(.replay(Fixtures.openAIUndecodable))
        let oaiResult = await collect(oai, weatherRequest)
        guard case .decoding(let oaiExpected, let oaiFragment) = oaiResult.error else {
            Issue.record("expected .decoding, got \(String(describing: oaiResult.error))")
            return
        }
        #expect(!oaiExpected.isEmpty)
        #expect(!oaiFragment.isEmpty)
        #expect(oaiFragment.contains("choices"))
    }

    @Test func everyProducibleErrorIsAKBLLMError() async {
        let missingStore = FakeCredentialStore(response: .missing)
        let (missingModel, _) = makeAnthropic(.replay(Fixtures.anthropicWeather), credentials: missingStore)
        let scenarios: [Collected] = [
            await collect(missingModel, weatherRequest),
            await collect(makeAnthropic(.replay(Fixtures.anthropicWeather)).0, malformedToolRequest),
            await collect(makeAnthropic(.foreign(detail: "x")).0, weatherRequest),
            await collect(makeAnthropic(.httpStatus(code: 500, message: "boom")).0, weatherRequest),
            await collect(makeAnthropic(.replay(Fixtures.anthropicUndecodable)).0, weatherRequest)
        ]
        for scenario in scenarios {
            // `Collected.error` is typed as KBLLMError?, so a non-nil value IS a KBLLMError;
            // this pins that every producible failure class arrives typed, never untyped.
            #expect(scenario.error != nil)
        }
    }

    // MARK: Assertion 11 - the secret is placed on the wire but never leaks.

    @Test func secretIsOnTheWireButNeverLeaks() async {
        // (i) The outbound auth header really carries the sentinel (non-vacuous).
        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, weatherRequest)
        #expect(anthTransport.requests.get().first?.headers["x-api-key"] == sentinelSecret)

        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, weatherRequest)
        #expect(oaiTransport.requests.get().first?.headers["Authorization"] == "Bearer \(sentinelSecret)")

        // (ii) A full successful exchange logged through the runtime logging middleware, and
        // each of the five producible throw sites, are free of the sentinel.
        await expectNoSentinel(makeAnthropic(.replay(Fixtures.anthropicWeather)).0, weatherRequest)
        await expectNoSentinel(
            makeAnthropic(.replay(Fixtures.anthropicWeather), credentials: FakeCredentialStore(response: .missing)).0,
            weatherRequest
        )
        // The credential store RETURNS the sentinel here, so the secret is in memory when
        // the malformed-tool request fails to build; the mapped error must still be clean.
        await expectNoSentinel(makeAnthropic(.replay(Fixtures.anthropicWeather)).0, malformedToolRequest)
        await expectNoSentinel(makeAnthropic(.foreign(detail: "post-request failure")).0, weatherRequest)
        await expectNoSentinel(makeAnthropic(.httpStatus(code: 429, message: "rate limited")).0, weatherRequest)
        await expectNoSentinel(makeAnthropic(.replay(Fixtures.anthropicUndecodable)).0, weatherRequest)
        await expectNoSentinel(makeOpenAI(.replay(Fixtures.openAIWeather)).0, weatherRequest)
    }

    // MARK: Assertion 11(iii) - a transport error carrying the secret is redacted.

    @Test func transportErrorCarryingSecretIsRedacted() async {
        let leakyDetail = "socket reset while sending \(sentinelSecret)"
        let (anth, _) = makeAnthropic(.foreign(detail: leakyDetail))
        let records = Box<[(LogLevel, String)]>([])
        let sink = SpyLogSink(records: records)
        let logged = wrap(anth, with: [LoggingMiddleware(sink: sink)])
        let result = await collect(logged, weatherRequest)

        guard case .transport(_, let underlying) = result.error else {
            Issue.record("expected .transport, got \(String(describing: result.error))")
            return
        }
        // The adapter really saw the secret in the message (the redaction marker proves it),
        // yet the mapped value and every log record are free of the sentinel.
        #expect(underlying.contains("[redacted]"))
        #expect(!underlying.contains(sentinelSecret))
        #expect(!String(describing: result.error).contains(sentinelSecret))
        #expect(!sink.joined.contains(sentinelSecret))
    }

    /// Drain a model through the logging middleware and assert the sentinel appears in
    /// neither the log nor the mapped error.
    private func expectNoSentinel(_ model: any LanguageModel, _ request: ModelRequest) async {
        let records = Box<[(LogLevel, String)]>([])
        let sink = SpyLogSink(records: records)
        let logged = wrap(model, with: [LoggingMiddleware(sink: sink)])
        let result = await collect(logged, request)
        #expect(!sink.joined.contains(sentinelSecret))
        if let error = result.error {
            #expect(!String(describing: error).contains(sentinelSecret))
        }
    }
}
