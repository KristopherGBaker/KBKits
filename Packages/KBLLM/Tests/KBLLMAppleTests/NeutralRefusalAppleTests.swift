import Foundation
import KBLLM
import KBLLMApple
import Testing

// `AppleModel`'s neutral pre-dispatch refusals, pinned by their COMPLETE reason strings, the
// precedence between them, and the one place its walk differs from the HTTP adapters': it checks
// a tool's `parameters` only, because FoundationModels never sees `rawParameters`, so a tool
// whose `rawParameters` is not an object schema reaches the backend rather than being refused.
// Offline, against the scripted `FakeFoundationModelBackend`.
@Suite struct NeutralRefusalAppleTests {
    private let capable: Set<FoundationModelCapability> = [.vision, .guidedGeneration, .toolCalling]

    private static let negativeSchema: JSONSchema = .object(
        properties: ["readings": .array(items: .string(description: nil), description: nil, minItems: -1)],
        required: ["readings"],
        description: nil
    )

    private func refusal(_ request: ModelRequest) async -> (field: String, reason: String, inferences: Int)? {
        let fake = FakeFoundationModelBackend(capabilities: capable, script: .snapshots(["{}"]))
        let result = await collect(AppleModel(backend: fake), request)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return nil
        }
        #expect(result.events.isEmpty)
        return (field, reason, fake.inferenceCount)
    }

    @Test func webSearchIsRefusedWithTheCompleteReason() async {
        let request = ModelRequest(messages: [Message(role: .user, text: "News?")], webSearch: WebSearchOptions())
        let outcome = await refusal(request)
        #expect(outcome?.field == "webSearch")
        #expect(outcome?.reason == "this model does not support server-side web search (supportsWebSearch is false)")
        #expect(outcome?.inferences == 0)
    }

    @Test func schemaPlusToolsIsRefusedWithTheCompleteReason() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")],
            tools: [appleWeatherTool],
            responseSchema: appleStructuredSchema
        )
        let outcome = await refusal(request)
        #expect(outcome?.field == "responseSchema+tools")
        #expect(outcome?.reason == "responseSchema and tools cannot be combined in one request")
        #expect(outcome?.inferences == 0)
    }

    @Test func webSearchWinsOverSchemaPlusTools() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")],
            tools: [appleWeatherTool],
            responseSchema: appleStructuredSchema,
            webSearch: WebSearchOptions()
        )
        let outcome = await refusal(request)
        #expect(outcome?.field == "webSearch")
        #expect(outcome?.inferences == 0)
    }

    @Test func schemaPlusToolsWinsOverAnUnhonourableSchema() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")],
            tools: [appleWeatherTool],
            responseSchema: Self.negativeSchema
        )
        let outcome = await refusal(request)
        #expect(outcome?.field == "responseSchema+tools")
        #expect(outcome?.inferences == 0)
    }

    @Test(arguments: [#"[1,2]"#, #"{"type":"string"}"#, "not json"])
    func aNonObjectRawSchemaIsNotRefusedBeforeTheBackendRuns(raw: String) async {
        let tool = ToolDefinition(
            name: "lookup", description: "d", parameters: .object(properties: [:], required: [], description: nil),
            rawParameters: Data(raw.utf8)
        )
        let fake = FakeFoundationModelBackend(capabilities: capable, script: .snapshots(["Paris is sunny."]))
        let result = await collect(
            AppleModel(backend: fake),
            ModelRequest(messages: [Message(role: .user, text: "Look up Paris")], tools: [tool])
        )
        #expect(result.error == nil)
        #expect(fake.inferenceCount == 1)
        #expect(result.content == "Paris is sunny.")
    }
}
