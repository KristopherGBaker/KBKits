import Foundation
import KBLLM
import KBLLMRuntime
import Testing

// Caller-authored middlewares, defined in the TEST target to prove external authorship.

/// Appends a marker message to the downgoing request, so a test can observe apply order.
struct TagRequest: LanguageModelMiddleware {
    let tag: String

    init(_ tag: String) {
        self.tag = tag
    }

    func intercept(
        _ request: ModelRequest,
        next: any LanguageModel
    ) -> AsyncThrowingStream<ModelEvent, any Error> {
        var tagged = request
        tagged.messages.append(Message(role: .user, text: "MARK:" + tag))
        return next.stream(tagged)
    }
}

/// Uppercases every returning content delta, leaving other events untouched.
struct UppercaseDeltas: LanguageModelMiddleware {
    func intercept(
        _ request: ModelRequest,
        next: any LanguageModel
    ) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in next.stream(request) {
                        if case .contentDelta(let delta) = event {
                            continuation.yield(.contentDelta(delta.uppercased()))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A base model that records the request markers it received (in order) and echoes a
/// lowercased reply, so both the request-side and response-side transforms are observable.
struct RecordingBase: LanguageModel {
    let seenMarkers: Box<[String]>
    let reply: String

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let markers = request.messages.flatMap { message in
            message.content.compactMap { part -> String? in
                if case .text(let text) = part, text.hasPrefix("MARK:") {
                    return String(text.dropFirst("MARK:".count))
                }
                return nil
            }
        }
        seenMarkers.mutate { $0 = markers }
        let reply = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(reply.lowercased()))
            continuation.yield(.completed(.stop))
            continuation.finish()
        }
    }
}

private func retryPolicy() -> RetryPolicy {
    RetryPolicy(delays: [.seconds(30), .seconds(60)]) { error in
        switch error {
        case .httpStatus(let code, _): code == 429
        case .transport: true
        default: false
        }
    }
}

@Suite struct MiddlewareTests {
    // MARK: Assertion 8 - middleware transforms request and events in declared order.

    @Test func callerMiddlewareTransformsRequestAndEventsInOrder() async throws {
        let base = RecordingBase(seenMarkers: Box([]), reply: "Hello")
        let wrapped = wrap(base, with: [TagRequest("A"), TagRequest("B"), UppercaseDeltas()])
        var deltas: [String] = []
        for try await event in wrapped.stream(ModelRequest(messages: [])) {
            if case .contentDelta(let delta) = event { deltas.append(delta) }
        }
        #expect(base.seenMarkers.get() == ["A", "B"], "base must receive markers in declared apply order")
        #expect(deltas == ["HELLO"], "consumer must see uppercased deltas")
    }

    // MARK: Assertion 9 - retry policy discriminates and uses the injected clock.

    @Test func retryPolicyDiscriminatesAndUsesInjectedClock() async throws {
        // (a) retryable error retried per the schedule, then succeeds.
        let sleeps = Box<[Duration]>([])
        let model = FlakyModel(
            failures: 2,
            error: .httpStatus(code: 429, message: "rate limited"),
            success: [.contentDelta("ok"), .completed(.stop)],
            calls: Box(0)
        )
        let wrapped = wrap(model, with: [RetryMiddleware(policy: retryPolicy(), clock: RecordingClock(sleeps: sleeps))])
        let response = try await wrapped.complete(ModelRequest(messages: []))
        #expect(response.content == "ok")
        #expect(sleeps.get() == [.seconds(30), .seconds(60)])

        // (b) non-retryable error is rethrown at once, with zero sleeps.
        let rejectSleeps = Box<[Duration]>([])
        let rejectModel = FlakyModel(
            failures: 1,
            error: .invalidRequest(field: "messages", reason: "empty"),
            success: [.completed(.stop)],
            calls: Box(0)
        )
        let rejecting = wrap(
            rejectModel,
            with: [RetryMiddleware(policy: retryPolicy(), clock: RecordingClock(sleeps: rejectSleeps))]
        )
        await #expect(throws: KBLLMError.invalidRequest(field: "messages", reason: "empty")) {
            _ = try await rejecting.complete(ModelRequest(messages: []))
        }
        #expect(rejectSleeps.get().isEmpty)
    }

    // MARK: Assertion 10 - logging records fixture-specific request and returned data.

    @Test func loggingMiddlewareRecordsRequestAndResponseData() async throws {
        let records = Box<[(LogLevel, String)]>([])
        let base = ScriptedModel(turns: [[.contentDelta("ANSWER"), .completed(.stop)]])
        let wrapped = wrap(base, with: [LoggingMiddleware(sink: SpyLogSink(records: records))])
        _ = try await wrapped.complete(ModelRequest(messages: [Message(role: .user, text: "PROBE-7f")]))
        let messages = records.get().map(\.1)
        #expect(messages.contains { $0.contains("PROBE-7f") }, "log must capture the request marker")
        #expect(messages.contains { $0.contains("ANSWER") }, "log must capture the returned payload")
    }

    // MARK: Assertion 12(a) - retry does not sleep on a real clock (behavioral bound).

    @Test func retryDoesNotSleepOnARealClock() async {
        let model = FlakyModel(
            failures: 2,
            error: .httpStatus(code: 429, message: "rate limited"),
            success: [.contentDelta("ok"), .completed(.stop)],
            calls: Box(0)
        )
        let retry = RetryMiddleware(policy: retryPolicy(), clock: RecordingClock(sleeps: Box([])))
        let wrapped = wrap(model, with: [retry])
        let done = Box(false)
        // Unstructured task: on a real OS sleep (the one thing no gate can release) we abandon it.
        let task = Task {
            _ = try? await wrapped.complete(ModelRequest(messages: []))
            done.mutate { $0 = true }
        }
        let elapsed = await realElapsed {
            _ = await waitUntil(timeout: .seconds(5)) { done.get() }
        }
        if done.get() {
            #expect(elapsed < .seconds(5), "injected clock returns immediately, so real elapsed must stay under 5s")
        } else {
            _ = task // abandoned without joining so the suite proceeds immediately
            Issue.record("retry did not complete within the 5s window; it slept on a real clock")
        }
    }
}
