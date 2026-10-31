import Foundation
import KBLLM
import KBLLMRuntime
import Testing
@testable import KBLLMAnthropic

// Structured output against the CURRENT Anthropic models, offline: each test replays a
// recorded-shape transcript and reads the request body the adapter wrote.
//
// The two live failures this pins: `claude-sonnet-5-5` answered every structured request with a
// 400, because structured output was a forced `tool_choice`, which the 5.x models reject; and
// `claude-sonnet-4-5` accepted the request but the structured answer failed to decode, which
// the session and stream tests below reproduce.

/// A learning plan, nested the way a real plan is, with a minimum the structured-outputs
/// grammar cannot carry (3).
let learnPlanSchema: JSONSchema = .object(
    properties: [
        "topic": .string(description: "what is being learned"),
        "steps": .array(
            items: .object(
                properties: [
                    "title": .string(description: "the step"),
                    "resources": .array(items: .string(description: nil), description: "links")
                ],
                required: ["title", "resources"],
                description: "one step"
            ),
            description: "the ordered steps",
            minItems: 3
        )
    ],
    required: ["topic", "steps"],
    description: "a learning plan"
)

/// What a consumer decodes the answer into, as an app does with a structured plan.
struct LearnPlan: Decodable, Equatable {
    struct Step: Decodable, Equatable {
        let title: String
        let resources: [String]
    }

    let topic: String
    let steps: [Step]
}

func learnPlanRequest(_ messages: [Message]? = nil, options: GenerationOptions = GenerationOptions()) -> ModelRequest {
    ModelRequest(
        messages: messages ?? [Message(role: .user, text: "Plan how I learn Swift concurrency.")],
        responseSchema: learnPlanSchema,
        options: options
    )
}

/// Every object node in a serialized schema, at any depth.
func schemaObjects(_ node: Any?) -> [[String: Any]] {
    guard let node = node as? [String: Any] else { return [] }
    let children = (node["properties"] as? [String: Any])?.values.flatMap { schemaObjects($0) } ?? []
    return (node["type"] as? String == "object" ? [node] : []) + children + schemaObjects(node["items"])
}

@Suite struct CurrentModelStructuredTests {
    static let structuredOutputModels = [
        "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-mythos-5-1",
        "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-opus-4-6", "claude-haiku-4-5"
    ]

    static let legacyModels = [
        "claude-3-5-sonnet-20241022", "claude-sonnet-4-20250514", "claude-opus-4-1", "qwen2.5-7b-instruct"
    ]

    // MARK: The request

    @Test(arguments: structuredOutputModels)
    func structuredRequestUsesOutputConfigAndNeverForcesAToolChoice(model: String) async throws {
        let (adapter, transport) = makeAnthropic(.replay(Fixtures.structuredOutputAnswer(model: model)), model: model)
        let result = await collect(adapter, learnPlanRequest())
        #expect(result.error == nil)
        let body = try #require(requestBodies(transport).first)

        // No tool route at all: no tool_choice (forced or otherwise), no synthetic tool.
        #expect(body["tool_choice"] == nil)
        #expect(body["tools"] == nil)
        // The deprecated top-level field is not used, and nothing the current models reject is sent.
        #expect(body["output_format"] == nil)
        #expect(body["thinking"] == nil)
        #expect((body["messages"] as? [[String: Any]])?.last?["role"] as? String == "user")

        let format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        // Every object closed and carrying `required`, at every depth (root and step).
        let objects = schemaObjects(schema)
        #expect(objects.count == 2)
        for object in objects {
            #expect(object["additionalProperties"] as? Bool == false)
            #expect(object["required"] is [String])
        }
        // A minimum the grammar cannot carry is sent as 1 and stated in the description.
        let steps = try #require((schema["properties"] as? [String: Any])?["steps"] as? [String: Any])
        #expect(steps["minItems"] as? Int == 1)
        #expect((steps["description"] as? String)?.contains("at least 3 items") == true)
    }

    @Test(arguments: legacyModels)
    func legacyRouteOffersAStrictToolWithoutForcingIt(model: String) async throws {
        let transcript = Fixtures.anthropicStructured(
            toolName: AnthropicModel.structuredToolName,
            fragments: [Fixtures.learnPlanDocument]
        )
        let (adapter, transport) = makeAnthropic(.replay(transcript), model: model)
        let result = await collect(adapter, learnPlanRequest())
        #expect(result.error == nil)
        let body = try #require(requestBodies(transport).first)

        #expect(canonicalJSON(body["tool_choice"]) == canonicalJSON(literal: #"{"type":"auto"}"#))
        #expect(body["output_config"] == nil)
        let tool = try #require((body["tools"] as? [[String: Any]])?.first)
        #expect(tool["name"] as? String == AnthropicModel.structuredToolName)
        #expect(tool["strict"] as? Bool == true)
        for object in schemaObjects(tool["input_schema"]) {
            #expect(object["additionalProperties"] as? Bool == false)
        }
    }

    // MARK: The answer

    @Test(arguments: ["claude-sonnet-5-5", "claude-sonnet-4-5"])
    func structuredOutputAnswerJoinsItsTextBlocksAndDecodes(model: String) async throws {
        let (adapter, _) = makeAnthropic(.replay(Fixtures.structuredOutputAnswer(model: model)), model: model)
        let result = await collect(adapter, learnPlanRequest())
        #expect(result.error == nil)
        #expect(toolCallRecords(result.events).isEmpty)
        #expect(result.events.last == .completed(.stop))

        let response = try await adapter.complete(learnPlanRequest())
        #expect(response.content == Fixtures.learnPlanDocument)
        let plan = try JSONDecoder().decode(LearnPlan.self, from: Data(response.content.utf8))
        #expect(plan.steps.count == 3)
        #expect(plan.steps[2].resources == [#"a "quoted" note"#])
    }

    @Test func legacyRemarkBeforeTheToolCallIsNotPartOfTheDocument() async {
        let transcript = Fixtures.legacyRemarkThenTool(
            toolName: AnthropicModel.structuredToolName,
            document: Fixtures.learnPlanDocument
        )
        let result = await collect(makeAnthropic(.replay(transcript)).0, learnPlanRequest())
        #expect(result.error == nil)
        let content = result.events.reduce(into: "") { joined, event in
            if case .contentDelta(let delta) = event { joined += delta }
        }
        #expect(content == Fixtures.learnPlanDocument)
        #expect(result.events.last == .completed(.stop))
    }

    // MARK: The claude-sonnet-4-5 decode failure

    /// `AgentSession` rebuilt each turn's request without the caller's `options`, so a plan asked
    /// for with a large `maxOutputTokens` went out at the adapter's 4096 fallback, was cut off,
    /// and failed to decode. The limit the caller set must be the one on the wire.
    @Test func aSessionSendsTheCallersOutputLimit() async throws {
        let model = "claude-sonnet-4-5"
        let (adapter, transport) = makeAnthropic(.replay(Fixtures.structuredOutputAnswer(model: model)), model: model)
        let session = AgentSession(model: adapter)
        let request = learnPlanRequest(options: GenerationOptions(temperature: 0.2, maxOutputTokens: 16_000))
        let result = try await session.run(request)
        let body = try #require(requestBodies(transport).first)
        #expect(body["max_tokens"] as? Int == 16_000)
        #expect(body["temperature"] as? Double == 0.2)
        #expect(try JSONDecoder().decode(LearnPlan.self, from: Data(result.content.utf8)).steps.count == 3)
    }

    /// A plan cut off at the output limit is reported as exactly that, not as a model that
    /// ignored the schema.
    @Test func aTruncatedAnswerSaysItHitTheOutputLimit() async {
        let model = "claude-sonnet-4-5"
        let (adapter, _) = makeAnthropic(.replay(Fixtures.structuredOutputTruncated(model: model)), model: model)
        let result = await collect(adapter, learnPlanRequest())
        guard case .schemaViolation(let expected, let received) = result.error else {
            Issue.record("expected .schemaViolation, got \(String(describing: result.error))")
            return
        }
        #expect(expected.contains("output token limit"))
        #expect(received == String(Fixtures.learnPlanDocument.prefix(60)))
    }

    /// An overload mid-stream used to end the stream quietly, so the half-written plan failed as
    /// a schema violation. It is the 529 it is, which a caller's retry policy can act on.
    @Test func anInBandErrorIsItsStatusNotASchemaViolation() async {
        let model = "claude-sonnet-4-5"
        let (adapter, _) = makeAnthropic(.replay(Fixtures.structuredOutputOverloaded(model: model)), model: model)
        let result = await collect(adapter, learnPlanRequest())
        #expect(result.error == .httpStatus(code: 529, message: "overloaded_error: Overloaded"))
        #expect(!result.events.contains { if case .completed = $0 { true } else { false } })
    }

    // MARK: Prefill

    @Test func aTrailingAssistantTurnIsRefusedOnlyWhereTheModelRejectsIt() async {
        let messages = [Message(role: .user, text: "Plan it."), Message(role: .assistant, text: "{")]
        let (current, currentTransport) = makeAnthropic(
            .replay(Fixtures.structuredOutputAnswer(model: "claude-sonnet-5-5")),
            model: "claude-sonnet-5-5"
        )
        let refused = await collect(current, ModelRequest(messages: messages))
        guard case .invalidRequest(let field, let reason) = refused.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: refused.error))")
            return
        }
        #expect(field == "messages")
        #expect(reason.contains("claude-sonnet-5-5"))
        #expect(currentTransport.openCount.get() == 0)

        // Sonnet 4.5 still accepts a prefill, so the same request is sent.
        let (older, olderTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: "claude-sonnet-4-5")
        #expect(await collect(older, ModelRequest(messages: messages)).error == nil)
        #expect(olderTransport.openCount.get() == 1)
    }
}
