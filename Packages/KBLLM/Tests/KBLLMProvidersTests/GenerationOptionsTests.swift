import Foundation
import KBLLM
import Testing

// Unit 9: the neutral `GenerationOptions` must reach the WIRE. These offline tests drive each
// HTTP adapter through the recording transport, then decode the recorded request body via
// `JSONSerialization` and compare TYPED values (not float substrings), so a knob that is set
// appears with the exact value and a knob that is unset appears with no key at all. The sole
// exception is Anthropic's wire-required `max_tokens`, which falls back to 4096 only when the
// caller supplied none. Every fixture is finite and offline, so no assertion can hang.
@Suite struct GenerationOptionsTests {
    /// Decode the first recorded request body into a typed dictionary. The adapters serialize
    /// with `JSONSerialization`, so the numbers come back as `NSNumber` and bridge to both
    /// `Double` and `Int` where the wire value is integral.
    private func decodedBody(_ transport: RecordingTransport) -> [String: Any] {
        let body = transport.requests.get().first?.body ?? Data()
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// A minimal request carrying the given options, enough to drive request building.
    private func request(_ options: GenerationOptions) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "hi")], options: options)
    }

    /// The three-knob options every carry-to-the-wire assertion drives.
    private let allThree = GenerationOptions(temperature: 0.3, maxOutputTokens: 4000, topP: 0.9)

    // MARK: Assertion 1 - the options value exists and its default is inert.

    @Test func generationOptionsDefaultIsInert() {
        let options = ModelRequest(messages: [Message(role: .user, text: "hi")]).options
        #expect(options.temperature == nil)
        #expect(options.maxOutputTokens == nil)
        #expect(options.topP == nil)
    }

    // MARK: Assertion 2 - OpenAI carries all three knobs to the wire.

    @Test func openAIBodyCarriesGenerationOptions() async {
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, request(allThree))
        let body = decodedBody(transport)
        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["max_tokens"] as? Int == 4000)
        #expect(body["top_p"] as? Double == 0.9)
    }

    // MARK: The output-token field is the caller's choice, defaulting to the old name.

    @Test func openAIUsesMaxCompletionTokensWhenAsked() async {
        // OpenAI's newer models REJECT `max_tokens` with a 400 `unsupported_parameter` rather
        // than ignoring it, while older models and LM Studio only understand the old name.
        // There is no name that works everywhere, so the caller picks.
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather), outputTokenField: .maxCompletionTokens)
        _ = await collect(oai, request(allThree))
        let body = decodedBody(transport)

        #expect(body["max_completion_tokens"] as? Int == 4000)
        // Exactly one of the two, or a strict endpoint rejects the request for carrying both.
        #expect(body["max_tokens"] == nil)
    }

    @Test func openAIDefaultsToMaxTokens() async {
        // The default must not change behaviour for anything already using this adapter.
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, request(allThree))
        let body = decodedBody(transport)

        #expect(body["max_tokens"] as? Int == 4000)
        #expect(body["max_completion_tokens"] == nil)
    }

    // MARK: Assertion 3 - Anthropic carries all three; the caller max is honoured unchanged.

    @Test func anthropicBodyCarriesGenerationOptions() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, request(allThree))
        let body = decodedBody(transport)
        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["top_p"] as? Double == 0.9)
        // The caller's value, not a constant: 4000, not the 4096 fallback.
        #expect(body["max_tokens"] as? Int == 4000)
    }

    // MARK: Assertion 4 - Anthropic falls back to 4096 (not the old constant) only on absence.

    @Test func anthropicOmittedMaxTokensUsesFallbackNot1024() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, request(GenerationOptions()))
        let body = decodedBody(transport)
        #expect(body.keys.contains("max_tokens"))
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["max_tokens"] as? Int != 1024)
    }

    // MARK: Assertion 5 - OpenAI omits every unset knob.

    @Test func openAIOmitsUnsetOptionKeys() async {
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, request(GenerationOptions()))
        let body = decodedBody(transport)
        #expect(!body.keys.contains("temperature"))
        #expect(!body.keys.contains("max_tokens"))
        #expect(!body.keys.contains("top_p"))
    }

    // MARK: Assertion 6 - Anthropic omits unset sampling knobs but keeps the required field.

    @Test func anthropicOmitsUnsetSamplingKeysKeepsMaxTokens() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, request(GenerationOptions()))
        let body = decodedBody(transport)
        #expect(!body.keys.contains("temperature"))
        #expect(!body.keys.contains("top_p"))
        #expect(body.keys.contains("max_tokens"))
    }

    // MARK: Assertion 7 - a single set knob emits only itself (the discriminator).

    @Test func partialOptionsEmitOnlySetKnobs() async {
        let partial = GenerationOptions(temperature: 0.3)

        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oai, request(partial))
        let oaiBody = decodedBody(oaiTransport)
        #expect(oaiBody["temperature"] as? Double == 0.3)
        #expect(!oaiBody.keys.contains("top_p"))
        #expect(!oaiBody.keys.contains("max_tokens"))

        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anth, request(partial))
        let anthBody = decodedBody(anthTransport)
        #expect(anthBody["temperature"] as? Double == 0.3)
        #expect(anthBody["max_tokens"] as? Int == 4096)
        #expect(!anthBody.keys.contains("top_p"))
    }
}
