import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// The Apple structured-output suite (unit 6). The offline tests drive `AppleModel` against the
// scripted `FakeFoundationModelBackend`, so validation and content-vs-tool-call behaviour are
// pinned with no Apple Intelligence. The single FM-gated test drives `LiveFoundationModelBackend`
// with a fake responder to prove the built `GenerationSchema` reaches the response op; it needs
// only schema construction, which requires no on-device inference.

/// The nested structured schema, matching the provider suite's `structuredSchema`: distinct
/// descriptions at object, array, and leaf level, and a required list at two nesting depths.
let appleStructuredSchema: JSONSchema = .object(
    properties: [
        "title": .string(description: "the card title"),
        "readings": .array(
            items: .object(
                properties: ["value": .string(description: "the reading value")],
                required: ["value"],
                description: "one reading"
            ),
            description: "the list of readings"
        )
    ],
    required: ["title", "readings"],
    description: "a vocabulary card"
)

let appleConformingDocument = #"{"title":"Paris","readings":[{"value":"sunny"}]}"#
let appleNonconformingDocument = #"{"title":"Paris"}"#
let appleMalformedDocument = #"{"title":"#

let appleStructuredRequest = ModelRequest(
    messages: [Message(role: .user, text: "Make a vocabulary card for Paris.")],
    responseSchema: appleStructuredSchema
)

/// A caller tool, to prove the schema-plus-tools request is rejected pre-run.
let appleWeatherTool = ToolDefinition(
    name: "get_weather",
    description: "Look up the weather for a city",
    parameters: .object(
        properties: ["city": .string(description: "The city to look up")],
        required: ["city"],
        description: "weather query"
    )
)

@Suite struct StructuredOutputAppleTests {
    // MARK: Assertion 10 - structured snapshots become content, not a tool call.

    @Test func appleStructuredSnapshotsBecomeContent() async {
        // Cumulative snapshots that build up to the conforming document (each a prefix of the
        // next, as the framework yields), so the diffed deltas concatenate to the document.
        let snapshots = [#"{"title":"#, #"{"title":"Paris","readings":["#, appleConformingDocument]
        let fake = FakeFoundationModelBackend(script: .snapshots(snapshots))
        let result = await collect(AppleModel(backend: fake), appleStructuredRequest)
        #expect(result.error == nil)
        #expect(result.content == appleConformingDocument)
        #expect(result.events.last == .completed(.stop))
        let hasToolCall = result.events.contains { if case .toolCall = $0 { true } else { false } }
        #expect(!hasToolCall)
    }

    // MARK: Assertion 8 - failure not fallback, both negative kinds.

    @Test func appleRejectsMalformedStructured() async {
        await expectAppleViolation(finalSnapshot: appleMalformedDocument)
    }

    @Test func appleRejectsNonconformingStructured() async {
        await expectAppleViolation(finalSnapshot: appleNonconformingDocument)
    }

    private func expectAppleViolation(finalSnapshot: String) async {
        let fake = FakeFoundationModelBackend(script: .snapshots([finalSnapshot]))
        let result = await collect(AppleModel(backend: fake), appleStructuredRequest)
        guard case .schemaViolation(_, let received) = result.error else {
            Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
            return
        }
        #expect(received == finalSnapshot)
        #expect(!result.events.contains(.completed(.stop)))
    }

    // MARK: Assertion 11 - responseSchema + tools rejected pre-dispatch, no inference.

    @Test func schemaPlusToolsRejectedByApple() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card")],
            tools: [appleWeatherTool],
            responseSchema: appleStructuredSchema
        )
        let fake = FakeFoundationModelBackend(script: .snapshots([appleConformingDocument]))
        let result = await collect(AppleModel(backend: fake), request)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        let payload = field + " " + reason
        #expect(payload.contains("responseSchema"))
        #expect(payload.contains("tools"))
        #expect(fake.inferenceCount == 0)
    }

    // MARK: Assertion 3 - the built GenerationSchema reaches the live backend's response op.

    #if canImport(FoundationModels)
    @Test func liveBackendSuppliesSchemaToResponseOperation() async throws {
        let responder = RecordingResponder(snapshots: [appleConformingDocument])
        let backend = LiveFoundationModelBackend(responder: responder)
        for try await _ in backend.run(appleStructuredRequest) {}

        let recorded = try #require(responder.recordedSchema)
        let encoded = try JSONEncoder().encode(recorded)
        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        #expect(text.contains("title"))
        #expect(text.contains("readings"))
        #expect(text.contains("value"))
        #expect(text.contains("required"))
        let descriptions = [
            "a vocabulary card", "the list of readings", "one reading", "the reading value", "the card title"
        ]
        for description in descriptions {
            #expect(text.contains(description), "encoded schema dropped description \"\(description)\"")
        }

        // With no schema the responder records nil, so the schema-absent path supplies none.
        let plainResponder = RecordingResponder(snapshots: ["hi"])
        let plainBackend = LiveFoundationModelBackend(responder: plainResponder)
        for try await _ in plainBackend.run(ModelRequest(messages: [Message(role: .user, text: "hi")])) {}
        #expect(plainResponder.didRecord)
        #expect(plainResponder.recordedSchema == nil)
    }
    #endif
}

#if canImport(FoundationModels)
import FoundationModels

/// A fake response op that records the `GenerationSchema` supplied to it and yields a scripted
/// snapshot list, running no inference. This is how assertion 3 observes the schema the live
/// backend built and passed to `session.streamResponse(to:schema:)` without a device.
final class RecordingResponder: FoundationModelResponder, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: GenerationSchema?
    private var recordedGenerationOptions: FoundationModels.GenerationOptions?
    private(set) var didRecord = false
    private let snapshots: [String]

    init(snapshots: [String]) {
        self.snapshots = snapshots
    }

    var recordedSchema: GenerationSchema? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The `GenerationOptions` the live backend built and supplied, so a test can prove the
    /// neutral sampling controls reached this seam on whichever response path ran.
    var recordedOptions: FoundationModels.GenerationOptions? {
        lock.lock()
        defer { lock.unlock() }
        return recordedGenerationOptions
    }

    func streamResponse(
        to prompt: ResponderPrompt,
        instructions: String?,
        tools: [any FoundationModels.Tool],
        schema: GenerationSchema?,
        options: FoundationModels.GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        lock.lock()
        recorded = schema
        recordedGenerationOptions = options
        didRecord = true
        lock.unlock()
        let snapshots = self.snapshots
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }
}
#endif

@Suite struct AppleStructuredSnapshotRevisionTests {
    /// Structured snapshots are REVISED, not extended. Observed on device for a two-field card:
    ///
    ///   {"word": "nekko", "reading": ""}
    ///   {"reading": "ねこ", "word": "nekko"}
    ///
    /// The keys reorder and a value is replaced, so the second is not a prefix of the first.
    /// The free-text path treats snapshots as cumulative and rejects a non-extending one, which
    /// is right for prose and wrong here: it rejected a perfectly good answer on real hardware.
    /// Every offline fixture used prefix-extending snapshots, so nothing caught it.
    @Test func revisedStructuredSnapshotsYieldTheFinalDocument() async {
        let schema = JSONSchema.object(
            properties: [
                "word": .string(description: "the word"),
                "reading": .string(description: "the reading")
            ],
            required: ["word", "reading"],
            description: "a vocabulary card"
        )
        let final = #"{"reading": "ねこ", "word": "nekko"}"#
        let fake = FakeFoundationModelBackend(script: .snapshots([
            #"{"word": "nekko", "reading": ""}"#,
            final
        ]))
        let request = ModelRequest(
            messages: [Message(role: .user, text: "card for neko")],
            responseSchema: schema
        )

        let result = await collect(AppleModel(backend: fake), request)

        #expect(result.error == nil)
        // The LAST snapshot is the answer, emitted once. Not a diff, and not both concatenated.
        #expect(result.content == final)
        #expect(result.events.last == .completed(.stop))
    }
}
