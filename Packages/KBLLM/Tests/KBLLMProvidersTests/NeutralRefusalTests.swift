import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

// The neutral pre-dispatch refusals every HTTP adapter makes, pinned by their COMPLETE reason
// strings (the other suites match on the field and a fragment), plus the precedence between
// them when one request breaks several rules at once: which refusal wins is part of the
// contract a caller sees. Every refusal leaves the transport unopened. Offline.
@Suite struct NeutralRefusalTests {
    static let webSearchReason = "this model does not support server-side web search (supportsWebSearch is false)"
    static let schemaPlusToolsReason = "responseSchema and tools cannot be combined in one request"

    /// A schema no provider could honour: `readings` with a negative `minItems`.
    static let negativeSchema: JSONSchema = .object(
        properties: [
            "title": .string(description: nil),
            "readings": .array(items: .string(description: nil), description: nil, minItems: -1)
        ],
        required: ["title", "readings"],
        description: nil
    )

    static let negativeTool = ToolDefinition(
        name: "tag_items",
        description: "Apply tags",
        parameters: .object(
            properties: ["tags": .array(items: .string(description: nil), description: nil, minItems: -1)],
            required: ["tags"],
            description: nil
        )
    )

    /// A conversation ending on the assistant's turn: a prefill, which current Anthropic models refuse.
    static let prefill = [Message(role: .user, text: "Plan it."), Message(role: .assistant, text: "{")]

    /// A model on which Anthropic refuses a prefill (its profile's `rejectsPrefill`).
    static let rejectsPrefillModel = "claude-sonnet-5-5"

    /// An adapter under test, with the transport whose open count proves a refusal was pre-dispatch.
    private struct Adapter {
        let name: String
        let model: any LanguageModel
        let transport: RecordingTransport
    }

    /// The HTTP adapters that cannot search (Apple's is pinned in `NeutralRefusalAppleTests`).
    private func nonSearching() -> [Adapter] {
        let (chat, chatTransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let (responses, responsesTransport) = makeResponses(.replay(Fixtures.responsesText))
        return [
            Adapter(name: "chat", model: chat, transport: chatTransport),
            Adapter(name: "responses", model: responses, transport: responsesTransport)
        ]
    }

    /// All three HTTP adapters, Anthropic included.
    private func allHTTP() -> [Adapter] {
        let (anthropic, anthropicTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        return nonSearching() + [Adapter(name: "anthropic", model: anthropic, transport: anthropicTransport)]
    }

    private func refusal(
        _ model: any LanguageModel, _ request: ModelRequest, adapter: String
    ) async -> (field: String, reason: String)? {
        let result = await collect(model, request)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("\(adapter): expected .invalidRequest, got \(String(describing: result.error))")
            return nil
        }
        #expect(result.events.isEmpty, "\(adapter) emitted events before refusing")
        return (field, reason)
    }

    // MARK: Complete reason strings

    @Test func webSearchIsRefusedWithTheCompleteReasonByTheAdaptersThatCannotSearch() async {
        let request = searchRequest(WebSearchOptions())
        for adapter in nonSearching() {
            let outcome = await refusal(adapter.model, request, adapter: adapter.name)
            #expect(outcome?.field == "webSearch", "\(adapter.name)")
            #expect(outcome?.reason == Self.webSearchReason, "\(adapter.name)")
            #expect(adapter.transport.openCount.get() == 0, "\(adapter.name) opened its transport")
        }
    }

    @Test func schemaPlusToolsIsRefusedWithTheCompleteReasonByEveryHTTPAdapter() async {
        for adapter in allHTTP() {
            let outcome = await refusal(adapter.model, structuredPlusToolsRequest, adapter: adapter.name)
            #expect(outcome?.field == "responseSchema+tools", "\(adapter.name)")
            #expect(outcome?.reason == Self.schemaPlusToolsReason, "\(adapter.name)")
            #expect(adapter.transport.openCount.get() == 0, "\(adapter.name) opened its transport")
        }
    }

    // MARK: The Responses adapter's schema walk (MinItemsProviderTests covers Chat and Anthropic)

    @Test func responsesRefusesANegativeResponseSchemaWithoutOpeningTheTransport() async {
        let (model, transport) = makeResponses(.replay(Fixtures.responsesText))
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")], responseSchema: Self.negativeSchema
        )
        let outcome = await refusal(model, request, adapter: "responses")
        #expect(outcome?.field == "root.readings")
        #expect(outcome?.reason.contains("minItems") == true)
        #expect(transport.openCount.get() == 0)
    }

    @Test func responsesRefusesANegativeToolParameterWithoutOpeningTheTransport() async {
        let (model, transport) = makeResponses(.replay(Fixtures.responsesText))
        let request = ModelRequest(messages: [Message(role: .user, text: "Tag these.")], tools: [Self.negativeTool])
        let outcome = await refusal(model, request, adapter: "responses")
        #expect(outcome?.field == "root.tags")
        #expect(outcome?.reason.contains("minItems") == true)
        #expect(transport.openCount.get() == 0)
    }

    // MARK: Precedence when one request breaks several rules

    @Test func webSearchWinsOverSchemaPlusToolsWhereSearchIsUnsupported() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")],
            tools: [weatherTool],
            responseSchema: structuredSchema,
            webSearch: WebSearchOptions()
        )
        for adapter in nonSearching() {
            let outcome = await refusal(adapter.model, request, adapter: adapter.name)
            #expect(outcome?.field == "webSearch", "\(adapter.name)")
            #expect(adapter.transport.openCount.get() == 0, "\(adapter.name) opened its transport")
        }
    }

    @Test func schemaPlusToolsWinsOverAnUnhonourableSchema() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")],
            tools: [weatherTool],
            responseSchema: Self.negativeSchema
        )
        for adapter in allHTTP() {
            let outcome = await refusal(adapter.model, request, adapter: adapter.name)
            #expect(outcome?.field == "responseSchema+tools", "\(adapter.name)")
            #expect(adapter.transport.openCount.get() == 0, "\(adapter.name) opened its transport")
        }
    }

    @Test func anthropicRefusesAPrefillBeforeWalkingTheSchema() async {
        let (model, transport) = makeAnthropic(
            .replay(Fixtures.structuredOutputAnswer(model: Self.rejectsPrefillModel)), model: Self.rejectsPrefillModel
        )
        let request = ModelRequest(messages: Self.prefill, responseSchema: Self.negativeSchema)
        let outcome = await refusal(model, request, adapter: "anthropic")
        #expect(outcome?.field == "messages")
        #expect(transport.openCount.get() == 0)
    }

    @Test func anthropicRefusesSchemaPlusSearchBeforeAPrefill() async {
        let (model, transport) = makeAnthropic(
            .replay(Fixtures.structuredOutputAnswer(model: Self.rejectsPrefillModel)), model: Self.rejectsPrefillModel
        )
        let request = ModelRequest(
            messages: Self.prefill, responseSchema: structuredSchema, webSearch: WebSearchOptions()
        )
        let outcome = await refusal(model, request, adapter: "anthropic")
        #expect(outcome?.field == "responseSchema+webSearch")
        #expect(transport.openCount.get() == 0)
    }

    @Test func anthropicValidatesItsSearchOptionsBeforeWalkingTheTools() async {
        let (model, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        let request = searchRequest(WebSearchOptions(maxUses: 0), tools: [Self.negativeTool])
        let outcome = await refusal(model, request, adapter: "anthropic")
        #expect(outcome?.field == "webSearch.maxUses")
        #expect(transport.openCount.get() == 0)
    }
}
