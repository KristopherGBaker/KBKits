import Foundation
import KBLLM
import Testing
@testable import KBLLMAnthropic

// Web search against the CURRENT Anthropic models, offline: the tool version each model is sent,
// a mixed search turn decoded end to end, a failed search reported as data, and a paused turn
// continued in the container it ran in.
@Suite struct CurrentModelSearchTests {
    static let toolVersions: [(model: String, type: String)] = [
        ("claude-sonnet-5-5", "web_search_20260209"),
        ("claude-opus-5-5", "web_search_20260209"),
        ("claude-sonnet-5", "web_search_20260209"),
        ("claude-opus-4-6", "web_search_20260209"),
        ("claude-sonnet-4-6-20260115", "web_search_20260209"),
        ("anthropic.claude-opus-4-6-v1:0", "web_search_20260209"),
        ("claude-sonnet-4-5", "web_search_20250305"),
        ("claude-haiku-4-5", "web_search_20250305"),
        ("claude-fable-5-1", "web_search_20250305"),
        ("claude-3-5-sonnet-20241022", "web_search_20250305"),
        ("local-model", "web_search_20250305")
    ]

    @Test(arguments: toolVersions)
    func eachModelGetsTheSearchToolVersionItTakes(model: String, type: String) async throws {
        let (adapter, transport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage), model: model)
        let result = await collect(adapter, searchRequest(WebSearchOptions(maxUses: 3)))
        #expect(result.error == nil)
        let tools = try #require(requestBodies(transport).first?["tools"] as? [[String: Any]])
        // Exactly the one search tool: code execution is never declared beside it.
        #expect(tools.count == 1)
        #expect(tools.first?["type"] as? String == type)
        #expect(tools.first?["name"] as? String == "web_search")
        #expect(tools.first?["max_uses"] as? Int == 3)
    }

    // MARK: A mixed turn

    @Test func aMixedSearchTurnDecodesToItsTextInOrder() async throws {
        let (adapter, _) = makeAnthropic(.replay(Fixtures.currentMixedSearch), model: Fixtures.currentModel)
        let response = try await adapter.complete(searchRequest(WebSearchOptions()))

        // Every text block, in order; nothing from the search or code execution blocks.
        #expect(response.content == Fixtures.mixedSearchAnswer)
        #expect(response.finishReason == .stop)
        // The server tools are the API's own: none surfaces as a tool for the caller to run.
        #expect(response.toolCalls.isEmpty)
        #expect(response.usage?.webSearchRequests == 2)
        #expect(response.usage?.inputTokens == 2_210)

        // The code execution step is not a search.
        #expect(response.webSearches.map(\.query) == ["swift 6.2 release", "swift forums outage"])
        #expect(response.webSearches.first?.outcome == .sources([
            WebSearchSource(url: "https://swift.org/blog/swift-6.2-released/", title: "Swift 6.2 Released", pageAge: "2 days ago"),
            WebSearchSource(url: "https://forums.swift.org/", title: "Swift Forums", pageAge: nil)
        ]))

        let citation = try #require(response.citations.first)
        #expect(response.citations.count == 1)
        #expect(citation.url == "https://swift.org/blog/swift-6.2-released/")
        let span = try #require(citation.range(in: response.content))
        #expect(response.content[span] == "Swift 6.2 shipped this week.")
    }

    /// A search that failed arrives as an error OBJECT where the result list would be, inside an
    /// HTTP 200. It is the search's outcome, never a thrown error, and the answer still arrives.
    @Test func aFailedSearchIsAnOutcomeAndTheAnswerStillArrives() async throws {
        let (adapter, _) = makeAnthropic(.replay(Fixtures.currentMixedSearch), model: Fixtures.currentModel)
        let result = await collect(adapter, searchRequest(WebSearchOptions()))
        #expect(result.error == nil)
        #expect(result.events.contains(.webSearchResult(WebSearchResult(
            searchID: "srvtoolu_01B",
            outcome: .failed(.tooManyRequests)
        ))))
        // Only the two searches produce search events; the code execution result does not.
        let results = result.events.filter { if case .webSearchResult = $0 { true } else { false } }
        #expect(results.count == 2)
        #expect(result.events.last == .completed(.stop))
    }

    // MARK: pause_turn

    @Test func aPausedTurnContinuesInItsContainerAndMergesIntoOneAnswer() async throws {
        let (adapter, transport) = makeAnthropic(
            .sequence([Fixtures.currentPausedTurn, Fixtures.currentResumedTurn]),
            model: Fixtures.currentModel
        )
        let response = try await adapter.complete(searchRequest(WebSearchOptions()))
        #expect(response.content == "Checking the forecast. Mild, pack a light jacket.")
        #expect(response.finishReason == .stop)
        #expect(response.usage?.webSearchRequests == 1)

        let bodies = requestBodies(transport)
        #expect(bodies.count == 2)
        #expect(bodies.first?["container"] == nil)
        // The continuation names the container and ends on the paused assistant turn, echoed
        // block for block. That trailing turn is the documented continuation, not a refused prefill.
        #expect(bodies.last?["container"] as? String == "container_011CWpause")
        let echoed = try #require((bodies.last?["messages"] as? [[String: Any]])?.last)
        #expect(echoed["role"] as? String == "assistant")
        let blocks = try #require(echoed["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["text", "server_tool_use", "web_search_tool_result"])
        #expect(canonicalJSON(blocks[1]["input"]) == canonicalJSON(literal: #"{"query":"kyoto weather"}"#))
        // The encrypted result travels back byte for byte.
        let raw = String(bytes: transport.requests.get().last?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(raw.contains("EkKy/oto+W==/+/"))
    }

    @Test func structuredOutputAndSearchStillTravelSeparately() async {
        let (adapter, transport) = makeAnthropic(.replay(Fixtures.currentMixedSearch), model: Fixtures.currentModel)
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Plan it.")],
            responseSchema: learnPlanSchema,
            webSearch: WebSearchOptions()
        )
        let result = await collect(adapter, request)
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "responseSchema+webSearch")
        #expect(reason.contains("citations"))
        #expect(transport.openCount.get() == 0)
    }
}

/// The id parse every request shape above hangs on.
@Suite struct AnthropicModelProfileTests {
    private struct Case {
        let model: String
        let version: AnthropicModelProfile.Version?
        let family: String?

        init(_ model: String, _ version: (Int, Int)?, _ family: String?) {
            self.model = model
            self.version = version.map { AnthropicModelProfile.Version(major: $0.0, minor: $0.1) }
            self.family = family
        }
    }

    @Test func versionsAreReadFromEveryIdForm() {
        let cases = [
            Case("claude-sonnet-5-5", (5, 5), "sonnet"),
            Case("claude-sonnet-4-5-20250929", (4, 5), "sonnet"),
            Case("claude-sonnet-4-20250514", (4, 0), "sonnet"),
            Case("claude-opus-4-1", (4, 1), "opus"),
            Case("claude-3-5-sonnet-20241022", (3, 5), "sonnet"),
            Case("claude-3-haiku-20240307", (3, 0), "haiku"),
            Case("anthropic.claude-opus-4-6-v1:0", (4, 6), "opus"),
            Case("claude-sonnet-4-5@20250929", (4, 5), "sonnet"),
            Case("Claude-Fable-5-1", (5, 1), "fable"),
            Case("qwen2.5-7b-instruct", nil, nil),
            Case("claude-sonnet-latest", nil, "sonnet")
        ]
        for item in cases {
            let profile = AnthropicModelProfile(item.model)
            #expect(profile.version == item.version, "\(item.model)")
            #expect(profile.family == item.family, "\(item.model)")
        }
    }

    @Test func capabilitiesFollowTheGeneration() {
        let sonnet55 = AnthropicModelProfile("claude-sonnet-5-5")
        #expect(sonnet55.supportsStructuredOutputs && sonnet55.supportsDynamicWebSearch && sonnet55.rejectsPrefill)
        let sonnet45 = AnthropicModelProfile("claude-sonnet-4-5")
        #expect(sonnet45.supportsStructuredOutputs && !sonnet45.supportsDynamicWebSearch && !sonnet45.rejectsPrefill)
        let haiku45 = AnthropicModelProfile("claude-haiku-4-5")
        #expect(haiku45.supportsStructuredOutputs && !haiku45.supportsDynamicWebSearch)
        let opus41 = AnthropicModelProfile("claude-opus-4-1")
        #expect(!opus41.supportsStructuredOutputs && !opus41.rejectsPrefill)
        // An id this adapter cannot place gets the routes every model accepts.
        let unknown = AnthropicModelProfile("claude-sonnet-latest")
        #expect(!unknown.supportsStructuredOutputs && !unknown.supportsDynamicWebSearch && !unknown.rejectsPrefill)
    }
}
