import Foundation
import KBLLM

// Offline, deterministic test scaffolding shared by the provider suite: a recording fake
// transport that replays recorded provider bytes (and never opens a socket), a fake
// credential store, a log spy, a lock-guarded box, and a real-clock bounded collector so
// no stream consumption can wedge the run. Nothing here reaches the network.

/// The sentinel secret. It is deliberately distinctive so any leak into a log line or an
/// error payload is unmistakable in an assertion.
let sentinelSecret = "sk-SENTINEL-DO-NOT-LOG-12345"

/// A reference-typed, lock-guarded cell so a value-type transport shared by copy still
/// sees one shared counter/recording. `@unchecked Sendable` because the `NSLock`
/// serializes every access to `value`.
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

/// A foreign failure that is deliberately NOT a `KBLLMError`, so a test that sees a
/// `.transport` come out of an adapter has witnessed a real mapping, not a hand-built
/// enum being re-thrown. Stands in for a host transport's reachability error.
struct ForeignFailure: Error, Sendable, CustomStringConvertible {
    let detail: String
    var description: String { "ForeignFailure: \(detail)" }
}

/// A credential store rejection, foreign to `KBLLMError`, so the adapter's mapping to
/// `.missingCredential` is a real conversion.
struct CredentialUnavailable: Error, Sendable {
    let key: String
}

/// A recording fake `HTTPTransport`. It captures every `HTTPRequestSpec`, counts opens,
/// and flags any use of the whole-response `send`, then replays a recorded byte transcript
/// (finite, then finishes) or throws a chosen error into the byte stream.
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    /// What one `openBytes` call does. Every payload is `Sendable` so no foreign,
    /// non-`Sendable` error crosses the stream-builder boundary.
    enum Behavior: Sendable {
        case replay([UInt8])
        /// The host surfaces a non-success status by throwing `.httpStatus` into the stream.
        case httpStatus(code: Int, message: String)
        /// A foreign reachability error, carrying a message the adapter must not leak.
        case foreign(detail: String)
        /// Replay some bytes, then throw a foreign error mid-stream.
        case emitThenForeign(bytes: [UInt8], detail: String)
        /// Replay the Nth transcript on the Nth open, repeating the last one after that, so a
        /// test can script a multi-call exchange (a `pause_turn` continuation).
        case sequence([[UInt8]])
    }

    let behavior: Behavior
    let requests = Box<[HTTPRequestSpec]>([])
    let openCount = Box(0)
    let sendInvoked = Box(false)

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec {
        sendInvoked.mutate { $0 = true }
        throw KBLLMError.transport(url: request.url, underlying: "send must never be used by a streaming adapter")
    }

    func openBytes(_ request: HTTPRequestSpec) -> AsyncThrowingStream<UInt8, any Error> {
        requests.mutate { $0.append(request) }
        let opened = openCount.mutate { count -> Int in
            count += 1
            return count
        }
        let behavior = self.behavior
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .replay(let bytes):
                for byte in bytes { continuation.yield(byte) }
                continuation.finish()
            case .sequence(let transcripts):
                let bytes = transcripts.isEmpty ? [] : transcripts[min(opened, transcripts.count) - 1]
                for byte in bytes { continuation.yield(byte) }
                continuation.finish()
            case .httpStatus(let code, let message):
                continuation.finish(throwing: KBLLMError.httpStatus(code: code, message: message))
            case .foreign(let detail):
                continuation.finish(throwing: ForeignFailure(detail: detail))
            case .emitThenForeign(let bytes, let detail):
                for byte in bytes { continuation.yield(byte) }
                continuation.finish(throwing: ForeignFailure(detail: detail))
            }
        }
    }
}

/// A fake `CredentialStore` returning a sentinel secret or throwing for a key.
struct FakeCredentialStore: CredentialStore {
    enum Response: Sendable {
        case secret(String)
        case missing
    }

    let response: Response

    func secret(forKey key: String) async throws -> String {
        switch response {
        case .secret(let value): return value
        case .missing: throw CredentialUnavailable(key: key)
        }
    }
}

/// A `LogSink` that captures every record so a test can prove what was and was not logged.
struct SpyLogSink: LogSink {
    let records: Box<[(LogLevel, String)]>

    func log(_ level: LogLevel, _ message: String) {
        records.mutate { $0.append((level, message)) }
    }

    /// Every logged message joined, for a substring scan.
    var joined: String {
        records.get().map(\.1).joined(separator: "\n")
    }
}

/// The outcome of draining an adapter stream: the ordered events and, if it threw, the
/// typed error. The adapter maps every failure onto `KBLLMError`, so a typed error suffices.
struct Collected: Sendable {
    var events: [ModelEvent] = []
    var error: KBLLMError?
}

/// Drain a model's stream on the real clock with a bounded wait, so a stuck stream fails
/// the wait rather than wedging the suite. The replays here are finite, so this returns at
/// once; the bound is liveness insurance, never the intended failure mode of any test.
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

/// Poll `condition` on a real clock until it holds or the timeout elapses. Copied from the
/// runtime suite's `Fakes.swift`; the real clock and `Task.sleep` are the TEST target's
/// own, so the unit-source clock ban does not bind here.
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
