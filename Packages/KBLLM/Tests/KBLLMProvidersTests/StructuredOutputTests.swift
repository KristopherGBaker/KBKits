import Foundation
import KBLLM
import KBLLMOpenAI
import KBLLMRuntime
import Testing
@testable import KBLLMAnthropic

// The structured-output suite (unit 6). Every test is offline: it replays recorded provider
// bytes through the same `RecordingTransport` the rest of the provider suite uses, so a
// structured request's wire body and neutral events are pinned without a socket. The Anthropic
// module is imported `@testable` for ONE reason: to key a fixture's structured-tool block name to
// `AnthropicModel.structuredToolName`, so the fixture and the adapter cannot drift apart.
@Suite struct StructuredOutputTests {
    private func bodyString(_ transport: RecordingTransport) -> String {
        String(bytes: transport.requests.get().first?.body ?? Data(), encoding: .utf8) ?? ""
    }

    private func bodyObject(_ transport: RecordingTransport) -> [String: Any] {
        let data = transport.requests.get().first?.body ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// The four distinct node descriptions the nested schema carries, which a translation that
    /// drops any level would lose.
    private let allDescriptions = ["a vocabulary card", "the list of readings", "one reading", "the reading value"]

    // MARK: Assertion 1 - OpenAI request carries the json_schema, fully translated.

    @Test func openAIRequestCarriesJSONSchema() async {
        let transcript = Fixtures.openAIStructured(contentChunks: [structuredConformingDocument])
        let (oai, transport) = makeOpenAI(.replay(transcript))
        _ = await collect(oai, structuredRequest)
        let body = bodyString(transport)
        #expect(body.contains("response_format"))
        #expect(body.contains(#""type":"json_schema""#))
        #expect(body.contains(#""strict":true"#))
        #expect(body.contains(#""name""#))
        #expect(body.contains(#""schema""#))
        // Nested property names survive.
        #expect(body.contains(#""title""#))
        #expect(body.contains(#""readings""#))
        #expect(body.contains(#""value""#))
        // BOTH required lists survive (outer object and inner reading object).
        #expect(body.contains(#""required":["title","readings"]"#))
        #expect(body.contains(#""required":["value"]"#))
        // Every level's description survives.
        for description in allDescriptions {
            #expect(body.contains(description), "OpenAI schema dropped description \"\(description)\"")
        }
        #expect(body.contains("the card title"))
    }

    // MARK: Assertion 2 - Anthropic's legacy route carries the strict tool, unforced, and schema.
    // (`makeAnthropic` defaults to a pre-4.5 model; current models are covered by
    // `CurrentModelStructuredTests`.)

    @Test func anthropicLegacyRequestCarriesStrictToolAndSchema() async {
        let transcript = Fixtures.anthropicStructured(
            toolName: AnthropicModel.structuredToolName,
            fragments: [structuredConformingDocument]
        )
        let (anth, transport) = makeAnthropic(.replay(transcript))
        _ = await collect(anth, structuredRequest)
        let body = bodyString(transport)
        #expect(body.contains("input_schema"))
        #expect(body.contains(#""title""#))
        #expect(body.contains(#""readings""#))
        #expect(body.contains(#""value""#))
        #expect(body.contains(#""required":["title","readings"]"#))
        #expect(body.contains(#""required":["value"]"#))
        for description in allDescriptions {
            #expect(body.contains(description), "Anthropic schema dropped description \"\(description)\"")
        }

        // The tool is offered (`auto`), never forced: forced choice is a 400 on current models.
        let object = bodyObject(transport)
        let toolChoice = object["tool_choice"] as? [String: Any]
        #expect(toolChoice?["type"] as? String == "auto")
        #expect(toolChoice?["name"] == nil)
        let tools = object["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        #expect(tools?.first?["name"] as? String == AnthropicModel.structuredToolName)
        #expect(tools?.first?["strict"] as? Bool == true)
    }

    // MARK: Assertion 4 - Anthropic tool_use becomes content, split across two frames.

    @Test func anthropicStructuredBecomesContentNeverToolCall() async {
        let transcript = Fixtures.anthropicStructured(
            toolName: AnthropicModel.structuredToolName,
            fragments: [structuredConformingFirstHalf, structuredConformingSecondHalf]
        )
        let result = await collect(makeAnthropic(.replay(transcript)).0, structuredRequest)
        #expect(result.error == nil)
        #expect(toolCallRecords(result.events).isEmpty)
        let content = result.events.reduce(into: "") { accumulated, event in
            if case .contentDelta(let delta) = event { accumulated += delta }
        }
        #expect(content == structuredConformingDocument)
        #expect(result.events.last == .completed(.stop))
    }

    // MARK: Assertion 5 - the structured answer never becomes unknownTool through AgentSession.

    @Test func anthropicStructuredThroughAgentSessionYieldsNoUnknownTool() async throws {
        let transcript = Fixtures.anthropicStructured(
            toolName: AnthropicModel.structuredToolName,
            fragments: [structuredConformingFirstHalf, structuredConformingSecondHalf]
        )
        let session = AgentSession(model: makeAnthropic(.replay(transcript)).0)
        let result = try await session.run(structuredRequest)
        #expect(result.content == structuredConformingDocument)
        // No tool was registered, and the structured answer must not have been dispatched.
        for toolResult in result.toolResults {
            #expect(!(toolResult.text ?? "").contains("unknownTool"))
        }
        #expect(result.toolCalls.isEmpty)
    }

    // MARK: Assertion 6 - OpenAI structured content streams as deltas.

    @Test func openAIStructuredContentStreamsAsDeltas() async {
        let transcript = Fixtures.openAIStructured(
            contentChunks: [structuredConformingFirstHalf, structuredConformingSecondHalf]
        )
        let result = await collect(makeOpenAI(.replay(transcript)).0, structuredRequest)
        #expect(result.error == nil)
        #expect(toolCallRecords(result.events).isEmpty)
        let content = result.events.reduce(into: "") { accumulated, event in
            if case .contentDelta(let delta) = event { accumulated += delta }
        }
        #expect(content == structuredConformingDocument)
        #expect(result.events.last == .completed(.stop))
    }

    // MARK: Assertion 7 - failure not fallback, HTTP adapters, both negative kinds each.

    @Test func openAIRejectsMalformedStructured() async {
        await expectHTTPStructuredViolation(
            openAI: Fixtures.openAIStructured(contentChunks: [structuredMalformedDocument]),
            received: structuredMalformedDocument
        )
    }

    @Test func openAIRejectsNonconformingStructured() async {
        await expectHTTPStructuredViolation(
            openAI: Fixtures.openAIStructured(contentChunks: [structuredNonconformingDocument]),
            received: structuredNonconformingDocument
        )
    }

    @Test func anthropicRejectsMalformedStructured() async {
        await expectHTTPStructuredViolation(
            anthropic: Fixtures.anthropicStructured(
                toolName: AnthropicModel.structuredToolName, fragments: [structuredMalformedDocument]
            ),
            received: structuredMalformedDocument
        )
    }

    @Test func anthropicRejectsNonconformingStructured() async {
        await expectHTTPStructuredViolation(
            anthropic: Fixtures.anthropicStructured(
                toolName: AnthropicModel.structuredToolName, fragments: [structuredNonconformingDocument]
            ),
            received: structuredNonconformingDocument
        )
    }

    @Test func anthropicMissingForcedToolErrors() async {
        let answer = "I cannot produce that."
        await expectHTTPStructuredViolation(
            anthropic: Fixtures.anthropicStructuredPlainText(answer),
            received: answer
        )
    }

    /// Drive a structured request and require it to end in `.schemaViolation` carrying what
    /// arrived, with no `.completed(.stop)` in the drained stream. One of the two transcripts is
    /// supplied per call, choosing the adapter under test.
    private func expectHTTPStructuredViolation(
        openAI: [UInt8]? = nil,
        anthropic: [UInt8]? = nil,
        received expected: String
    ) async {
        let model: any LanguageModel = openAI.map { makeOpenAI(.replay($0)).0 }
            ?? makeAnthropic(.replay(anthropic ?? [])).0
        let result = await collect(model, structuredRequest)
        guard case .schemaViolation(_, let received) = result.error else {
            Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
            return
        }
        #expect(received == expected)
        #expect(!result.events.contains(.completed(.stop)))
    }

    // MARK: Assertion 9 - cross-adapter equivalence for a structured answer.

    @Test func bothAdaptersEmitIdenticalStructuredEvents() async {
        let oaiResult = await collect(
            makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [structuredConformingDocument]))).0,
            structuredRequest
        )
        let anthResult = await collect(
            makeAnthropic(.replay(Fixtures.anthropicStructured(
                toolName: AnthropicModel.structuredToolName, fragments: [structuredConformingDocument]
            ))).0,
            structuredRequest
        )
        let expected: [ModelEvent] = [.contentDelta(structuredConformingDocument), .completed(.stop)]
        #expect(oaiResult.error == nil)
        #expect(anthResult.error == nil)
        #expect(oaiResult.events == expected)
        #expect(anthResult.events == expected)
        #expect(oaiResult.events == anthResult.events)
        #expect(toolCallRecords(oaiResult.events).isEmpty)
        #expect(toolCallRecords(anthResult.events).isEmpty)
    }

    // MARK: Assertion 11 - responseSchema + tools rejected pre-dispatch by both HTTP adapters.

    @Test func schemaPlusToolsRejectedByHTTPAdapters() async {
        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let oaiResult = await collect(oai, structuredPlusToolsRequest)
        expectSchemaPlusToolsRejection(oaiResult.error)
        #expect(oaiTransport.openCount.get() == 0)
        #expect(oaiTransport.sendInvoked.get() == false)

        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        let anthResult = await collect(anth, structuredPlusToolsRequest)
        expectSchemaPlusToolsRejection(anthResult.error)
        #expect(anthTransport.openCount.get() == 0)
        #expect(anthTransport.sendInvoked.get() == false)
    }

    private func expectSchemaPlusToolsRejection(_ error: KBLLMError?) {
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
        let payload = field + " " + reason
        #expect(payload.contains("responseSchema"))
        #expect(payload.contains("tools"))
    }
}

/// What OpenAI's `strict: true` actually demands of a schema. Both rules below are hard 400s
/// from the real API and are ignored by LM Studio, which is why the structured path shipped
/// without them: every local verification passed.
@Suite struct StrictSchemaTests {
    /// A structured reply matching `nestedSchema`, so the transport has something to answer
    /// with on the paths that do dispatch.
    private static let reply = Fixtures.openAIStructured(
        contentChunks: [#"{"word":"x","detail":{"reading":"y"}}"#]
    )

    private func request(_ schema: JSONSchema) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "hi")], responseSchema: schema)
    }

    private func bodyString(_ transport: RecordingTransport) -> String {
        String(bytes: transport.requests.get().first?.body ?? Data(), encoding: .utf8) ?? ""
    }

    private var nestedSchema: JSONSchema {
        .object(
            properties: [
                "word": .string(description: nil),
                "detail": .object(
                    properties: ["reading": .string(description: nil)],
                    required: ["reading"],
                    description: nil
                )
            ],
            required: ["word", "detail"],
            description: nil
        )
    }

    @Test func everyObjectCarriesAdditionalPropertiesFalse() async {
        let (model, transport) = makeOpenAI(.replay(Self.reply))
        _ = await collect(model, request(nestedSchema))

        let body = bodyString(transport)
        // Twice: the root object and the nested one. A root-only emission is the common
        // half-fix and still fails against the real API.
        #expect(body.components(separatedBy: "\"additionalProperties\":false").count - 1 == 2)
    }

    /// Strict mode cannot say "may be absent", but it can say "may be null", which is the
    /// same statement. The caller's optionality is preserved by translation rather than
    /// rejected or silently promoted to mandatory.
    @Test func anOptionalPropertyIsSentAsNullableAndRequired() async {
        let partial = JSONSchema.object(
            properties: ["word": .string(description: nil), "note": .string(description: nil)],
            required: ["word"],
            description: nil
        )
        let (model, transport) = makeOpenAI(.replay(Self.reply))
        let result = await collect(model, request(partial))

        #expect(result.error == nil)
        let body = bodyString(transport)
        // The optional property becomes a union with null...
        #expect(body.contains(#""type":["string","null"]"#))
        // ...and joins `required`, which strict mode demands hold every property.
        #expect(body.contains(#""required":["word","note"]"#))
    }

    @Test func aRequiredPropertyIsNotMadeNullable() async {
        let (model, transport) = makeOpenAI(.replay(Self.reply))
        _ = await collect(model, request(nestedSchema))

        let body = bodyString(transport)
        // Nothing was promoted, so no union type appears anywhere.
        #expect(!body.contains(#""null""#))
    }

    @Test func anOptionalPropertyNestedDeeperIsAlsoTranslated() async {
        let nested = JSONSchema.object(
            properties: [
                "outer": .object(
                    properties: ["a": .string(description: nil), "b": .string(description: nil)],
                    required: ["a"],
                    description: nil
                )
            ],
            required: ["outer"],
            description: nil
        )
        // A reply matching THIS schema, so a conformance failure cannot be mistaken for the
        // request-shaping behaviour under test.
        let reply = Fixtures.openAIStructured(contentChunks: [#"{"outer":{"a":"1","b":"2"}}"#])
        let (model, transport) = makeOpenAI(.replay(reply))
        let result = await collect(model, request(nested))

        #expect(result.error == nil)
        // Translating only the root is the half-fix that still fails against the real API.
        #expect(bodyString(transport).contains(#""required":["a","b"]"#))
    }

    /// An array of objects is the shape a card generator actually sends, and the objects
    /// inside it need the same treatment.
    @Test func objectsInsideAnArrayAreTranslated() async {
        let arrayOfCards = JSONSchema.array(
            items: .object(
                properties: ["lemma": .string(description: nil), "reading": .string(description: nil)],
                required: ["lemma"],
                description: nil
            ),
            description: nil
        )
        let reply = Fixtures.openAIStructured(contentChunks: [#"[{"lemma":"cat","reading":null}]"#])
        let (model, transport) = makeOpenAI(.replay(reply))
        let result = await collect(model, request(arrayOfCards))

        // The null the translation asked for validates against the schema as the caller wrote
        // it: absent and null are the same statement about an optional property.
        #expect(result.error == nil)
        let body = bodyString(transport)
        #expect(body.contains(#""type":["string","null"]"#))
        #expect(body.contains(#""required":["lemma","reading"]"#))
    }

    @Test func aFullyRequiredSchemaIsAccepted() async {
        let (model, transport) = makeOpenAI(.replay(Self.reply))
        let result = await collect(model, request(nestedSchema))

        #expect(result.error == nil)
        #expect(transport.requests.get().count == 1)
    }

    /// Tool parameters are not sent with `strict`, so the optional-property rule does not
    /// apply to them and a partially-required tool schema still dispatches.
    @Test func toolSchemasAreNotSubjectToTheStrictRule() async {
        let partialTool = ToolDefinition(
            name: "lookup",
            description: "d",
            parameters: .object(
                properties: ["city": .string(description: nil), "unit": .string(description: nil)],
                required: ["city"],
                description: nil
            )
        )
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let result = await collect(
            model,
            ModelRequest(messages: [Message(role: .user, text: "hi")], tools: [partialTool])
        )

        #expect(result.error == nil)
        #expect(transport.requests.get().count == 1)
    }
}
