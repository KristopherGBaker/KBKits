import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import KBLLMRuntime
import Testing

/// The parsed JSON bodies of every request a transport saw, in order.
func requestBodies(_ transport: RecordingTransport) -> [[String: Any]] {
    transport.requests.get().map { spec in
        (try? JSONSerialization.jsonObject(with: spec.body ?? Data())) as? [String: Any] ?? [:]
    }
}

/// A JSON value rendered with sorted keys and unescaped slashes, so two values compare by
/// content regardless of the key order a serializer happened to choose.
func canonicalJSON(_ value: Any?) -> String {
    guard let value,
          let data = try? JSONSerialization.data(
              withJSONObject: value,
              options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
          )
    else { return "<nil>" }
    return String(bytes: data, encoding: .utf8) ?? "<undecodable>"
}

/// `canonicalJSON` of a JSON literal, for writing an expected value as the wire would.
func canonicalJSON(literal: String) -> String {
    canonicalJSON(try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]))
}

/// A plain question, with and without search, so the only difference on the wire is the tool.
func searchRequest(_ webSearch: WebSearchOptions?, tools: [ToolDefinition] = []) -> ModelRequest {
    ModelRequest(
        messages: [Message(role: .user, text: "What changed in Swift this week?")],
        tools: tools,
        webSearch: webSearch
    )
}

/// Request shaping and pre-dispatch refusal for server-side web search.
@Suite struct WebSearchRequestTests {
    private func tools(_ request: ModelRequest) async -> String {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        let result = await collect(anth, request)
        #expect(result.error == nil)
        return canonicalJSON(requestBodies(transport).first?["tools"])
    }

    @Test func withoutSearchTheBodyCarriesNoSearchToolAndKeepsItsSerialization() async {
        // No tools at all: no `tools` key, exactly as before the field existed.
        #expect(await tools(searchRequest(nil)) == "<nil>")
        // Client tools only: just the client tool.
        let clientOnly = await tools(searchRequest(nil, tools: [weatherTool]))
        #expect(!clientOnly.contains("web_search"))
        #expect(clientOnly.contains("get_weather"))
        // The default `webSearch` and an explicit nil produce the same body. (Compared by
        // content: the serializer's key order varies per dictionary, which it always has.)
        let (implicit, implicitTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(implicit, ModelRequest(messages: [Message(role: .user, text: "a/b")]))
        let (explicit, explicitTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(explicit, ModelRequest(messages: [Message(role: .user, text: "a/b")], webSearch: nil))
        let implicitBody = requestBodies(implicitTransport).first
        #expect(implicitBody?["messages"] != nil)
        #expect(canonicalJSON(implicitBody) == canonicalJSON(requestBodies(explicitTransport).first))
        // Serialization is untouched for a request without search: a `/` is still escaped the
        // way it always was. Only a search request writes slashes verbatim.
        let raw = String(bytes: implicitTransport.requests.get().first?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(raw.contains(#"a\/b"#))
        let (searching, searchingTransport) = makeAnthropic(.replay(Fixtures.anthropicWithUsage))
        _ = await collect(searching, ModelRequest(
            messages: [Message(role: .user, text: "a/b")],
            webSearch: WebSearchOptions()
        ))
        let searchingRaw = String(bytes: searchingTransport.requests.get().first?.body ?? Data(), encoding: .utf8)
        #expect(searchingRaw?.contains(#""a/b""#) == true)
    }

    @Test func searchAddsExactlyTheDocumentedEntry() async {
        #expect(
            await tools(searchRequest(WebSearchOptions()))
                == canonicalJSON(literal: #"[{"type":"web_search_20250305","name":"web_search"}]"#)
        )
    }

    @Test func maxUsesAndTheAllowListRideTheEntry() async {
        let options = WebSearchOptions(maxUses: 3, allowedDomains: ["swift.org", "developer.apple.com"])
        #expect(
            await tools(searchRequest(options))
                == canonicalJSON(literal: #"[{"type":"web_search_20250305","name":"web_search","max_uses":3,"#
                    + #""allowed_domains":["swift.org","developer.apple.com"]}]"#)
        )
    }

    @Test func theBlockListRidesTheEntryAlone() async {
        let options = WebSearchOptions(blockedDomains: ["example.com"])
        #expect(
            await tools(searchRequest(options))
                == canonicalJSON(literal: #"[{"type":"web_search_20250305","name":"web_search","#
                    + #""blocked_domains":["example.com"]}]"#)
        )
    }

    @Test func clientToolsAndTheSearchToolTravelTogether() async {
        let body = await tools(searchRequest(WebSearchOptions(maxUses: 1), tools: [weatherTool]))
        let parsed = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]] ?? []
        #expect(parsed.count == 2)
        #expect(parsed.first?["name"] as? String == "get_weather")
        #expect(parsed.last?["type"] as? String == "web_search_20250305")
        #expect(parsed.last?["max_uses"] as? Int == 1)
    }

    // MARK: Refusals, all before the transport opens

    private func refusal(_ request: ModelRequest) async -> (field: String?, opens: Int) {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicTwoSearches))
        let result = await collect(anth, request)
        guard case .invalidRequest(let field, _) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return (nil, transport.openCount.get())
        }
        #expect(result.events.isEmpty)
        return (field, transport.openCount.get())
    }

    @Test func bothDomainListsAreRefused() async {
        let options = WebSearchOptions(allowedDomains: ["swift.org"], blockedDomains: ["example.com"])
        let outcome = await refusal(searchRequest(options))
        #expect(outcome.field == "webSearch.allowedDomains+blockedDomains")
        #expect(outcome.opens == 0)
        // And by the core check every adapter shares, with no adapter involved.
        #expect(throws: KBLLMError.self) { try options.validate() }
    }

    @Test func aNonPositiveMaxUsesIsRefused() async {
        for maxUses in [0, -1] {
            let outcome = await refusal(searchRequest(WebSearchOptions(maxUses: maxUses)))
            #expect(outcome.field == "webSearch.maxUses")
            #expect(outcome.opens == 0)
        }
        // The boundary that IS allowed.
        #expect(throws: Never.self) { try WebSearchOptions(maxUses: 1).validate() }
    }

    @Test func structuredOutputPlusSearchIsRefused() async {
        let request = ModelRequest(
            messages: [Message(role: .user, text: "Make a card.")],
            responseSchema: structuredSchema,
            webSearch: WebSearchOptions()
        )
        let outcome = await refusal(request)
        #expect(outcome.field == "responseSchema+webSearch")
        #expect(outcome.opens == 0)
    }

    // MARK: Capability, and the adapters that cannot search

    @Test func onlyAnthropicReportsWebSearchAndWrappingKeepsTheAnswer() {
        let anthropic: any LanguageModel = makeAnthropic(.replay([])).0
        let openAI: any LanguageModel = makeOpenAI(.replay([])).0
        #expect(anthropic.supportsWebSearch)
        #expect(!openAI.supportsWebSearch)
        #expect(anthropic.normalizingErrors().supportsWebSearch)
        let sink = SpyLogSink(records: Box([]))
        #expect(wrap(anthropic, with: [LoggingMiddleware(sink: sink)]).supportsWebSearch)
        #expect(!wrap(openAI, with: [LoggingMiddleware(sink: sink)]).supportsWebSearch)
    }

    @Test func openAIRefusesWebSearchBeforeOpeningTheTransport() async {
        let (openAI, transport) = makeOpenAI(.replay(Fixtures.openAIWithUsage))
        let result = await collect(openAI, searchRequest(WebSearchOptions()))
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "webSearch")
        #expect(reason.contains("web search"))
        #expect(transport.openCount.get() == 0)
        #expect(result.events.isEmpty)
        // The same request without search goes through, so the refusal is about search alone.
        let (plain, plainTransport) = makeOpenAI(.replay(Fixtures.openAIWithUsage))
        #expect(await collect(plain, searchRequest(nil)).error == nil)
        #expect(plainTransport.openCount.get() == 1)
    }
}
