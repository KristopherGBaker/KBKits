import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMURLSession
import Testing

// The opt-in live check of structured output on current Anthropic models, the way a planning
// feature uses it: a structured answer alone, and a web search whose findings feed a second,
// structured request (the two cannot share one). The replayed fixtures pin the bytes; only a
// real call proves the API accepts the `output_config.format` body and that what it streams
// back decodes. It runs ONLY with `KBLLM_LIVE_STRUCTURED=1` and a non-empty `ANTHROPIC_API_KEY`;
// otherwise the suite is disabled and a default run spends nothing. It runs against
// `claude-sonnet-5-5` and `claude-sonnet-4-5`, or the comma-separated ids in
// `KBLLM_LIVE_ANTHROPIC_MODELS`. A run costs a few searches plus tokens per model.

private let environment = ProcessInfo.processInfo.environment

private let liveStructuredEnabled =
    environment["KBLLM_LIVE_STRUCTURED"] == "1" && !(environment["ANTHROPIC_API_KEY"] ?? "").isEmpty

private let liveModels = (environment["KBLLM_LIVE_ANTHROPIC_MODELS"] ?? "claude-sonnet-5-5,claude-sonnet-4-5")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }

private let planSchema: JSONSchema = .object(
    properties: [
        "topic": .string(description: "what is being learned"),
        "steps": .array(
            items: .object(
                properties: [
                    "title": .string(description: "the step, in a few words"),
                    "why": .string(description: "one sentence on why it matters")
                ],
                required: ["title", "why"],
                description: "one step"
            ),
            description: "the ordered steps",
            minItems: 3
        )
    ],
    required: ["topic", "steps"],
    description: "a short learning plan"
)

private struct Plan: Decodable {
    struct Step: Decodable {
        let title: String
        let why: String
    }

    let topic: String
    let steps: [Step]
}

@Suite(.enabled(if: liveStructuredEnabled, "set KBLLM_LIVE_STRUCTURED=1 and ANTHROPIC_API_KEY to run"))
struct LiveStructuredOutputTests {
    private func model(_ id: String) -> AnthropicModel {
        AnthropicModel(
            model: id,
            credentialKey: "ANTHROPIC_API_KEY",
            transport: KBLLMURLSession(),
            credentials: EnvironmentCredentialStore()
        )
    }

    private func plan(_ id: String, prompt: String) async throws -> Plan {
        let response = try await model(id).complete(ModelRequest(
            messages: [Message(role: .user, text: prompt)],
            responseSchema: planSchema,
            options: GenerationOptions(maxOutputTokens: 2048)
        ))
        #expect(response.finishReason == .stop)
        return try JSONDecoder().decode(Plan.self, from: Data(response.content.utf8))
    }

    @Test(.timeLimit(.minutes(2)), arguments: liveModels)
    func aStructuredPlanDecodes(model id: String) async throws {
        let plan = try await plan(id, prompt: "Make a three to five step plan for learning Swift concurrency.")
        #expect(plan.steps.count >= 3)
        #expect(!plan.topic.isEmpty)
    }

    @Test(.timeLimit(.minutes(3)), arguments: liveModels)
    func searchFindingsFeedAStructuredPlan(model id: String) async throws {
        let research = try await model(id).complete(ModelRequest(
            messages: [Message(
                role: .user,
                text: "Search the web: what is the latest stable Swift release and its headline features? "
                    + "Answer in a short paragraph."
            )],
            options: GenerationOptions(maxOutputTokens: 1024),
            webSearch: WebSearchOptions(maxUses: 2)
        ))
        #expect(!research.content.isEmpty)
        #expect(!research.webSearches.isEmpty)
        let plan = try await plan(
            id,
            prompt: "Using these findings, make a three to five step plan for learning what is new in Swift.\n\n"
                + research.content
        )
        #expect(plan.steps.count >= 3)
    }
}
