import Foundation
import KBLLM
import Testing

@Suite struct EquivalenceTests {
    // MARK: Assertion 2 - usable as LanguageModel, driven through the byte seam only.

    @Test func adaptersDriveTheExchangeThroughTheByteSeamOnly() async {
        let (anthAdapter, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        let anth: any LanguageModel = anthAdapter
        let anthResult = await collect(anth, weatherRequest)
        #expect(anthResult.error == nil)
        #expect(anthResult.events == expectedWeatherEvents)
        #expect(anthTransport.openCount.get() == 1)
        #expect(anthTransport.sendInvoked.get() == false)

        let (oaiAdapter, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let oai: any LanguageModel = oaiAdapter
        let oaiResult = await collect(oai, weatherRequest)
        #expect(oaiResult.error == nil)
        #expect(oaiResult.events == expectedWeatherEvents)
        #expect(oaiTransport.openCount.get() == 1)
        #expect(oaiTransport.sendInvoked.get() == false)
    }

    // MARK: Assertion 4(a) - cross-provider equivalence.

    @Test func bothProvidersEmitIdenticalNeutralEvents() async {
        let anthResult = await collect(makeAnthropic(.replay(Fixtures.anthropicWeather)).0, weatherRequest)
        let oaiResult = await collect(makeOpenAI(.replay(Fixtures.openAIWeather)).0, weatherRequest)

        #expect(anthResult.error == nil)
        #expect(oaiResult.error == nil)
        #expect(anthResult.events == expectedWeatherEvents)
        #expect(oaiResult.events == expectedWeatherEvents)
        #expect(anthResult.events == oaiResult.events)

        // The tool-call arguments decode to the same neutral value from both providers.
        let anthCall = toolCallRecords(anthResult.events).first
        let oaiCall = toolCallRecords(oaiResult.events).first
        #expect(anthCall.map(decodedArguments) == ["city": "Paris"])
        #expect(oaiCall.map(decodedArguments) == ["city": "Paris"])
        #expect(anthCall?.id == "call_1")
        #expect(oaiCall?.id == "call_1")
    }

    // MARK: Assertion 4(b) - each transcript is recognisably its own provider.

    @Test func transcriptsSpeakDistinctWireProtocols() {
        let anthropic = Fixtures.anthropicWeatherText
        #expect(anthropic.contains("event: content_block_delta"))
        #expect(anthropic.contains("input_json_delta"))
        #expect(anthropic.contains("message_delta"))
        #expect(anthropic.contains("stop_reason"))

        let openAI = Fixtures.openAIWeatherText
        #expect(openAI.contains("\"choices\""))
        #expect(openAI.contains("tool_calls"))
        #expect(openAI.contains("\"function\""))
        #expect(openAI.contains("arguments"))
        #expect(openAI.contains("finish_reason"))

        // Neither is the other's encoding relabeled.
        #expect(!anthropic.contains("\"choices\""))
        #expect(!anthropic.contains("finish_reason"))
        #expect(!openAI.contains("content_block_delta"))
        #expect(!openAI.contains("input_json_delta"))
    }

    // MARK: Assertion 4(c) - the cross-feed discriminator.

    @Test func crossFedTranscriptsDoNotProduceTheSuccessArray() async {
        // Anthropic adapter fed the OpenAI transcript.
        let anthWrong = await collect(makeAnthropic(.replay(Fixtures.openAIWeather)).0, weatherRequest)
        #expect(!isWeatherSuccess(anthWrong))
        #expect(anthWrong.events != expectedWeatherEvents)

        // OpenAI adapter fed the Anthropic transcript.
        let oaiWrong = await collect(makeOpenAI(.replay(Fixtures.anthropicWeather)).0, weatherRequest)
        #expect(!isWeatherSuccess(oaiWrong))
        #expect(oaiWrong.events != expectedWeatherEvents)
    }

    // MARK: Assertion 5 - split JSON fragments accumulate into one tool call.

    @Test func splitJSONFragmentsAccumulateIntoOneToolCall() async {
        let anthResult = await collect(makeAnthropic(.replay(Fixtures.anthropicSplitToolCall)).0, weatherRequest)
        let oaiResult = await collect(makeOpenAI(.replay(Fixtures.openAISplitToolCall)).0, weatherRequest)

        for result in [anthResult, oaiResult] {
            #expect(result.error == nil)
            let calls = toolCallRecords(result.events)
            #expect(calls.count == 1)
            #expect(calls.first.map(decodedArguments) == ["city": "Paris"])
        }
    }

    // MARK: Assertion 6 - interleaved parallel tool calls stay distinct (OpenAI).

    @Test func interleavedParallelToolCallsStayDistinct() async {
        let result = await collect(makeOpenAI(.replay(Fixtures.openAIParallelToolCalls)).0, weatherRequest)
        #expect(result.error == nil)
        let calls = toolCallRecords(result.events)
        #expect(calls.count == 2)
        #expect(calls.first?.id == "call_a")
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first.map(decodedArguments) == ["city": "Paris"])
        #expect(calls.last?.id == "call_b")
        #expect(calls.last?.name == "get_time")
        #expect(calls.last.map(decodedArguments) == ["zone": "CET"])
    }

    // MARK: Assertion 7 - unterminated trailing frame is discarded.

    @Test func unterminatedTrailingFrameContributesNothing() async {
        let anthFull = await collect(makeAnthropic(.replay(Fixtures.anthropicWeather)).0, weatherRequest)
        let anthPartial = await collect(
            makeAnthropic(.replay(Fixtures.anthropicWeatherWithTrailingPartial)).0,
            weatherRequest
        )
        #expect(anthPartial.error == nil)
        #expect(anthPartial.events == anthFull.events)
        #expect(!anthPartial.events.contains(.contentDelta("LEAKED")))

        let oaiFull = await collect(makeOpenAI(.replay(Fixtures.openAIWeather)).0, weatherRequest)
        let oaiPartial = await collect(
            makeOpenAI(.replay(Fixtures.openAIWeatherWithTrailingPartial)).0,
            weatherRequest
        )
        #expect(oaiPartial.error == nil)
        #expect(oaiPartial.events == oaiFull.events)
        #expect(!oaiPartial.events.contains(.contentDelta("LEAKED")))
    }
}
