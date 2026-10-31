import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMURLSession
import Testing

// The opt-in live check of server-side web search: a real Anthropic call over the real
// transport, which the replayed fixtures cannot prove (that the API accepts the tool entry this
// adapter writes, and that what it streams back parses). It lives in this target because it is
// the one test target allowed real networking. It runs ONLY with `KBLLM_LIVE_WEB_SEARCH=1` and a
// non-empty `ANTHROPIC_API_KEY`; otherwise the suite is disabled, so a default run spends
// nothing. A run costs one or two searches (billed per search) plus tokens. The model defaults
// to a current Sonnet and can be overridden with `KBLLM_LIVE_ANTHROPIC_MODEL`.

private let liveEnvironment = ProcessInfo.processInfo.environment

private let liveWebSearchEnabled =
    liveEnvironment["KBLLM_LIVE_WEB_SEARCH"] == "1" && !(liveEnvironment["ANTHROPIC_API_KEY"] ?? "").isEmpty

@Suite(.enabled(if: liveWebSearchEnabled, "set KBLLM_LIVE_WEB_SEARCH=1 and ANTHROPIC_API_KEY to run"))
struct LiveWebSearchTests {
    @Test(.timeLimit(.minutes(2)))
    func anthropicSearchesTheWebAndCitesWhatItFound() async throws {
        let model = AnthropicModel(
            model: liveEnvironment["KBLLM_LIVE_ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5",
            credentialKey: "ANTHROPIC_API_KEY",
            transport: KBLLMURLSession(),
            credentials: EnvironmentCredentialStore()
        )
        let request = ModelRequest(
            messages: [Message(
                role: .user,
                text: "Search the web: what is the latest stable release of the Swift programming language? "
                    + "Answer in one sentence and cite your source."
            )],
            options: GenerationOptions(maxOutputTokens: 1024),
            webSearch: WebSearchOptions(maxUses: 2)
        )
        let response = try await model.complete(request)
        #expect(!response.content.isEmpty)
        #expect(!response.webSearches.isEmpty)
        #expect(response.webSearches.allSatisfy { !$0.query.isEmpty && $0.outcome != nil })
        #expect((response.usage?.webSearchRequests ?? 0) >= 1)
        for citation in response.citations {
            #expect(citation.range(in: response.content) != nil)
        }
    }
}
