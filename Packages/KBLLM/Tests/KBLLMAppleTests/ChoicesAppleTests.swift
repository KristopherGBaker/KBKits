import Foundation
import KBLLM
import Testing
@testable import KBLLMApple
#if canImport(FoundationModels)
import FoundationModels
#endif

// String choices and greedy sampling on the Apple adapter. The refusal and post-decode tests drive
// `AppleModel` against the scripted `FakeFoundationModelBackend`, so they run on every machine.
// The FM-gated tests drive the live backends with recording responders to prove the choices reach
// the `GenerationSchema` (structured output and tool parameters) and greedy reaches the
// FoundationModels `GenerationOptions`, on-device and through Private Cloud Compute; they need
// only schema and options construction, never inference.
@Suite struct ChoicesAppleTests {
    static let labels = ["personalClaim", "general", "instruction"]

    /// A required label, and two nested objects whose same-named `kind` carries different
    /// choices, plus array items with a choice of their own.
    static let schema: JSONSchema = .object(
        properties: [
            "label": .string(description: "the claim kind", choices: labels),
            "first": .object(
                properties: ["kind": .string(description: nil, choices: ["x", "y"])],
                required: ["kind"],
                description: nil
            ),
            "second": .object(
                properties: ["kind": .string(description: nil, choices: ["p", "q"])],
                required: ["kind"],
                description: nil
            ),
            "tags": .array(items: .string(description: nil, choices: ["red", "blue"]), description: nil)
        ],
        required: ["label", "first", "second", "tags"],
        description: nil
    )

    static let conforming = #"{"label":"general","first":{"kind":"x"},"second":{"kind":"q"},"tags":["red"]}"#
    static let unlistedLabel = #"{"label":"opinion","first":{"kind":"x"},"second":{"kind":"q"},"tags":[]}"#
    static let unlistedNested = #"{"label":"general","first":{"kind":"x"},"second":{"kind":"x"},"tags":[]}"#
    static let unlistedItem = #"{"label":"general","first":{"kind":"x"},"second":{"kind":"q"},"tags":["green"]}"#

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
        ModelRequest(messages: [Message(role: .user, text: "Classify.")], responseSchema: schema)
    }

    /// `request` asking for greedy sampling beside the given knobs. Built through
    /// `request.options` because, where FoundationModels is imported, the neutral options type
    /// cannot be named without colliding with the framework's own `GenerationOptions`.
    private static func greedy(
        _ request: ModelRequest,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        topP: Double? = nil
    ) -> ModelRequest {
        var request = request
        request.options.temperature = temperature
        request.options.maxOutputTokens = maxOutputTokens
        request.options.topP = topP
        request.options.sampling = .greedy
        return request
    }

    // MARK: Refused before any inference

    @Test func unsendableChoicesAreRefusedWithoutInference() async {
        let bad: JSONSchema = .object(
            properties: ["label": .string(description: nil, choices: ["a", ""])],
            required: ["label"],
            description: nil
        )
        let fake = FakeFoundationModelBackend(script: .snapshots([#"{"label":"a"}"#]))
        let result = await collect(AppleModel(backend: fake), Self.structured(bad))
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "root.label")
        #expect(reason.contains("choices"))
        #expect(fake.inferenceCount == 0)

        let badTool = ToolDefinition(
            name: "classify",
            description: "Record the claim kind",
            parameters: .object(
                properties: ["label": .string(description: nil, choices: [])],
                required: [],
                description: nil
            )
        )
        let toolScript = FakeFoundationModelBackend.Script.toolCall(name: "classify", id: "call_1", argumentsJSON: "{}")
        let toolFake = FakeFoundationModelBackend(script: toolScript)
        let toolRequest = ModelRequest(messages: [Message(role: .user, text: "Classify.")], tools: [badTool])
        let toolResult = await collect(AppleModel(backend: toolFake), toolRequest)
        guard case .invalidRequest(let toolField, _) = toolResult.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: toolResult.error))")
            return
        }
        #expect(toolField == "root.label")
        #expect(toolFake.inferenceCount == 0)
    }

    // MARK: Post-decode enforcement

    @Test(arguments: [
        (unlistedLabel, "root.label"),
        (unlistedNested, "root.second.kind"),
        (unlistedItem, "root.tags[]")
    ])
    func anUnlistedValueIsASchemaViolation(document: String, path: String) async {
        let fake = FakeFoundationModelBackend(script: .snapshots([document]))
        let result = await collect(AppleModel(backend: fake), Self.structured(Self.schema))
        guard case .schemaViolation(let expected, let received) = result.error else {
            Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
            return
        }
        #expect(expected.contains(path))
        #expect(expected.contains("one of"))
        #expect(received == document)
        #expect(!result.events.contains(.completed(.stop)))
    }

    @Test func aListedAnswerCompletes() async {
        let fake = FakeFoundationModelBackend(script: .snapshots([Self.conforming]))
        let result = await collect(AppleModel(backend: fake), Self.structured(Self.schema))
        #expect(result.error == nil)
        #expect(result.content == Self.conforming)
        #expect(result.events.last == .completed(.stop))
    }

    #if canImport(FoundationModels)
    // MARK: The choices reach the GenerationSchema

    @Test func structuredChoicesBecomeTheGenerationSchemaEnum() async throws {
        let responder = RecordingResponder(snapshots: [Self.conforming])
        for try await _ in LiveFoundationModelBackend(responder: responder).run(Self.structured(Self.schema)) {}
        let encoded = try encodedJSON(try #require(responder.recordedSchema))
        let properties = try #require(encoded["properties"] as? [String: Any])
        let label = try #require(properties["label"] as? [String: Any])
        #expect(label["enum"] as? [String] == Self.labels)
        #expect(label["type"] as? String == "string")
        #expect(label["description"] as? String == "the claim kind")
        let tags = try #require(properties["tags"] as? [String: Any])
        #expect((tags["items"] as? [String: Any])?["enum"] as? [String] == ["red", "blue"])
        // The same-named nested choices stay distinct rather than colliding on one name.
        let enums = Set(allEnums(in: encoded))
        #expect(enums.contains(["x", "y"]))
        #expect(enums.contains(["p", "q"]))
    }

    @Test func aStringWithoutChoicesRendersAsBefore() async throws {
        let plain: JSONSchema = .object(
            properties: ["label": .string(description: "free")],
            required: ["label"],
            description: nil
        )
        let responder = RecordingResponder(snapshots: [#"{"label":"anything"}"#])
        for try await _ in LiveFoundationModelBackend(responder: responder).run(Self.structured(plain)) {}
        let encoded = try encodedJSON(try #require(responder.recordedSchema))
        let label = try #require((encoded["properties"] as? [String: Any])?["label"] as? [String: Any])
        #expect(label["enum"] == nil)
        #expect(label["type"] as? String == "string")
    }

    @Test func toolParameterChoicesBecomeTheGenerationSchemaEnum() async throws {
        let responder = ToolSchemaRecordingResponder()
        let request = ModelRequest(messages: [Message(role: .user, text: "Classify.")], tools: [Self.classifyTool])
        for try await _ in LiveFoundationModelBackend(responder: responder).run(request) {}
        let parameters = try #require(responder.parameters.first)
        let encoded = try encodedJSON(parameters)
        let label = try #require((encoded["properties"] as? [String: Any])?["label"] as? [String: Any])
        #expect(label["enum"] as? [String] == Self.labels)
    }

    // MARK: Greedy reaches GenerationOptions

    @Test func greedyBecomesTheGreedySamplingModeAndWins() async throws {
        let base = Self.structured(Self.schema)
        let variants = [
            Self.greedy(base),
            Self.greedy(base, temperature: 0.8, maxOutputTokens: 300, topP: 0.9)
        ]
        for request in variants {
            let responder = RecordingResponder(snapshots: [Self.conforming])
            for try await _ in LiveFoundationModelBackend(responder: responder).run(request) {}
            let recorded = try #require(responder.recordedOptions)
            #expect(recorded.samplingMode == .greedy)
            #expect(recorded.temperature == nil)
            #expect(recorded.maximumResponseTokens == request.options.maxOutputTokens)
        }
    }

    @Test func unsetSamplingKeepsTheExistingMapping() async throws {
        let responder = RecordingResponder(snapshots: ["hi"])
        var request = ModelRequest(messages: [Message(role: .user, text: "hi")])
        request.options.temperature = 0.5
        request.options.topP = 0.25
        #expect(request.options.sampling == nil)
        for try await _ in LiveFoundationModelBackend(responder: responder).run(request) {}
        let recorded = try #require(responder.recordedOptions)
        #expect(recorded.samplingMode == .random(probabilityThreshold: 0.25))
        #expect(recorded.temperature == 0.5)
    }

    @Test func bothLiveBackendsSendChoicesAndGreedy() async throws {
        guard #available(macOS 27, iOS 27, *) else { return }
        let responder = RecordingResponder(snapshots: [Self.conforming])
        for (backendName, backend) in bothLiveBackends(responder: responder) {
            for try await _ in backend.run(Self.greedy(Self.structured(Self.schema))) {}
            #expect(responder.recordedOptions?.samplingMode == .greedy, "\(backendName)")
            let encoded = try encodedJSON(try #require(responder.recordedSchema))
            let labelNode = (encoded["properties"] as? [String: Any])?["label"] as? [String: Any]
            #expect(labelNode?["enum"] as? [String] == Self.labels, "\(backendName)")
        }
    }

    private func encodedJSON(_ schema: GenerationSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every `enum` list anywhere in an encoded schema, `$defs` included.
    private func allEnums(in node: Any) -> [[String]] {
        if let object = node as? [String: Any] {
            let own = (object["enum"] as? [String]).map { [$0] } ?? []
            return own + object.values.flatMap { allEnums(in: $0) }
        }
        if let array = node as? [Any] { return array.flatMap { allEnums(in: $0) } }
        return []
    }
    #endif
}

#if canImport(FoundationModels)
/// Records each tool's `GenerationSchema` parameters, then answers one plain snapshot.
final class ToolSchemaRecordingResponder: FoundationModelResponder, @unchecked Sendable {
    private let recorded = Box<[GenerationSchema]>([])

    var parameters: [GenerationSchema] { recorded.get() }

    func streamResponse(
        to prompt: ResponderPrompt,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        schema: GenerationSchema?,
        options: FoundationModels.GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        recorded.mutate { $0 = tools.map(\.parameters) }
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}
#endif
