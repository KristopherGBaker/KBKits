import Foundation
import KBLLM
import KBLLMOpenAI
import Testing

func makeResponses(
    _ behavior: RecordingTransport.Behavior,
    credentials: FakeCredentialStore = FakeCredentialStore(response: .secret(sentinelSecret)),
    reasoningEffort: OpenAIResponsesModel.ReasoningEffort? = nil,
    reasoningSummary: OpenAIResponsesModel.ReasoningSummary? = nil,
    promptCacheKey: String? = nil
) -> (OpenAIResponsesModel, RecordingTransport) {
    let transport = RecordingTransport(behavior)
    let model = OpenAIResponsesModel(
        model: "gpt-6-astra", credentialKey: "OPENAI_API_KEY", reasoningEffort: reasoningEffort,
        reasoningSummary: reasoningSummary, promptCacheKey: promptCacheKey,
        transport: transport, credentials: credentials
    )
    return (model, transport)
}

/// The events `OpenAIResponsesModel` maps from a Responses stream: text, reasoning summaries, the encrypted reasoning
/// item, function calls, usage and every ending. Offline: every response is replayed bytes.
@Suite struct OpenAIResponsesStreamTests {
    static let usage = TokenUsage(inputTokens: 120, outputTokens: 12, cacheReadTokens: 100, cacheWriteTokens: 8)

    @Test func textStreamsToTheResponsesEndpoint() async throws {
        let (model, transport) = makeResponses(.replay(Fixtures.responsesText))
        let result = await collect(model, ModelRequest(messages: [Message(role: .user, text: "Weather?")]))
        #expect(result.error == nil)
        #expect(result.events == [
            .contentDelta("The weather in Paris "), .contentDelta("is sunny."), .usage(Self.usage), .completed(.stop)
        ])
        let spec = try #require(transport.requests.get().first)
        #expect(spec.url == "https://api.openai.com/v1/responses")
        #expect(spec.headers["Authorization"] == "Bearer \(sentinelSecret)")
        #expect(transport.sendInvoked.get() == false)
    }

    @Test func aToolCallIsWholeAfterItsSplitArgumentsWithItsReasoning() async throws {
        let (model, _) = makeResponses(.replay(Fixtures.responsesToolCall))
        let result = await collect(model, weatherRequest)
        #expect(result.error == nil)
        let call = ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8))
        #expect(result.events == [
            .reasoningDelta("Check the "), .reasoningDelta("weather."), .reasoningDelta("\n\n"),
            .reasoningDelta("Then answer."), .reasoningBlock(Fixtures.responsesReasoningBlock),
            .toolCall(call), .usage(Self.usage), .completed(.toolCalls)
        ])
        let response = try await model.complete(weatherRequest)
        #expect(response.reasoning == "Check the weather.\n\nThen answer.")
        #expect(response.toolCalls == [call])
    }

    @Test func argumentsComeFromTheDeltasWhenTheFinishedItemLacksThem() async throws {
        let (model, _) = makeResponses(.replay(Fixtures.responsesToolCallFromDeltas))
        let records = toolCallRecords(await collect(model, weatherRequest).events)
        #expect(records.count == 1)
        #expect(records.first.flatMap(decodedArguments) == ["city": "Paris"])
    }

    @Test func aCallWithNoArgumentsCarriesAnEmptyObject() async {
        let (model, _) = makeResponses(.replay(Fixtures.responsesNoArgumentCall))
        let result = await collect(model, weatherRequest)
        #expect(toolCallRecords(result.events) == [
            ToolCallRecord(id: "call_2", name: "get_time", arguments: Data("{}".utf8))
        ])
        #expect(result.events.last == .completed(.toolCalls))
    }

    @Test func anIncompleteResponseAtTheOutputLimitEndsOnLength() async {
        let (model, _) = makeResponses(.replay(Fixtures.responsesIncomplete))
        let result = await collect(model, weatherRequest)
        #expect(result.error == nil)
        #expect(result.events == [.contentDelta("The weather"), .usage(Self.usage), .completed(.length)])
    }

    @Test func aFailedResponseAndAnErrorEventAreTypedStatuses() async {
        let (failed, _) = makeResponses(.replay(Fixtures.responsesFailed))
        #expect(await collect(failed, weatherRequest).error == .httpStatus(
            code: 500, message: "server_error: The model failed to generate a response."
        ))
        let (limited, _) = makeResponses(.replay(Fixtures.responsesError))
        #expect(
            await collect(limited, weatherRequest).error
                == .httpStatus(code: 429, message: "rate_limit_exceeded: Slow down")
        )
    }

    @Test func failuresBeforeAndAroundTheStreamAreNormalized() async {
        let (missing, missingTransport) = makeResponses(
            .replay(Fixtures.responsesText), credentials: FakeCredentialStore(response: .missing)
        )
        #expect(await collect(missing, weatherRequest).error == .missingCredential(key: "OPENAI_API_KEY"))
        #expect(missingTransport.openCount.get() == 0)

        let (foreign, _) = makeResponses(.foreign(detail: "refused with \(sentinelSecret)"))
        let error = await collect(foreign, weatherRequest).error
        guard case .transport(let url, let underlying) = error else {
            Issue.record("expected .transport, got \(String(describing: error))")
            return
        }
        #expect(url == "https://api.openai.com/v1/responses")
        #expect(!underlying.contains(sentinelSecret))

        // A 200 whose body is not an event stream is a decoding failure, not an empty answer.
        let (empty, _) = makeResponses(.replay(Fixtures.bytes(#"{"error":{"message":"nope"}}"#)))
        guard case .decoding = await collect(empty, weatherRequest).error else {
            Issue.record("expected .decoding")
            return
        }
    }

    @Test func aStructuredAnswerIsValidatedBeforeItsTerminal() async {
        let document = structuredConformingDocument.replacingOccurrences(of: "\"", with: "\\\"")
        let stream = Fixtures.frame(
            event: "response.output_text.delta",
            data: #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"\#(document)"}"#
        ) + Fixtures.frame(
            event: "response.completed",
            data: #"{"type":"response.completed","response":{"status":"completed"}}"#
        )
        let (model, _) = makeResponses(.replay(Fixtures.bytes(stream)))
        let result = await collect(model, structuredRequest)
        #expect(result.error == nil)
        #expect(result.events == [.contentDelta(structuredConformingDocument), .completed(.stop)])
    }
}
