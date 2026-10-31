import Foundation
import KBLLM
import KBLLMOpenAI
import Testing

@Suite struct RequestBodyTests {
    private func bodyString(_ transport: RecordingTransport) -> String {
        let body = transport.requests.get().first?.body ?? Data()
        return String(bytes: body, encoding: .utf8) ?? ""
    }

    // MARK: Assertion 12 - Anthropic envelope, tool, and history translation.

    @Test func anthropicRequestBodyCarriesEnvelopeToolsAndHistory() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather), model: "claude-x")
        _ = await collect(anth, weatherRequest)
        let spec = transport.requests.get().first
        #expect(spec?.method == .post)
        #expect(spec?.url == "https://api.anthropic.com/v1/messages")
        #expect(spec?.headers["x-api-key"] == sentinelSecret)
        #expect(spec?.headers["anthropic-version"] != nil)

        let body = bodyString(transport)
        #expect(body.contains("\"model\":\"claude-x\""))
        #expect(body.contains("What is the weather in Paris?"))
        // Tool translation.
        #expect(body.contains("\"name\":\"get_weather\""))
        #expect(body.contains("Look up the weather for a city"))
        #expect(body.contains("input_schema"))
        #expect(body.contains("\"city\""))
        #expect(body.contains("\"required\":[\"city\"]"))

        // History translation.
        let (anthHistory, historyTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(anthHistory, historyRequest)
        let historyBody = bodyString(historyTransport)
        #expect(historyBody.contains("tool_use"))
        #expect(historyBody.contains("\"id\":\"call_1\""))
        #expect(historyBody.contains("\"name\":\"get_weather\""))
        #expect(historyBody.contains("tool_result"))
        #expect(historyBody.contains("\"tool_use_id\":\"call_1\""))
    }

    /// Some reasoning models refuse FUNCTION TOOLS on Chat Completions unless reasoning is off,
    /// answering a tool-using request with "use /v1/responses or set reasoning_effort to 'none'".
    /// This is the knob that makes such a model usable, and it must reach the wire.
    @Test func openAICarriesReasoningEffortOnlyWhenAsked() async {
        let (unset, unsetTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(unset, weatherRequest)
        #expect(!bodyString(unsetTransport).contains("reasoning_effort"))

        let effortOff = OpenAIModel.ReasoningEffort.none
        let (off, offTransport) = makeOpenAI(.replay(Fixtures.openAIWeather), reasoningEffort: effortOff)
        _ = await collect(off, weatherRequest)
        let body = bodyString(offTransport)
        #expect(body.contains("\"reasoning_effort\":\"none\""))
        // The tools must still be there: sending one without the other fixes nothing.
        #expect(body.contains("\"name\":\"get_weather\""))
    }

    /// A tool with no parameters is the common case for "tell me the current state", and
    /// Anthropic sends no argument deltas for one. Joining nothing gave an empty string, which is
    /// not valid JSON, so the loop refused to dispatch a call whose arguments were never in
    /// doubt: "tool call arguments must be valid JSON before dispatch".
    @Test func anthropicToolWithNoArgumentsCarriesAnEmptyObject() async {
        let (anth, _) = makeAnthropic(.replay(Fixtures.anthropicNoArgumentTool))
        let result = await collect(anth, weatherRequest)
        let call = toolCallRecords(result.events).first
        #expect(call?.name == "today_summary")
        #expect(String(data: call?.arguments ?? Data(), encoding: .utf8) == "{}")
        // And it must actually decode, which is the thing that was failing.
        #expect((try? JSONSerialization.jsonObject(with: call?.arguments ?? Data())) != nil)
    }

    // MARK: Assertion 12 - OpenAI envelope, tool, and history translation.

    @Test func openAIRequestBodyCarriesEnvelopeToolsAndHistory() async {
        let (oai, transport) = makeOpenAI(.replay(Fixtures.openAIWeather), model: "gpt-x")
        _ = await collect(oai, weatherRequest)
        let spec = transport.requests.get().first
        #expect(spec?.method == .post)
        #expect(spec?.url == "https://api.openai.com/v1/chat/completions")
        #expect(spec?.headers["Authorization"] == "Bearer \(sentinelSecret)")

        let body = bodyString(transport)
        #expect(body.contains("\"model\":\"gpt-x\""))
        #expect(body.contains("\"stream\":true"))
        #expect(body.contains("What is the weather in Paris?"))
        // Tool translation.
        #expect(body.contains("\"type\":\"function\""))
        #expect(body.contains("\"name\":\"get_weather\""))
        #expect(body.contains("Look up the weather for a city"))
        #expect(body.contains("parameters"))
        #expect(body.contains("\"city\""))
        #expect(body.contains("\"required\":[\"city\"]"))

        // History translation.
        let (oaiHistory, historyTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(oaiHistory, historyRequest)
        let historyBody = bodyString(historyTransport)
        #expect(historyBody.contains("tool_calls"))
        #expect(historyBody.contains("\"id\":\"call_1\""))
        #expect(historyBody.contains("\"name\":\"get_weather\""))
        #expect(historyBody.contains("\"role\":\"tool\""))
        #expect(historyBody.contains("\"tool_call_id\":\"call_1\""))
    }
}
