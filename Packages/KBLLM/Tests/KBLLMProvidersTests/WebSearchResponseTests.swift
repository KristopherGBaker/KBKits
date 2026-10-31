import Foundation
import KBLLM
import KBLLMAnthropic
import Testing

/// Search activity parsed from replayed Anthropic streams into the neutral types, a failed
/// search surfacing as data, and `pause_turn` continuing with the paused turn echoed verbatim.
@Suite struct WebSearchResponseTests {
    private let search = searchRequest(WebSearchOptions(maxUses: 5))

    private let swiftReleaseSources = [
        WebSearchSource(url: "https://swift.org/blog/swift-6.2-released/", title: "Swift 6.2 Released", pageAge: "2 days ago"),
        WebSearchSource(url: "https://developer.apple.com/swift/whats-new/", title: "What's new in Swift", pageAge: nil)
    ]

    private let concurrencySources = [
        WebSearchSource(
            url: "https://www.swift.org/documentation/concurrency/",
            title: "Concurrency Guide",
            pageAge: "1 week ago"
        )
    ]

    // MARK: Two searches, results, citations and usage

    @Test func aStreamWithTwoSearchesParsesIntoTheNeutralEvents() async {
        let result = await collect(makeAnthropic(.replay(Fixtures.anthropicTwoSearches)).0, search)
        #expect(result.error == nil)
        // The emoji is two UTF-16 units, so "Swift 6.2 shipped this week." starts at 14, not 13.
        let expected: [ModelEvent] = [
            .contentDelta("🔎 Searching. "),
            .webSearchCall(WebSearchCall(id: "srvtoolu_01", query: "swift 6.2 release")),
            .webSearchResult(WebSearchResult(searchID: "srvtoolu_01", outcome: .sources(swiftReleaseSources))),
            .webSearchCall(WebSearchCall(id: "srvtoolu_02", query: "swift concurrency changes")),
            .webSearchResult(WebSearchResult(searchID: "srvtoolu_02", outcome: .sources(concurrencySources))),
            .contentDelta("Swift 6.2 shipped"),
            .contentDelta(" this week."),
            .citation(WebSearchCitation(
                url: "https://swift.org/blog/swift-6.2-released/",
                title: "Swift 6.2 Released",
                citedText: "Swift 6.2 is now available.",
                utf16Range: 14..<42
            )),
            .contentDelta(" Concurrency got simpler."),
            .citation(WebSearchCitation(
                url: "https://www.swift.org/documentation/concurrency/",
                title: "Concurrency Guide",
                citedText: "Approachable concurrency is on by default.",
                utf16Range: 42..<67
            )),
            .usage(TokenUsage(inputTokens: 2679, outputTokens: 510, webSearchRequests: 2)),
            .completed(.stop)
        ]
        #expect(result.events == expected)
    }

    @Test func theCollectedResponseJoinsQueriesToSourcesAndLocatesCitations() async throws {
        let response = try await makeAnthropic(.replay(Fixtures.anthropicTwoSearches)).0.complete(search)
        #expect(response.content == "🔎 Searching. Swift 6.2 shipped this week. Concurrency got simpler.")
        #expect(response.webSearches == [
            WebSearch(id: "srvtoolu_01", query: "swift 6.2 release", outcome: .sources(swiftReleaseSources)),
            WebSearch(id: "srvtoolu_02", query: "swift concurrency changes", outcome: .sources(concurrencySources))
        ])
        #expect(response.usage?.webSearchRequests == 2)
        #expect(response.finishReason == .stop)
        // Each citation's range picks out exactly the span it cites in the collected text.
        let cited = response.citations.map { citation in
            citation.range(in: response.content).map { String(response.content[$0]) }
        }
        #expect(cited == ["Swift 6.2 shipped this week.", " Concurrency got simpler."])
        // A range outside the text it is applied to is refused rather than clamped.
        #expect(response.citations.first?.range(in: "short") == nil)
    }

    @Test func aRequestWithoutSearchHasEmptySearchFieldsAndZeroCount() async throws {
        let response = try await makeAnthropic(.replay(Fixtures.anthropicWithUsage)).0.complete(weatherRequest)
        #expect(response.webSearches.isEmpty)
        #expect(response.citations.isEmpty)
        #expect(response.usage?.webSearchRequests == 0)
        #expect(response.content == "The weather in Paris is sunny.")
    }

    // MARK: A failed search is data

    @Test func everySearchFailingStillReturnsTheModelsText() async throws {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicFailedSearches))
        let response = try await anth.complete(search)
        #expect(response.content == "I could not search right now.")
        #expect(response.finishReason == .stop)
        #expect(response.webSearches == [
            WebSearch(id: "srvtoolu_e1", query: "swift news", outcome: .failed(.maxUsesExceeded)),
            WebSearch(id: "srvtoolu_e2", query: "swift forums", outcome: .failed(.unavailable))
        ])
        #expect(response.usage?.webSearchRequests == 0)
        // A 200 carrying search errors is one call, not a retry or a continuation.
        #expect(transport.openCount.get() == 1)

        // The stream shows the same thing as events, with no thrown error.
        let streamed = await collect(makeAnthropic(.replay(Fixtures.anthropicFailedSearches)).0, search)
        #expect(streamed.error == nil)
        #expect(streamed.events.contains(
            .webSearchResult(WebSearchResult(searchID: "srvtoolu_e1", outcome: .failed(.maxUsesExceeded)))
        ))
    }

    // MARK: pause_turn

    @Test func pauseTurnContinuesOnceEchoingThePausedTurnVerbatim() async throws {
        let (anth, transport) = makeAnthropic(
            .sequence([Fixtures.anthropicPausedTurn, Fixtures.anthropicResumedTurn])
        )
        let response = try await anth.complete(search)

        // Exactly one continuation, and the caller sees ONE merged response.
        #expect(transport.openCount.get() == 2)
        #expect(response.content == "Kyoto is mild today. Pack a light jacket.")
        #expect(response.finishReason == .stop)
        #expect(response.webSearches.map(\.query) == ["kyoto weather"])
        #expect(response.citations.compactMap { $0.range(in: response.content).map { String(response.content[$0]) } }
            == ["Kyoto is mild today."])
        #expect(response.usage == TokenUsage(inputTokens: 400, outputTokens: 70, webSearchRequests: 1))

        let bodies = requestBodies(transport)
        let first = bodies[0]["messages"] as? [[String: Any]] ?? []
        let second = bodies[1]["messages"] as? [[String: Any]] ?? []
        // The first request is the caller's conversation alone.
        #expect(first.count == 1)
        // The continuation is that conversation plus the paused assistant turn, unchanged.
        #expect(second.count == 2)
        #expect(canonicalJSON(second.first) == canonicalJSON(first.first))
        #expect(second.last?["role"] as? String == "assistant")
        #expect(canonicalJSON(second.last?["content"]) == canonicalJSON(literal: Fixtures.expectedPausedTurnJSON))
        // The continuation still offers the search tool, so the turn can keep searching.
        #expect(canonicalJSON(bodies[1]["tools"]) == canonicalJSON(bodies[0]["tools"]))

        // The encrypted fields are byte for byte what arrived: present verbatim in the raw
        // bytes on the wire, not merely equal after a JSON decode.
        let raw = String(bytes: transport.requests.get()[1].body ?? Data(), encoding: .utf8) ?? ""
        #expect(raw.contains(#""encrypted_content":"\#(Fixtures.encryptedKyoto)""#))
        #expect(raw.contains(#""encrypted_index":"\#(Fixtures.encryptedKyotoIndex)""#))
    }

    @Test func aTurnThatKeepsPausingStopsAtTheCapAsPaused() async throws {
        let (anth, transport) = makeAnthropic(.sequence([Fixtures.anthropicPausedTurn]))
        let streamed = await collect(anth, search)
        #expect(streamed.error == nil)
        // The first call plus the five continuations the cap allows, then a clear `.paused`.
        #expect(transport.openCount.get() == 6)
        #expect(streamed.events.last == .completed(.paused))
        let completions = streamed.events.filter { if case .completed = $0 { true } else { false } }
        #expect(completions.count == 1)
        // One usage report, summed over all six calls.
        let usages = streamed.events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
        #expect(usages == [TokenUsage(inputTokens: 600, outputTokens: 300, webSearchRequests: 6)])
        // The last continuation echoes every paused piece so far: five pauses of three blocks.
        let lastMessages = requestBodies(transport).last?["messages"] as? [[String: Any]] ?? []
        #expect((lastMessages.last?["content"] as? [Any])?.count == 15)
    }

    @Test func aStreamWithoutPauseNeverContinues() async {
        let (anth, transport) = makeAnthropic(.replay(Fixtures.anthropicTwoSearches))
        _ = await collect(anth, search)
        #expect(transport.openCount.get() == 1)
    }
}
