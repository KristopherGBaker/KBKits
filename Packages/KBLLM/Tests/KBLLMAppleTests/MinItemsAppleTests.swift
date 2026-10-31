import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// `minItems` on the Apple adapter. The refusal and post-decode tests drive `AppleModel` against
// the scripted `FakeFoundationModelBackend`, so they run on every machine. The FM-gated test
// drives `LiveFoundationModelBackend` with the `RecordingResponder` to prove the minimum reaches
// the `GenerationSchema` handed to the response op; it needs only schema construction, never
// on-device inference. When `KBLLM_MINITEMS_CAPTURE_DIR` is set, the encoded schemas and the
// FoundationModels availability of this build are written there for the gate.
@Suite struct MinItemsAppleTests {
    private static func schema(readings: Int?) -> JSONSchema {
        .object(
            properties: [
                "title": .string(description: "the card title"),
                "readings": .array(items: .string(description: nil), description: "the readings", minItems: readings)
            ],
            required: ["title", "readings"],
            description: "a vocabulary card"
        )
    }

    private static let twoReadings = #"{"title":"t","readings":["a","b"]}"#
    private static let oneReading = #"{"title":"t","readings":["a"]}"#

    private static func structured(_ schema: JSONSchema) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "Make a card.")], responseSchema: schema)
    }

    private static var captureDirectory: URL? {
        ProcessInfo.processInfo.environment["KBLLM_MINITEMS_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static func write(_ data: Data, as name: String) throws {
        guard let directory = captureDirectory else { return }
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func expectMinItemsRefusal(_ error: KBLLMError?, field expectedField: String) {
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == expectedField)
        #expect(reason.contains("minItems"))
    }

    // MARK: Refused before any inference

    @Test func refusesNegativeResponseSchemaWithoutInference() async {
        let fake = FakeFoundationModelBackend(script: .snapshots([Self.twoReadings]))
        let result = await collect(AppleModel(backend: fake), Self.structured(Self.schema(readings: -1)))
        expectMinItemsRefusal(result.error, field: "root.readings")
        #expect(fake.inferenceCount == 0)
    }

    @Test func refusesNegativeToolParametersWithoutInference() async {
        let tool = ToolDefinition(
            name: "tag_items",
            description: "Apply tags",
            parameters: .object(
                properties: ["tags": .array(items: .string(description: nil), description: nil, minItems: -1)],
                required: ["tags"],
                description: nil
            )
        )
        let fake = FakeFoundationModelBackend(script: .toolCall(name: "tag_items", id: "call_1", argumentsJSON: "{}"))
        let request = ModelRequest(messages: [Message(role: .user, text: "Tag these.")], tools: [tool])
        let result = await collect(AppleModel(backend: fake), request)
        expectMinItemsRefusal(result.error, field: "root.tags")
        #expect(fake.inferenceCount == 0)
    }

    // MARK: Post-decode enforcement

    @Test func anUnderCountAnswerIsASchemaViolation() async {
        let fake = FakeFoundationModelBackend(script: .snapshots([Self.oneReading]))
        let result = await collect(AppleModel(backend: fake), Self.structured(Self.schema(readings: 2)))
        guard case .schemaViolation(let expected, let received) = result.error else {
            Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
            return
        }
        #expect(expected.contains("root.readings"))
        #expect(expected.contains("at least 2"))
        #expect(received == Self.oneReading)
        #expect(!result.events.contains(.completed(.stop)))
    }

    @Test func anAnswerMeetingTheMinimumCompletes() async {
        let fake = FakeFoundationModelBackend(script: .snapshots([Self.twoReadings]))
        let result = await collect(AppleModel(backend: fake), Self.structured(Self.schema(readings: 2)))
        #expect(result.error == nil)
        #expect(result.content == Self.twoReadings)
        #expect(result.events.last == .completed(.stop))
        #expect(fake.inferenceCount == 1)
    }

    // MARK: The minimum reaches the GenerationSchema

    #if canImport(FoundationModels)
    @Test func liveBackendMapsTheMinimumOntoTheGenerationSchema() async throws {
        let withMinimum = try await recordedSchema(for: Self.schema(readings: 2))
        let withoutMinimum = try await recordedSchema(for: Self.schema(readings: nil))
        try Self.write(Data("available\n".utf8), as: "apple-fm-status.txt")
        try Self.write(withMinimum, as: "apple-schema-min2.json")
        try Self.write(withoutMinimum, as: "apple-schema-nil.json")

        #expect(withMinimum != withoutMinimum)
        let readings = try #require(readingsNode(in: withMinimum))
        let bare = try #require(readingsNode(in: withoutMinimum))
        #expect(readings["minItems"] as? Int == 2)
        #expect(bare["minItems"] == nil)
    }

    /// The sorted-key encoding of the `GenerationSchema` the live backend built for `schema`.
    private func recordedSchema(for schema: JSONSchema) async throws -> Data {
        let responder = RecordingResponder(snapshots: [Self.twoReadings])
        let backend = LiveFoundationModelBackend(responder: responder)
        for try await _ in backend.run(Self.structured(schema)) {}
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try #require(responder.recordedSchema))
    }

    /// The `readings` property node of an encoded schema, wherever the encoding nests it.
    private func readingsNode(in encoded: Data) -> [String: Any]? {
        func search(_ node: Any) -> [String: Any]? {
            if let object = node as? [String: Any] {
                if let properties = object["properties"] as? [String: Any],
                   let readings = properties["readings"] as? [String: Any] {
                    return readings
                }
                for value in object.values { if let found = search(value) { return found } }
            } else if let array = node as? [Any] {
                for value in array { if let found = search(value) { return found } }
            }
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: encoded)).flatMap(search)
    }
    #else
    @Test func recordsThatFoundationModelsIsUnavailable() throws {
        try Self.write(Data("unavailable\n".utf8), as: "apple-fm-status.txt")
    }
    #endif
}
