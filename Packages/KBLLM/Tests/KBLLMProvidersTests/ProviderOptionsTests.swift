import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

/// The two provider-specific knobs that exist because the providers themselves differ:
/// Anthropic's prompt cache, and the extra headers an OpenAI-compatible host may require.
/// Neither belongs on the neutral `ModelRequest`, so both are proved at the wire.
@Suite struct ProviderOptionsTests {
    private func bodyString(_ transport: RecordingTransport) -> String {
        String(bytes: transport.requests.get().first?.body ?? Data(), encoding: .utf8) ?? ""
    }

    @Test func anthropicSendsAPlainSystemStringUnlessCachingIsAskedFor() async {
        let transport = RecordingTransport(.replay(Fixtures.anthropicWeather))
        let model = AnthropicModel(
            model: "claude-x",
            credentialKey: "K",
            transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, systemRequest)

        let body = bodyString(transport)
        #expect(body.contains("\"system\":\"You are terse.\""))
        #expect(!body.contains("cache_control"))
    }

    @Test func anthropicMarksTheSystemPromptForItsCacheWhenAsked() async {
        let transport = RecordingTransport(.replay(Fixtures.anthropicWeather))
        let model = AnthropicModel(
            model: "claude-x",
            credentialKey: "K",
            promptCaching: .systemPrompt,
            transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, systemRequest)

        // Block form, because that is the only shape that can carry cache_control, and the
        // text has to survive the change of shape intact.
        let body = bodyString(transport)
        #expect(body.contains("\"type\":\"ephemeral\""))
        #expect(body.contains("You are terse."))
        #expect(body.contains("\"type\":\"text\""))
    }

    @Test func openAISendsCallerSuppliedHeaders() async {
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        let model = OpenAIModel(
            model: "gpt-x",
            credentialKey: "K",
            baseURL: "https://openrouter.ai/api/v1",
            extraHeaders: ["HTTP-Referer": "https://example.test", "X-Title": "Aside"],
            transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, weatherRequest)

        let headers = transport.requests.get().first?.headers ?? [:]
        #expect(headers["HTTP-Referer"] == "https://example.test")
        #expect(headers["X-Title"] == "Aside")
    }

    /// A caller cannot clobber the credential it just supplied, whatever it passes.
    @Test func callerHeadersNeverOverrideTheAdaptersOwn() async {
        let transport = RecordingTransport(.replay(Fixtures.openAIWeather))
        let model = OpenAIModel(
            model: "gpt-x",
            credentialKey: "K",
            extraHeaders: ["Authorization": "Bearer attacker", "content-type": "text/plain"],
            transport: transport,
            credentials: FakeCredentialStore(response: .secret(sentinelSecret))
        )
        _ = await collect(model, weatherRequest)

        let headers = transport.requests.get().first?.headers ?? [:]
        #expect(headers["Authorization"] == "Bearer \(sentinelSecret)")
        #expect(headers["content-type"] == "application/json")
    }
}
