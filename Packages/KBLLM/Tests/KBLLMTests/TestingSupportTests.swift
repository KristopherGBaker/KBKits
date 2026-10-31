import Foundation
import KBLLM
import KBLLMTesting
import Testing

@Suite struct TestingSupportTests {
    @Test func fixedClockReturnsTheConfiguredInstant() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FixedClock(instant: instant)
        #expect(clock.now == instant)
    }

    @Test func seededGeneratorsAreReproducibleAndSeedSensitive() {
        var first = SeededRandomNumberGenerator(seed: 12_345)
        var second = SeededRandomNumberGenerator(seed: 12_345)
        var other = SeededRandomNumberGenerator(seed: 99_999)
        let firstSequence = (0..<6).map { _ in first.next() }
        let secondSequence = (0..<6).map { _ in second.next() }
        let otherSequence = (0..<6).map { _ in other.next() }
        // Same seed, identical multi-value sequences; a different seed diverges.
        #expect(firstSequence == secondSequence)
        #expect(firstSequence != otherSequence)
    }

    @Test func transcriptReplayIsIdenticalAcrossRuns() async throws {
        let transcript: [ModelEvent] = [
            .contentDelta("partial answer "),
            .toolCall(ToolCallRecord(id: "call-1", name: "search", arguments: Data(#"{"q":"swift"}"#.utf8))),
            .completed(.toolCalls)
        ]
        let model = ReplayModel(
            transcript: transcript,
            clock: FixedClock(instant: Date(timeIntervalSince1970: 0)),
            rng: SeededRandomNumberGenerator(seed: 7)
        )
        let firstRun = try await collectEvents(from: model)
        let secondRun = try await collectEvents(from: model)
        #expect(firstRun == secondRun)
        #expect(firstRun == transcript)
        #expect(firstRun.count == 3)
    }

    private func collectEvents(from model: some LanguageModel) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in model.stream(ModelRequest(messages: [])) {
            events.append(event)
        }
        return events
    }
}
