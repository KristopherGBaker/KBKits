import Foundation
import KBLLM
import KBLLMRuntime

// Deterministic, offline test fixtures for the runtime suite. Every fixture that can
// block waits on a gate the TEST owns, so no runtime mutation can wedge the suite: a test
// releases the gate through the fixture's normal data path to drive termination.

/// A reference-typed, lock-guarded cell so a value struct model shared by copy still sees
/// one shared counter/recording. `@unchecked Sendable` because the `NSLock` serializes
/// every access to `value`.
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

/// A one-shot gate the TEST owns: a fixture awaits it, the test opens it to release. Used
/// so a parked model or a tool waiting on a peer terminates through its data path.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// An ordered log of named events, so a concurrency test can assert start/finish order.
actor OrderLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

/// What a scripted model does on one `stream(_:)` call.
enum TurnBehavior: Sendable {
    case events([ModelEvent])
    case park(Gate)
    /// Yield the events, then park on the gate WITHOUT completing. On the consumer being
    /// cancelled the stream ends, leaving the yielded tool call collected but the turn
    /// unfinished, so a loop that ignores cancellation would wrongly dispatch it.
    case emitThenPark([ModelEvent], Gate)
}

/// A `LanguageModel` scripted PER TURN. Each `stream(_:)` call consumes the next behavior,
/// counts the call (a spy), and records the request it received (so a test can assert what
/// the previous turn's results fed forward). A behavior beyond the script is a plain stop.
struct ScriptedModel: LanguageModel {
    let behaviors: [TurnBehavior]
    let calls: Box<Int>
    let requests: Box<[ModelRequest]>

    init(
        behaviors: [TurnBehavior],
        calls: Box<Int> = Box(0),
        requests: Box<[ModelRequest]> = Box([])
    ) {
        self.behaviors = behaviors
        self.calls = calls
        self.requests = requests
    }

    /// Convenience: a model scripted with plain event turns (no parking).
    init(turns: [[ModelEvent]], calls: Box<Int> = Box(0), requests: Box<[ModelRequest]> = Box([])) {
        self.init(behaviors: turns.map { .events($0) }, calls: calls, requests: requests)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let index = calls.mutate { current -> Int in
            let value = current
            current += 1
            return value
        }
        requests.mutate { $0.append(request) }
        let behavior = index < behaviors.count ? behaviors[index] : .events([.completed(.stop)])
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .events(let events):
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                case .park(let gate):
                    await gate.wait()
                    continuation.finish()
                case .emitThenPark(let events, let gate):
                    for event in events { continuation.yield(event) }
                    await gate.wait()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A model that ALWAYS asks for the same tool for a finite budget of turns, then parks on a
/// test-owned gate. A correct round-trip bound stops the loop before the budget is reached;
/// a bound-ignoring mutation runs on to the park, which the test releases.
struct GatedRunawayModel: LanguageModel {
    let call: ToolCallRecord
    let budget: Int
    let gate: Gate
    let calls: Box<Int>

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let index = calls.mutate { current -> Int in
            let value = current
            current += 1
            return value
        }
        let call = call
        let gate = gate
        let overBudget = index >= budget
        return AsyncThrowingStream { continuation in
            let task = Task {
                if overBudget {
                    await gate.wait()
                    continuation.finish()
                    return
                }
                continuation.yield(.toolCall(call))
                continuation.yield(.completed(.toolCalls))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A model whose `stream` fails a configured number of times with a given error, then
/// streams a success transcript. It fails BEFORE yielding anything, so a retry re-issue
/// never double-yields.
struct FlakyModel: LanguageModel {
    let failures: Int
    let error: KBLLMError
    let success: [ModelEvent]
    let calls: Box<Int>

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let index = calls.mutate { current -> Int in
            let value = current
            current += 1
            return value
        }
        let error = error
        let success = success
        let shouldFail = index < failures
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: error)
                return
            }
            for event in success { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// A `ClockSource` that records every requested sleep duration in order and returns at once,
/// so a retry schedule is observable without real time passing.
struct RecordingClock: ClockSource {
    let sleeps: Box<[Duration]>

    var now: Date { Date(timeIntervalSince1970: 0) }

    func sleep(for duration: Duration) async throws {
        sleeps.mutate { $0.append(duration) }
    }
}

/// A `LogSink` that captures every record so a test can assert on the logged content.
struct SpyLogSink: LogSink {
    let records: Box<[(LogLevel, String)]>

    func log(_ level: LogLevel, _ message: String) {
        records.mutate { $0.append((level, message)) }
    }
}

// MARK: - Tools

/// A tool that increments a shared counter and returns a fixed success payload.
func countingTool(named name: String, counter: Box<Int>) -> Tool {
    Tool(
        definition: ToolDefinition(
            name: name,
            description: "counts invocations",
            parameters: .object(properties: [:], required: [], description: nil)
        ),
        invoke: { _ in
            counter.mutate { $0 += 1 }
            return ToolResult.success(toolName: name, content: Data(#"{"ok":true}"#.utf8))
        }
    )
}

/// A tool that always returns a recoverable error result (never throws).
func failingTool(named name: String) -> Tool {
    Tool(
        definition: ToolDefinition(
            name: name,
            description: "always fails",
            parameters: .object(properties: [:], required: [], description: nil)
        ),
        invoke: { _ in ToolResult.failure(toolName: name, message: "boom") }
    )
}

// MARK: - Bounded-wait helpers (real clock lives in the TEST target only)

/// Poll `condition` on a real clock until it holds or the timeout elapses. The real clock
/// and `Task.sleep` are the TEST target's own; the unit-source clock ban does not bind here.
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

/// Real elapsed time of an async operation, measured on the TEST target's real clock.
func realElapsed(_ operation: () async -> Void) async -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    await operation()
    return start.duration(to: clock.now)
}
