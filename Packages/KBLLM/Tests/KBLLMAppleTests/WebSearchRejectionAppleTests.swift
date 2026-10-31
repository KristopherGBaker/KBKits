import Foundation
import KBLLM
import KBLLMApple
import Testing

// `AppleModel` cannot search the web, on device or on Private Cloud Compute, so a request that
// asks for server-side search is refused before any backend run rather than answered from the
// model's memory. Paired with the same request minus `webSearch` on the same fully capable
// backend, so a gate that refused everything fails too.
@Suite struct WebSearchRejectionAppleTests {
    private let capable: Set<FoundationModelCapability> = [.vision, .guidedGeneration, .toolCalling]

    private func request(webSearch: WebSearchOptions?) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "What changed in Swift this week?")], webSearch: webSearch)
    }

    @Test func appleModelReportsNoWebSearchSupport() {
        let model: any LanguageModel = AppleModel(backend: FakeFoundationModelBackend(script: .snapshots(["hi"])))
        #expect(model.supportsWebSearch == false)
    }

    @Test func aWebSearchRequestIsRefusedBeforeAnyBackendRun() async {
        let fake = FakeFoundationModelBackend(capabilities: capable, script: .snapshots(["Nothing new."]))
        let result = await collect(AppleModel(backend: fake), request(webSearch: WebSearchOptions()))
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "webSearch")
        #expect(reason.contains("web search"))
        #expect(fake.inferenceCount == 0)
        #expect(result.events.isEmpty)
    }

    @Test func theSameRequestWithoutWebSearchRuns() async {
        let fake = FakeFoundationModelBackend(capabilities: capable, script: .snapshots(["Nothing new."]))
        let result = await collect(AppleModel(backend: fake), request(webSearch: nil))
        #expect(result.error == nil)
        #expect(fake.inferenceCount == 1)
        #expect(result.events.contains(.contentDelta("Nothing new.")))
    }
}
