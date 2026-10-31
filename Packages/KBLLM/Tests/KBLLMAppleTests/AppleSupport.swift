import Foundation
import KBLLM
import KBLLMApple

// Offline, deterministic scaffolding for the Apple adapter suite: a scripted fake backend
// (the FoundationModels analogue of the provider suite's RecordingTransport), a foreign
// failure type, a lock-guarded box, and a real-clock bounded collector. NOTHING here invokes
// real inference, so the whole suite runs and passes on a machine with no Apple Intelligence.

/// A reference-typed, lock-guarded cell so a value-type consumer shared by copy still sees
/// one shared counter/recording. `@unchecked Sendable` because the `NSLock` serializes every
/// access to `value`.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// A foreign failure deliberately NOT a `KBLLMError`, so a test that sees a `KBLLMError` come
/// out of the adapter has witnessed a real mapping, not a hand-built enum being re-thrown.
struct ForeignFailure: Error, Sendable, CustomStringConvertible {
    let detail: String
    var description: String { "ForeignFailure: \(detail)" }
}

/// A scripted `FoundationModelBackend`. It records how many times it was asked to run
/// inference and the exact `ModelRequest` it received per call, then yields a deterministic
/// script of cumulative snapshots, a captured tool call, or a foreign error. It NEVER runs
/// real inference. The reference type keeps one shared record across the value-type adapter.
final class FakeFoundationModelBackend: FoundationModelBackend, @unchecked Sendable {
    /// What one `run` call does.
    enum Script: Sendable {
        /// Yield these cumulative snapshots in order, then finish.
        case snapshots([String])
        /// Surface one captured model tool call (name + id + argument JSON), then finish.
        case toolCall(name: String, id: String, argumentsJSON: String)
        /// Yield one snapshot, then throw a foreign error MID-STREAM.
        case snapshotThenForeign(snapshot: String, detail: String)
        /// Reply with a marker encoding the received request's PRIOR user-turn count, so a
        /// session carried across calls (a bloated request) is observable in the output.
        case reflectPriorTurns
    }

    /// What `contextSize()` does: answer a size (or `nil`), or throw a foreign error.
    enum ContextSizeScript: Sendable {
        case size(Int?)
        case throwing(String)
    }

    let availability: FoundationModelAvailability
    let capabilities: Set<FoundationModelCapability>
    let quotaUsage: FoundationModelQuotaUsage?
    private let contextSizeScript: ContextSizeScript
    private let script: Script
    private let state = Box(State())

    struct State: Sendable {
        var inferenceCount = 0
        var requests: [ModelRequest] = []
    }

    /// Defaults match the seam's own defaults (today's on-device model), so a test that sets
    /// none of the new knobs behaves exactly as before they existed.
    init(
        availability: FoundationModelAvailability = .available,
        capabilities: Set<FoundationModelCapability> = [.guidedGeneration, .toolCalling],
        contextSize: ContextSizeScript = .size(nil),
        quotaUsage: FoundationModelQuotaUsage? = nil,
        script: Script = .snapshots([])
    ) {
        self.availability = availability
        self.capabilities = capabilities
        self.contextSizeScript = contextSize
        self.quotaUsage = quotaUsage
        self.script = script
    }

    func contextSize() async throws -> Int? {
        switch contextSizeScript {
        case .size(let size): return size
        case .throwing(let detail): throw ForeignFailure(detail: detail)
        }
    }

    /// How many times `run` was called. Availability is a property, so checking it never
    /// touches this count: the unavailable path must leave it at zero.
    var inferenceCount: Int { state.get().inferenceCount }

    /// The requests `run` received, in order, so a test can prove they arrived unchanged.
    var receivedRequests: [ModelRequest] { state.get().requests }

    func run(_ request: ModelRequest) -> AsyncThrowingStream<FoundationModelChunk, any Error> {
        state.mutate { $0.inferenceCount += 1; $0.requests.append(request) }
        let script = self.script
        return AsyncThrowingStream { continuation in
            switch script {
            case .snapshots(let snapshots):
                for snapshot in snapshots { continuation.yield(.snapshot(snapshot)) }
                continuation.finish()
            case .toolCall(let name, let id, let argumentsJSON):
                continuation.yield(.toolCall(name: name, id: id, argumentsJSON: argumentsJSON))
                continuation.finish()
            case .snapshotThenForeign(let snapshot, let detail):
                continuation.yield(.snapshot(snapshot))
                continuation.finish(throwing: ForeignFailure(detail: detail))
            case .reflectPriorTurns:
                let priorTurns = max(0, request.messages.filter { $0.role == .user }.count - 1)
                continuation.yield(.snapshot("reply(priorUserTurns=\(priorTurns))"))
                continuation.finish()
            }
        }
    }
}

/// The outcome of draining an adapter stream: the ordered events and, if it threw, the typed
/// error. The adapter maps every failure onto `KBLLMError`, so a typed error suffices.
struct Collected: Sendable {
    var events: [ModelEvent] = []
    var error: KBLLMError?

    /// The concatenation of every `contentDelta` payload, i.e. the collected content.
    var content: String {
        events.reduce(into: "") { accumulated, event in
            if case .contentDelta(let delta) = event { accumulated += delta }
        }
    }

    /// Just the `contentDelta` payloads, in order.
    var deltas: [String] {
        events.compactMap { if case .contentDelta(let delta) = $0 { delta } else { nil } }
    }
}

/// Drain a model's stream on the real clock with a bounded wait, so a stuck stream fails the
/// wait rather than wedging the suite. The scripts here are finite, so this returns at once;
/// the bound is liveness insurance, never the intended failure mode of any test.
func collect(
    _ model: any LanguageModel,
    _ request: ModelRequest,
    timeout: Duration = .seconds(10)
) async -> Collected {
    let box = Box<Collected?>(nil)
    let task = Task {
        var events: [ModelEvent] = []
        do {
            for try await event in model.stream(request) { events.append(event) }
            box.mutate { $0 = Collected(events: events, error: nil) }
        } catch {
            box.mutate { $0 = Collected(events: events, error: KBLLMError.from(error)) }
        }
    }
    let finished = await waitUntil(timeout: timeout) { box.get() != nil }
    if !finished { task.cancel() }
    return box.get() ?? Collected()
}

/// Poll `condition` on a real clock until it holds or the timeout elapses. The real clock and
/// `Task.sleep` are the TEST target's own, so the unit-source clock ban does not bind here.
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
