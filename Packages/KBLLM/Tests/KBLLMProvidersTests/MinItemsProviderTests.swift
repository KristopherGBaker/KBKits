import Foundation
import KBLLM
import KBLLMOpenAI
import Testing
@testable import KBLLMAnthropic

// `minItems` on the wire. Every test is offline: the request body each adapter built is read
// back off the same `RecordingTransport` the rest of the provider suite uses, decoded, and
// checked, so the assertions are about what a provider would actually receive. When
// `KBLLM_MINITEMS_CAPTURE_DIR` is set the decoded bodies are also written there, so a gate can
// inspect them independently of these expectations.
@Suite struct MinItemsProviderTests {
    /// A card whose `readings` must hold `readings` items and whose OPTIONAL `notes` array
    /// carries its own minimum, so the strict nullable translation is exercised with a minimum.
    private static func cardSchema(readings: Int?, notes: Int?) -> JSONSchema {
        .object(
            properties: [
                "title": .string(description: "the card title"),
                "readings": .array(
                    items: .object(
                        properties: ["value": .string(description: nil)],
                        required: ["value"],
                        description: "one reading"
                    ),
                    description: "the readings",
                    minItems: readings
                ),
                "notes": .array(items: .string(description: nil), description: nil, minItems: notes)
            ],
            required: ["title", "readings"],
            description: "a vocabulary card"
        )
    }

    private static let minimumSchema = cardSchema(readings: 2, notes: 1)
    private static let plainSchema = cardSchema(readings: nil, notes: nil)
    private static let negativeSchema = cardSchema(readings: -1, notes: nil)

    private static let twoReadings = #"{"title":"t","readings":[{"value":"a"},{"value":"b"}],"notes":null}"#
    private static let oneReading = #"{"title":"t","readings":[{"value":"a"}],"notes":null}"#

    private static func tagTool(minItems: Int?) -> ToolDefinition {
        ToolDefinition(
            name: "tag_items",
            description: "Apply tags",
            parameters: .object(
                properties: ["tags": .array(items: .string(description: nil), description: nil, minItems: minItems)],
                required: ["tags"],
                description: nil
            )
        )
    }

    private static func structured(_ schema: JSONSchema) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "Make a card.")], responseSchema: schema)
    }

    private static func withTool(_ tool: ToolDefinition) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "Tag these.")], tools: [tool])
    }

    private static func anthropicReply(_ document: String) -> [UInt8] {
        Fixtures.anthropicStructured(toolName: AnthropicModel.structuredToolName, fragments: [document])
    }

    // MARK: Helpers

    private func body(_ transport: RecordingTransport) -> [String: Any] {
        let data = transport.requests.get().first?.body ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func bodyString(_ transport: RecordingTransport) -> String {
        String(bytes: transport.requests.get().first?.body ?? Data(), encoding: .utf8) ?? ""
    }

    /// Write the decoded body under `name` when the capture directory is configured. The body is
    /// re-serialized with sorted keys so two captures of equal requests are byte-identical.
    private func capture(_ transport: RecordingTransport, as name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["KBLLM_MINITEMS_CAPTURE_DIR"] else { return }
        let data = try JSONSerialization.data(withJSONObject: body(transport), options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
    }

    private func dig(_ object: Any?, _ path: String...) -> Any? {
        path.reduce(object) { node, key in
            if let index = Int(key) { return (node as? [Any]).flatMap { $0.indices.contains(index) ? $0[index] : nil } }
            return (node as? [String: Any])?[key]
        }
    }

    /// Every object node in a serialized schema, at any depth, for the strict-mode sweep.
    private func objectNodes(_ node: Any?) -> [[String: Any]] {
        guard let node = node as? [String: Any] else { return [] }
        let types = (node["type"] as? [String]) ?? [node["type"] as? String].compactMap { $0 }
        let isObject = types.contains("object")
        let children = (node["properties"] as? [String: Any])?.values.flatMap { objectNodes($0) } ?? []
        return (isObject ? [node] : []) + children + objectNodes(node["items"])
    }

    private func reserialize(_ node: Any?) throws -> String {
        let object = try #require(node)
        return String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
    }

    // MARK: Anthropic

    @Test func anthropicStructuredSendsTheMinimum() async throws {
        let (model, transport) = makeAnthropic(.replay(Self.anthropicReply(Self.twoReadings)))
        let result = await collect(model, Self.structured(Self.minimumSchema))
        #expect(result.error == nil)
        try capture(transport, as: "anthropic-structured-min2")

        let schema = dig(body(transport), "tools", "0", "input_schema")
        #expect(dig(schema, "properties", "readings", "minItems") as? Int == 2)
        #expect(dig(schema, "properties", "notes", "minItems") as? Int == 1)
        // A JSON integer on the wire, not a string or a float.
        #expect(bodyString(transport).contains(#""minItems":2"#))
        // Round trip: the input_schema parses back to exactly the schema that was sent.
        #expect(try JSONSchema.parse(reserialize(schema)) == Self.minimumSchema)
    }

    @Test func anthropicStructuredWithNoMinimumSendsNoKey() async throws {
        let (model, transport) = makeAnthropic(.replay(Self.anthropicReply(Self.twoReadings)))
        let result = await collect(model, Self.structured(Self.plainSchema))
        #expect(result.error == nil)
        try capture(transport, as: "anthropic-structured-nil")
        #expect(!bodyString(transport).contains("minItems"))
        let schema = dig(body(transport), "tools", "0", "input_schema")
        #expect(try JSONSchema.parse(reserialize(schema)) == Self.plainSchema)
    }

    @Test func anthropicSendsAZeroMinimumAsZero() async {
        let (model, transport) = makeAnthropic(.replay(Self.anthropicReply(Self.twoReadings)))
        _ = await collect(model, Self.structured(Self.cardSchema(readings: 0, notes: nil)))
        #expect(dig(body(transport), "tools", "0", "input_schema", "properties", "readings", "minItems") as? Int == 0)
        #expect(bodyString(transport).contains(#""minItems":0"#))
    }

    @Test func anthropicToolParametersCarryTheMinimum() async throws {
        let (model, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(model, Self.withTool(Self.tagTool(minItems: 1)))
        try capture(transport, as: "anthropic-tool-min1")
        #expect(dig(body(transport), "tools", "0", "input_schema", "properties", "tags", "minItems") as? Int == 1)
    }

    // MARK: OpenAI

    @Test func openAIStrictStructuredSendsTheMinimum() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [Self.twoReadings])))
        let result = await collect(model, Self.structured(Self.minimumSchema))
        #expect(result.error == nil)
        try capture(transport, as: "openai-structured-min2")

        let format = dig(body(transport), "response_format", "json_schema")
        #expect(dig(format, "strict") as? Bool == true)
        let schema = dig(format, "schema")
        #expect(dig(schema, "properties", "readings", "minItems") as? Int == 2)
        #expect(bodyString(transport).contains(#""minItems":2"#))

        // Strict mode still gets additionalProperties:false on EVERY object node.
        let objects = objectNodes(schema)
        #expect(objects.count == 2)
        for object in objects {
            #expect(object["additionalProperties"] as? Bool == false)
        }

        // The OPTIONAL array is nullable, listed in required, and keeps its minimum.
        #expect(dig(schema, "properties", "notes", "type") as? [String] == ["array", "null"])
        #expect((dig(schema, "required") as? [String])?.contains("notes") == true)
        #expect(dig(schema, "properties", "notes", "minItems") as? Int == 1)

        // Round trip: the strict schema parses back to the source, minimums and optionality intact.
        #expect(try JSONSchema.parse(reserialize(schema)) == Self.minimumSchema)
    }

    @Test func openAIStructuredWithNoMinimumSendsNoKey() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [Self.twoReadings])))
        let result = await collect(model, Self.structured(Self.plainSchema))
        #expect(result.error == nil)
        try capture(transport, as: "openai-structured-nil")
        #expect(!bodyString(transport).contains("minItems"))
        let schema = dig(body(transport), "response_format", "json_schema", "schema")
        #expect(try JSONSchema.parse(reserialize(schema)) == Self.plainSchema)
    }

    @Test func openAIToolParametersCarryTheMinimum() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(model, Self.withTool(Self.tagTool(minItems: 1)))
        try capture(transport, as: "openai-tool-min1")
        let parameters = dig(body(transport), "tools", "0", "function", "parameters")
        #expect(dig(parameters, "properties", "tags", "minItems") as? Int == 1)
    }

    // MARK: Negative minimum refused before the transport opens

    @Test func aNegativeResponseSchemaIsRefusedWithoutOpeningTheTransport() async {
        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [Self.twoReadings])))
        expectMinItemsRefusal(await collect(oai, Self.structured(Self.negativeSchema)).error, field: "root.readings")
        #expect(oaiTransport.openCount.get() == 0)

        let (anth, anthTransport) = makeAnthropic(.replay(Self.anthropicReply(Self.twoReadings)))
        expectMinItemsRefusal(await collect(anth, Self.structured(Self.negativeSchema)).error, field: "root.readings")
        #expect(anthTransport.openCount.get() == 0)
    }

    @Test func aNegativeToolParameterIsRefusedWithoutOpeningTheTransport() async {
        let request = Self.withTool(Self.tagTool(minItems: -1))
        let (oai, oaiTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        expectMinItemsRefusal(await collect(oai, request).error, field: "root.tags")
        #expect(oaiTransport.openCount.get() == 0)

        let (anth, anthTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        expectMinItemsRefusal(await collect(anth, request).error, field: "root.tags")
        #expect(anthTransport.openCount.get() == 0)
    }

    private func expectMinItemsRefusal(_ error: KBLLMError?, field expectedField: String) {
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == expectedField)
        #expect(reason.contains("minItems"))
    }

    // MARK: Post-decode enforcement

    @Test func anUnderCountAnswerIsASchemaViolationOnBothAdapters() async {
        let openAI = await collect(
            makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [Self.oneReading]))).0,
            Self.structured(Self.minimumSchema)
        )
        let anthropic = await collect(
            makeAnthropic(.replay(Self.anthropicReply(Self.oneReading))).0,
            Self.structured(Self.minimumSchema)
        )
        for result in [openAI, anthropic] {
            guard case .schemaViolation(let expected, let received) = result.error else {
                Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
                continue
            }
            #expect(expected.contains("root.readings"))
            #expect(expected.contains("at least 2"))
            #expect(received == Self.oneReading)
            #expect(!result.events.contains(.completed(.stop)))
        }
    }

    @Test func anAnswerMeetingTheMinimumCompletesOnBothAdapters() async {
        let openAI = await collect(
            makeOpenAI(.replay(Fixtures.openAIStructured(contentChunks: [Self.twoReadings]))).0,
            Self.structured(Self.minimumSchema)
        )
        let anthropic = await collect(
            makeAnthropic(.replay(Self.anthropicReply(Self.twoReadings))).0,
            Self.structured(Self.minimumSchema)
        )
        for result in [openAI, anthropic] {
            #expect(result.error == nil)
            #expect(result.events.last == .completed(.stop))
        }
    }
}
