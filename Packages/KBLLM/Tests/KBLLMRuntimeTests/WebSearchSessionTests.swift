import Foundation
import KBLLM
import KBLLMRuntime
import Testing

// `AgentSession` rebuilds the request for every turn, so a field it does not copy is silently
// dropped. These pin that `webSearch` reaches every turn's model call, and that the search
// events a turn streams neither break the loop nor leak into the assistant history.
@Suite struct WebSearchSessionTests {
    private let options = WebSearchOptions(maxUses: 2, blockedDomains: ["example.com"])

    @Test func everyTurnCarriesTheCallersWebSearchOptions() async throws {
        let requests = Box<[ModelRequest]>([])
        let call = ToolCallRecord(id: "c1", name: "lookup", arguments: Data("{}".utf8))
        let model = ScriptedModel(
            turns: [
                [.toolCall(call), .completed(.toolCalls)],
                [.contentDelta("done"), .completed(.stop)]
            ],
            requests: requests
        )
        let tool = countingTool(named: "lookup", counter: Box(0))
        let session = AgentSession(model: model, tools: ToolBox(tools: [tool]), maxToolRoundTrips: 4)
        let request = ModelRequest(messages: [Message(role: .user, text: "research")], webSearch: options)
        _ = try await session.run(request)
        #expect(requests.get().count == 2)
        #expect(requests.get().allSatisfy { $0.webSearch == options })
    }

    /// The same rebuild once dropped `options`, so a caller's `maxOutputTokens` never reached the
    /// model and a long structured answer was cut off at the adapter's fallback limit.
    @Test func everyTurnCarriesTheCallersGenerationOptions() async throws {
        let requests = Box<[ModelRequest]>([])
        let call = ToolCallRecord(id: "c1", name: "lookup", arguments: Data("{}".utf8))
        let model = ScriptedModel(
            turns: [
                [.toolCall(call), .completed(.toolCalls)],
                [.contentDelta("done"), .completed(.stop)]
            ],
            requests: requests
        )
        let session = AgentSession(
            model: model,
            tools: ToolBox(tools: [countingTool(named: "lookup", counter: Box(0))]),
            maxToolRoundTrips: 4
        )
        let generation = GenerationOptions(temperature: 0.3, maxOutputTokens: 16_000, topP: 0.9)
        _ = try await session.run(ModelRequest(messages: [Message(role: .user, text: "plan")], options: generation))
        #expect(requests.get().count == 2)
        #expect(requests.get().allSatisfy { $0.options == generation })
    }

    @Test func searchEventsLeaveTheAnswerAndHistoryClean() async throws {
        let model = ScriptedModel(turns: [[
            .webSearchCall(WebSearchCall(id: "s1", query: "swift news")),
            .webSearchResult(WebSearchResult(searchID: "s1", outcome: .failed(.unavailable))),
            .contentDelta("No results."),
            .citation(WebSearchCitation(url: "https://swift.org", title: nil, citedText: "x", utf16Range: 0..<3)),
            .usage(TokenUsage(inputTokens: 1, outputTokens: 2, webSearchRequests: 1)),
            .completed(.stop)
        ]])
        let session = AgentSession(model: model, tools: ToolBox(tools: []), maxToolRoundTrips: 4)
        let request = ModelRequest(messages: [Message(role: .user, text: "q")], webSearch: options)
        let result = try await session.run(request)
        #expect(result.content == "No results.")
        #expect(result.finishReason == .stop)
        #expect(result.usage?.webSearchRequests == 1)
        #expect(result.messages.last == Message(role: .assistant, text: "No results."))
    }
}
