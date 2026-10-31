import Foundation
import KBLLM
import KBLLMOpenAI
import Testing
@testable import KBLLMAnthropic

// A string's `choices` on the wire, offline: each test reads back the request body the adapter
// wrote, so the assertions are about what a provider would receive. Then the answer side: an
// unlisted value is a typed `.schemaViolation` on both adapters, and an unsendable list is
// refused before the transport opens.
@Suite struct ChoicesProviderTests {
    static let labels = ["personalClaim", "general", "instruction"]

    /// A required label, an OPTIONAL tone (so OpenAI's nullable translation meets a choice), and
    /// array items carrying their own choice.
    static let claimSchema: JSONSchema = .object(
        properties: [
            "label": .string(description: "the claim kind", choices: labels),
            "tone": .string(description: nil, choices: ["calm", "urgent"]),
            "spans": .array(
                items: .object(
                    properties: ["kind": .string(description: nil, choices: ["name", "place"])],
                    required: ["kind"],
                    description: nil
                ),
                description: nil
            )
        ],
        required: ["label", "spans"],
        description: "a classified claim"
    )

    static let plainSchema: JSONSchema = .object(
        properties: ["label": .string(description: "the claim kind")],
        required: ["label"],
        description: nil
    )

    static let conforming = #"{"label":"general","tone":null,"spans":[{"kind":"name"}]}"#
    static let unlistedLabel = #"{"label":"opinion","tone":null,"spans":[]}"#
    static let unlistedItem = #"{"label":"general","tone":null,"spans":[{"kind":"date"}]}"#

    static let classifyTool = ToolDefinition(
        name: "classify",
        description: "Record the claim kind",
        parameters: .object(
            properties: ["label": .string(description: nil, choices: labels)],
            required: ["label"],
            description: nil
        )
    )

    private static func structured(_ schema: JSONSchema) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "Classify this claim.")], responseSchema: schema)
    }

    private static let toolRequest = ModelRequest(
        messages: [Message(role: .user, text: "Classify this claim.")],
        tools: [classifyTool]
    )

    private static func legacyReply(_ document: String) -> [UInt8] {
        Fixtures.anthropicStructured(toolName: AnthropicModel.structuredToolName, fragments: [document])
    }

    private func dig(_ object: Any?, _ path: String...) -> Any? {
        path.reduce(object) { node, key in
            if let index = Int(key) { return (node as? [Any]).flatMap { $0.indices.contains(index) ? $0[index] : nil } }
            return (node as? [String: Any])?[key]
        }
    }

    /// The `enum` of the `kind` choice inside the `spans` items of a serialized claim schema.
    private func spanKindEnum(_ schema: Any?) -> [String]? {
        dig(schema, "properties", "spans", "items", "properties", "kind", "enum") as? [String]
    }

    private func bodyString(_ transport: RecordingTransport) -> String {
        String(bytes: transport.requests.get().first?.body ?? Data(), encoding: .utf8) ?? ""
    }

    private func reparsed(_ node: Any?) throws -> JSONSchema {
        let data = try JSONSerialization.data(withJSONObject: try #require(node))
        return try JSONSchema.parse(String(bytes: data, encoding: .utf8) ?? "")
    }

    // MARK: Anthropic

    @Test func anthropicLegacyStrictToolCarriesTheEnum() async throws {
        let (model, transport) = makeAnthropic(.replay(Self.legacyReply(Self.conforming)))
        #expect(await collect(model, Self.structured(Self.claimSchema)).error == nil)
        let tool = try #require(requestBodies(transport).first.flatMap { dig($0, "tools", "0") })
        #expect(dig(tool, "strict") as? Bool == true)
        let schema = dig(tool, "input_schema")
        #expect(dig(schema, "properties", "label", "enum") as? [String] == Self.labels)
        #expect(dig(schema, "properties", "tone", "enum") as? [String] == ["calm", "urgent"])
        #expect(spanKindEnum(schema) == ["name", "place"])
        #expect(try reparsed(schema) == Self.claimSchema)
    }

    @Test(arguments: ["claude-sonnet-4-5", "claude-opus-4-6", "claude-sonnet-5-5"])
    func anthropicStructuredOutputsCarryTheEnumUndegraded(model: String) async throws {
        let reply = Fixtures.structuredOutputAnswer(model: model, document: Self.conforming)
        let (adapter, transport) = makeAnthropic(.replay(reply), model: model)
        #expect(await collect(adapter, Self.structured(Self.claimSchema)).error == nil)
        let body = try #require(requestBodies(transport).first)
        let schema = dig(body, "output_config", "format", "schema")
        #expect(dig(schema, "properties", "label", "enum") as? [String] == Self.labels)
        #expect(spanKindEnum(schema) == ["name", "place"])
        // Nothing moved into a description: the grammar takes string enums as written.
        #expect(dig(schema, "properties", "label", "description") as? String == "the claim kind")
        #expect(try reparsed(schema) == Self.claimSchema)
    }

    @Test func anthropicToolInputSchemaCarriesTheEnum() async throws {
        let (model, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(model, Self.toolRequest)
        let body = try #require(requestBodies(transport).first)
        let schema = dig(body, "tools", "0", "input_schema")
        #expect(dig(schema, "properties", "label", "enum") as? [String] == Self.labels)
        #expect(try reparsed(schema) == Self.classifyTool.parameters)
    }

    // MARK: OpenAI

    @Test func openAIStrictResponseFormatCarriesTheEnum() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [Self.conforming])))
        #expect(await collect(model, Self.structured(Self.claimSchema)).error == nil)
        let body = try #require(requestBodies(transport).first)
        let format = dig(body, "response_format", "json_schema")
        #expect(dig(format, "strict") as? Bool == true)
        let schema = dig(format, "schema")
        #expect(dig(schema, "properties", "label", "enum") as? [String] == Self.labels)
        #expect(dig(schema, "properties", "label", "type") as? String == "string")
        #expect(spanKindEnum(schema) == ["name", "place"])
        // The optional choice is nullable, and null is listed so strict mode can send it.
        #expect(dig(schema, "properties", "tone", "type") as? [String] == ["string", "null"])
        let tone = try #require(dig(schema, "properties", "tone", "enum") as? [Any])
        #expect(tone.count == 3)
        #expect(tone.prefix(2).compactMap { $0 as? String } == ["calm", "urgent"])
        #expect(tone.last is NSNull)
        #expect(bodyString(transport).contains(#""enum":["calm","urgent",null]"#))
        // That nullable list is wire output only: a choices list holds only strings, so the
        // parser refuses the `null` member rather than reading it back.
        do {
            _ = try reparsed(schema)
            Issue.record("expected the null enum member to be refused")
        } catch let error as KBLLMError {
            guard case .invalidRequest(let field, let reason) = error else {
                Issue.record("expected .invalidRequest, got \(error)")
                return
            }
            #expect(field == "root.tone")
            #expect(reason.contains("got null"))
        }
    }

    /// With every choice required there is no null to add, so the strict schema round-trips.
    @Test func openAIStrictSchemaWithRequiredChoicesRoundTrips() async throws {
        let required: JSONSchema = .object(
            properties: [
                "label": .string(description: "the claim kind", choices: Self.labels),
                "tone": .string(description: nil, choices: ["calm", "urgent"])
            ],
            required: ["label", "tone"],
            description: nil
        )
        let reply = Fixtures.openAIStructured(contentChunks: [#"{"label":"general","tone":"calm"}"#])
        let (model, transport) = makeOpenAI(.replay(reply))
        #expect(await collect(model, Self.structured(required)).error == nil)
        let body: [String: Any] = try #require(requestBodies(transport).first)
        let schema = dig(body, "response_format", "json_schema", "schema")
        #expect(dig(schema, "properties", "tone", "enum") as? [String] == ["calm", "urgent"])
        #expect(try reparsed(schema) == required)
    }

    @Test func openAIToolParametersCarryTheEnum() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(model, Self.toolRequest)
        let body = try #require(requestBodies(transport).first)
        let parameters = dig(body, "tools", "0", "function", "parameters")
        #expect(dig(parameters, "properties", "label", "enum") as? [String] == Self.labels)
        #expect(try reparsed(parameters) == Self.classifyTool.parameters)
    }

    // MARK: No choices, no key

    @Test func aSchemaWithoutChoicesSendsNoEnumOnEitherAdapter() async {
        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [#"{"label":"x"}"#])))
        #expect(await collect(oai, Self.structured(Self.plainSchema)).error == nil)
        #expect(!bodyString(oaiTransport).contains("enum"))

        let (legacy, legacyTransport) = makeAnthropic(.replay(Self.legacyReply(#"{"label":"x"}"#)))
        #expect(await collect(legacy, Self.structured(Self.plainSchema)).error == nil)
        #expect(!bodyString(legacyTransport).contains("enum"))

        let reply = Fixtures.structuredOutputAnswer(model: "claude-sonnet-5-5", document: #"{"label":"x"}"#)
        let (current, currentTransport) = makeAnthropic(.replay(reply), model: "claude-sonnet-5-5")
        #expect(await collect(current, Self.structured(Self.plainSchema)).error == nil)
        #expect(!bodyString(currentTransport).contains("enum"))
    }

    // MARK: Post-decode enforcement

    @Test(arguments: [(unlistedLabel, "root.label"), (unlistedItem, "root.spans[].kind")])
    func anUnlistedValueIsASchemaViolationOnEveryRoute(document: String, path: String) async {
        let structuredReply = Fixtures.structuredOutputAnswer(model: "claude-sonnet-5-5", document: document)
        let results = [
            await collect(makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [document]))).0,
                          Self.structured(Self.claimSchema)),
            await collect(makeAnthropic(.replay(Self.legacyReply(document))).0, Self.structured(Self.claimSchema)),
            await collect(makeAnthropic(.replay(structuredReply), model: "claude-sonnet-5-5").0,
                          Self.structured(Self.claimSchema))
        ]
        for result in results {
            guard case .schemaViolation(let expected, let received) = result.error else {
                Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
                continue
            }
            #expect(expected.contains(path))
            #expect(expected.contains("one of"))
            #expect(received == document)
            #expect(!result.events.contains(.completed(.stop)))
        }
    }

    // MARK: Refused before the transport opens

    @Test func unsendableChoicesAreRefusedWithoutOpeningTheTransport() async {
        let bad: JSONSchema = .object(
            properties: ["label": .string(description: nil, choices: ["a", "a"])],
            required: ["label"],
            description: nil
        )
        let badTool = ToolDefinition(
            name: "classify",
            description: "Record the claim kind",
            parameters: .object(
                properties: ["label": .string(description: nil, choices: [])],
                required: ["label"],
                description: nil
            )
        )
        let toolRequest = ModelRequest(messages: [Message(role: .user, text: "Classify.")], tools: [badTool])
        for request in [Self.structured(bad), toolRequest] {
            let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
            expectChoicesRefusal(await collect(oai, request).error)
            #expect(oaiTransport.openCount.get() == 0)

            let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
            expectChoicesRefusal(await collect(anth, request).error)
            #expect(anthTransport.openCount.get() == 0)
        }
    }

    private func expectChoicesRefusal(_ error: KBLLMError?) {
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == "root.label")
        #expect(reason.contains("choices"))
    }
}
