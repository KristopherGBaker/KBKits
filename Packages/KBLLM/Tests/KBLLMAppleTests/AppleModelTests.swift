import Foundation
import KBLLM
import KBLLMApple
import Testing

// Every test here drives `AppleModel` against the scripted `FakeFoundationModelBackend`, so
// the whole suite runs offline with no Apple Intelligence and never invokes real inference.
// The translation logic under test: cumulative-snapshot diffing, tool-call capture,
// availability mapping, total error mapping, request pass-through, and no session caching.
@Suite struct AppleModelTests {
    // Fixture A: four strictly growing snapshots.
    private let growingSnapshots = ["The", "The weather", "The weather in", "The weather in Paris is sunny."]
    // Fixture B: a leading empty snapshot and a repeated snapshot.
    private let emptyAndRepeated = ["", "The", "The", "The weather in Paris."]
    // Fixture C: a regressing (non-prefix) snapshot.
    private let regressing = ["The weather in Paris", "The"]

    private func userRequest(_ text: String = "What is the weather?") -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: text)])
    }

    // MARK: Assertion 3 - snapshot diff = non-overlapping deltas.

    @Test func snapshotDiffEmitsNonOverlappingDeltas() async {
        let fake = FakeFoundationModelBackend(script: .snapshots(growingSnapshots))
        let result = await collect(AppleModel(backend: fake), userRequest())
        #expect(result.error == nil)
        #expect(result.deltas == ["The", " weather", " in", " Paris is sunny."])
    }

    @Test func snapshotDiffSkipsEmptyAndRepeatedSnapshots() async {
        let fake = FakeFoundationModelBackend(script: .snapshots(emptyAndRepeated))
        let result = await collect(AppleModel(backend: fake), userRequest())
        #expect(result.error == nil)
        // No empty delta, no duplicated "The".
        #expect(result.deltas == ["The", " weather in Paris."])
    }

    // MARK: Assertion 5 - a regressing snapshot terminates with a typed error.

    @Test func nonPrefixSnapshotTerminatesWithTypedError() async {
        let fake = FakeFoundationModelBackend(script: .snapshots(regressing))
        let result = await collect(AppleModel(backend: fake), userRequest())
        guard case .decoding(_, let fragment) = result.error else {
            Issue.record("expected .decoding, got \(String(describing: result.error))")
            return
        }
        // The offending snapshot survives into the fragment, so the corruption is diagnosable.
        #expect(fragment.contains("The"))
        #expect(fragment == "The")

        // And the collected path throws rather than returning a mangled/truncated content.
        do {
            _ = try await AppleModel(backend: fake).complete(userRequest())
            Issue.record("expected complete to throw on a regressing snapshot")
        } catch {
            guard case .decoding = error else {
                Issue.record("expected .decoding from complete, got \(error)")
                return
            }
        }
    }

    // MARK: Assertion 4 - collected content equals the final snapshot exactly.

    @Test func collectedContentEqualsFinalSnapshotExactly() async throws {
        let fake = FakeFoundationModelBackend(script: .snapshots(growingSnapshots))
        let response = try await AppleModel(backend: fake).complete(userRequest())
        #expect(response.content == "The weather in Paris is sunny.")
        // No repeated prefix: content length equals the final snapshot's length exactly.
        #expect(response.content.count == growingSnapshots.last!.count)
    }

    // MARK: Assertion 6 - tool capture becomes one neutral tool call + a toolCalls finish.

    @Test func toolCaptureBecomesOneToolCallPlusToolCallsFinish() async throws {
        // Fixture T1: a flat object.
        let t1JSON = #"{"city":"Paris"}"#
        let fake1 = FakeFoundationModelBackend(
            script: .toolCall(name: "get_weather", id: "call_1", argumentsJSON: t1JSON)
        )
        let r1 = await collect(AppleModel(backend: fake1), userRequest())
        #expect(r1.error == nil)
        let expected1 = ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(t1JSON.utf8))
        #expect(r1.events == [.toolCall(expected1), .completed(.toolCalls)])
        let parsed1 = try parseObject(expected1.arguments)
        #expect(parsed1.count == 1)
        #expect(parsed1["city"] as? String == "Paris")

        // Fixture T2: a structurally DIFFERENT nested object-plus-array, so a hardcoded
        // record cannot pass both.
        let t2JSON = #"{"from":{"lat":48.8,"lon":2.3},"stops":["A","B"]}"#
        let fake2 = FakeFoundationModelBackend(
            script: .toolCall(name: "lookup_route", id: "call_9", argumentsJSON: t2JSON)
        )
        let r2 = await collect(AppleModel(backend: fake2), userRequest())
        #expect(r2.error == nil)
        let expected2 = ToolCallRecord(id: "call_9", name: "lookup_route", arguments: Data(t2JSON.utf8))
        #expect(r2.events == [.toolCall(expected2), .completed(.toolCalls)])
        let parsed2 = try parseObject(expected2.arguments)
        #expect((parsed2["from"] as? [String: Any])?["lat"] as? Double == 48.8)
        #expect((parsed2["from"] as? [String: Any])?["lon"] as? Double == 2.3)
        #expect(parsed2["stops"] as? [String] == ["A", "B"])
    }

    // MARK: Assertion 7 - an unavailable model maps to a typed .unavailable carrying the reason.

    @Test func unavailableModelMapsToUnavailableError() async {
        let fake = FakeFoundationModelBackend(
            availability: .unavailable(reason: "appleIntelligenceNotEnabled"),
            script: .snapshots(growingSnapshots)
        )
        let result = await collect(AppleModel(backend: fake), userRequest())
        guard case .unavailable(let reason) = result.error else {
            Issue.record("expected .unavailable, got \(String(describing: result.error))")
            return
        }
        #expect(reason.contains("appleIntelligenceNotEnabled"))
    }

    // MARK: Assertion 8 - distinct availability reasons discriminate.

    @Test func distinctAvailabilityReasonsMapToDistinctErrors() async {
        let notEnabled = FakeFoundationModelBackend(availability: .unavailable(reason: "appleIntelligenceNotEnabled"))
        let notEligible = FakeFoundationModelBackend(availability: .unavailable(reason: "deviceNotEligible"))
        let enabledResult = await collect(AppleModel(backend: notEnabled), userRequest())
        let eligibleResult = await collect(AppleModel(backend: notEligible), userRequest())
        guard case .unavailable(let reasonA) = enabledResult.error,
              case .unavailable(let reasonB) = eligibleResult.error else {
            Issue.record("expected both to be .unavailable, got \(String(describing: enabledResult.error))")
            return
        }
        #expect(reasonA != reasonB)
        #expect(reasonA.contains("appleIntelligenceNotEnabled"))
        #expect(reasonB.contains("deviceNotEligible"))
    }

    // MARK: Assertion 9 - inference count: once on the normal path, zero when unavailable.

    @Test func normalStreamRunsInferenceExactlyOnce() async {
        let fake = FakeFoundationModelBackend(script: .snapshots(growingSnapshots))
        _ = await collect(AppleModel(backend: fake), userRequest())
        #expect(fake.inferenceCount == 1)
    }

    @Test func unavailableFixtureMakesZeroInferenceAttempts() async {
        let fake = FakeFoundationModelBackend(
            availability: .unavailable(reason: "appleIntelligenceNotEnabled"),
            script: .snapshots(growingSnapshots)
        )
        let result = await collect(AppleModel(backend: fake), userRequest())
        #expect(result.error != nil)
        // Availability is checked BEFORE any inference, so the count stays at zero.
        #expect(fake.inferenceCount == 0)
    }

    // MARK: Assertion 10 - the request reaches the backend unchanged (no prompt rewriting).

    @Test func backendReceivesRequestUnchanged() async {
        let request = ModelRequest(messages: [
            Message(role: .system, text: "You are terse."),
            Message(role: .user, text: "Weather in Paris?")
        ])
        let fake = FakeFoundationModelBackend(script: .snapshots(["ok"]))
        _ = await collect(AppleModel(backend: fake), request)
        #expect(fake.receivedRequests.count == 1)
        // Same roles, same text, same order: no injected system prompt, no rewritten text.
        #expect(fake.receivedRequests.first == request)
    }

    // MARK: Assertion 11 - successive calls share no session state, pinned by output.

    @Test func successiveCallsShareNoSessionState() async {
        let first = ModelRequest(messages: [Message(role: .user, text: "first")])
        let second = ModelRequest(messages: [Message(role: .user, text: "second")])

        // Two calls on ONE AppleModel instance, each with a different request.
        let shared = FakeFoundationModelBackend(script: .reflectPriorTurns)
        let model = AppleModel(backend: shared)
        let sequential1 = await collect(model, first)
        let sequential2 = await collect(model, second)

        // Run-alone baselines against FRESH fakes.
        let freshFirst = FakeFoundationModelBackend(script: .reflectPriorTurns)
        let freshSecond = FakeFoundationModelBackend(script: .reflectPriorTurns)
        let baseline1 = await collect(AppleModel(backend: freshFirst), first)
        let baseline2 = await collect(AppleModel(backend: freshSecond), second)

        // Each sequential output is INDEPENDENT and identical to its run-alone baseline, and
        // the second shows zero prior turns, not an accumulated one.
        #expect(sequential1.content == baseline1.content)
        #expect(sequential2.content == baseline2.content)
        #expect(sequential2.content == "reply(priorUserTurns=0)")
    }

    // MARK: Assertion 13 - error mapping is total: a foreign error surfaces as a KBLLMError.

    @Test func foreignBackendErrorSurfacesAsTypedError() async {
        let fake = FakeFoundationModelBackend(
            script: .snapshotThenForeign(snapshot: "partial", detail: "boom")
        )
        let result = await collect(AppleModel(backend: fake), userRequest())
        // The foreign error never escapes untyped; it is mapped onto the KBLLMError surface.
        guard case .upstream(let cause) = result.error else {
            Issue.record("expected .upstream, got \(String(describing: result.error))")
            return
        }
        #expect(cause.contains("ForeignFailure"))
    }

    /// Parse tool-call argument bytes into a JSON object for structural assertions.
    private func parseObject(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
