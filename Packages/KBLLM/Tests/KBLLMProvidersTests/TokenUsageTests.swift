import Foundation
import KBLLM
import Testing

/// Both providers report what a call consumed, in the shape each actually uses on the wire,
/// and a provider that reports nothing produces no usage rather than a zeroed one.
@Suite struct TokenUsageTests {
    private func usageEvents(_ events: [ModelEvent]) -> [TokenUsage] {
        events.compactMap { event in
            guard case let .usage(usage) = event else { return nil }
            return usage
        }
    }

    @Test func anthropicMergesUsageSplitAcrossItsOpeningAndClosingFrames() async throws {
        let result = await collect(makeAnthropic(.replay(Fixtures.anthropicWithUsage)).0, weatherRequest)
        #expect(result.error == nil)

        // ONE report, not one per frame: input and cache counts arrive at message_start and
        // output counts at message_delta, and a consumer that added up what it received
        // would otherwise count the same call twice.
        let reported = usageEvents(result.events)
        #expect(reported.count == 1)
        let usage = try #require(reported.first)
        #expect(usage.inputTokens == 11)
        #expect(usage.outputTokens == 29)
        #expect(usage.cacheReadTokens == 300)
        #expect(usage.cacheWriteTokens == 7)
    }

    @Test func openAIReadsUsageFromItsChoicelessTrailingFrame() async throws {
        let result = await collect(makeOpenAI(.replay(Fixtures.openAIWithUsage)).0, weatherRequest)
        #expect(result.error == nil)

        let usage = try #require(usageEvents(result.events).first)
        #expect(usage.inputTokens == 13)
        #expect(usage.outputTokens == 21)
        // A model before GPT-5.6 reports no `cache_write_tokens` (its writes are not billed),
        // so that field stays 0 rather than borrowing another provider's meaning.
        #expect(usage.cacheReadTokens == 8)
        #expect(usage.cacheWriteTokens == 0)
    }

    @Test func anthropicReportsTheOneHourShareOfACacheWrite() async throws {
        let result = await collect(makeAnthropic(.replay(Fixtures.anthropicWithCacheLifetimes)).0, weatherRequest)
        #expect(result.error == nil)
        let usage = try #require(usageEvents(result.events).first)
        // The total stays the whole write; the one-hour part is reported beside it, so a
        // caller that knows only one write rate still counts every token.
        #expect(usage.cacheWriteTokens == 45)
        #expect(usage.cacheWrite1hTokens == 40)
        #expect(usage.reportedCostUSD == nil)
    }

    @Test func openAICompatibleProviderCostIsReported() async throws {
        let withCost = await collect(makeOpenAI(.replay(Fixtures.openAIWithReportedCost)).0, weatherRequest)
        #expect(try #require(usageEvents(withCost.events).first).reportedCostUSD == 0.00042)
        // OpenAI itself states no cost: nil, never 0, so a caller knows to estimate.
        let without = await collect(makeOpenAI(.replay(Fixtures.openAIWithUsage)).0, weatherRequest)
        #expect(try #require(usageEvents(without.events).first).reportedCostUSD == nil)
    }

    @Test func aTotalIsAReportedCostOnlyWhenEveryCallReportedOne() {
        let reported = TokenUsage(
            inputTokens: 1, outputTokens: 1, cacheWriteTokens: 10, cacheWrite1hTokens: 4, reportedCostUSD: 0.25
        )
        let alsoReported = TokenUsage(
            inputTokens: 2, outputTokens: 2, cacheWriteTokens: 6, cacheWrite1hTokens: 6, reportedCostUSD: 0.5
        )
        let unreported = TokenUsage(inputTokens: 3, outputTokens: 3)
        let both = reported + alsoReported
        #expect(both.reportedCostUSD == 0.75)
        #expect(both.cacheWriteTokens == 16 && both.cacheWrite1hTokens == 10)
        #expect((reported + unreported).reportedCostUSD == nil)
        #expect((unreported + reported).reportedCostUSD == nil)
    }

    /// The ordering guarantee, and the reason the OpenAI adapter withholds its terminal:
    /// usage arrives after `finish_reason` on the wire, but a consumer must never see it
    /// after the event that ends the call.
    @Test func usagePrecedesCompletionForBothProviders() async {
        for events in await [
            collect(makeOpenAI(.replay(Fixtures.openAIWithUsage)).0, weatherRequest).events,
            collect(makeAnthropic(.replay(Fixtures.anthropicWithUsage)).0, weatherRequest).events
        ] {
            let usageIndex = events.firstIndex { if case .usage = $0 { return true } else { return false } }
            let completedIndex = events.firstIndex { if case .completed = $0 { return true } else { return false } }
            #expect(usageIndex != nil)
            #expect(completedIndex != nil)
            if let usageIndex, let completedIndex {
                #expect(usageIndex < completedIndex)
            }
        }
    }

    @Test func aProviderThatReportsNothingYieldsNoUsageRatherThanZero() async throws {
        let result = await collect(makeOpenAI(.replay(Fixtures.openAIWithoutUsage)).0, weatherRequest)
        #expect(result.error == nil)
        #expect(usageEvents(result.events).isEmpty)

        // And the collected form says nil, not TokenUsage(0, 0): "billed nothing" and "was
        // never told" are different facts, and a caller summing costs has to tell them apart.
        let response = try await makeOpenAI(.replay(Fixtures.openAIWithoutUsage)).0.complete(weatherRequest)
        #expect(response.usage == nil)
    }

    @Test func collectedCompletionCarriesTheReportedUsage() async throws {
        let response = try await makeAnthropic(.replay(Fixtures.anthropicWithUsage)).0.complete(weatherRequest)
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 11)
        #expect(usage.outputTokens == 29)
    }

    @Test func usageAddsFieldWise() {
        let total = TokenUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 2, cacheWriteTokens: 1)
            + TokenUsage(inputTokens: 3, outputTokens: 7, cacheReadTokens: 4, cacheWriteTokens: 0)
        #expect(total == TokenUsage(inputTokens: 13, outputTokens: 12, cacheReadTokens: 6, cacheWriteTokens: 1))
    }
}
