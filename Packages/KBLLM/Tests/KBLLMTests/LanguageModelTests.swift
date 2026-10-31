import Foundation
import KBLLM
import KBLLMTesting
import Testing

// A fake that conforms to LanguageModel by implementing ONLY `stream`. It does not
// implement `complete`; that comes from the core protocol extension. Its presence in
// the suite proves an adapter needs exactly one method.
private struct StreamOnlyModel: LanguageModel {
    let deltas: [String]

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let deltas = deltas
        return AsyncThrowingStream { continuation in
            for delta in deltas {
                continuation.yield(.contentDelta(delta))
            }
            continuation.yield(.completed(.stop))
            continuation.finish()
        }
    }
}

/// A model whose stream ignores cancellation entirely: it waits on a gate the test controls,
/// then yields a full answer regardless. It stands in for a real adapter that does not thread
/// cancellation into its transport, which is exactly the case `complete` has to cover itself.
private struct UncooperativeModel: LanguageModel {
    let entered: AsyncGate
    let release: AsyncGate

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await entered.open()
                await release.wait()
                continuation.yield(.contentDelta("an answer nobody is waiting for"))
                continuation.yield(.completed(.stop))
                continuation.finish()
            }
        }
    }
}

/// A one-shot latch. `Task` cancellation must not affect it, so it is built from a plain
/// continuation rather than anything that throws on cancel.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Counts how many times an adapter was asked to stream.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var invocations: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private struct CountingModel: LanguageModel {
    let counter: CallCounter

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        counter.record()
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(.stop))
            continuation.finish()
        }
    }
}

@Suite struct LanguageModelTests {
    @Test func derivedCompleteAggregatesTheStream() async throws {
        let model = StreamOnlyModel(deltas: ["Hello, ", "stream", "ing ", "world"])
        let response = try await model.complete(ModelRequest(messages: []))
        #expect(response.content == "Hello, streaming world")
        #expect(response.finishReason == .stop)
    }

    @Test func replayModelImplementsOnlyStreamYetCompletes() async throws {
        // ReplayModel from KBLLMTesting also implements only `stream`.
        let model = ReplayModel(transcript: [
            .contentDelta("one "),
            .contentDelta("two"),
            .completed(.stop)
        ])
        let response = try await model.complete(ModelRequest(messages: []))
        #expect(response.content == "one two")
    }

    @Test func completeStopsCollectingWhenItsTaskIsCancelled() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let model = UncooperativeModel(entered: entered, release: release)

        let task = Task { try await model.complete(ModelRequest(messages: [])) }
        await entered.wait()
        task.cancel()
        // Only now let the model produce. Without the check inside `complete`, this answer
        // would be collected and returned as though nothing had been cancelled.
        await release.open()

        switch await task.result {
        case let .success(response):
            Issue.record("expected cancellation, got a full response: \(response.content)")
        case let .failure(error):
            #expect(error as? KBLLMError == .cancelled)
        }
    }

    @Test func completeNeverReachesTheProviderWhenAlreadyCancelled() async {
        let counter = CallCounter()
        let model = CountingModel(counter: counter)

        let task = Task {
            // Do not call until this task has actually observed its own cancellation, so the
            // test pins the guard rather than a race with `task.cancel()`.
            while !Task.isCancelled { await Task.yield() }
            return try await model.complete(ModelRequest(messages: []))
        }
        task.cancel()

        switch await task.result {
        case .success:
            Issue.record("expected cancellation before the provider was ever asked")
        case let .failure(error):
            #expect(error as? KBLLMError == .cancelled)
        }
        #expect(counter.invocations == 0)
    }
}
