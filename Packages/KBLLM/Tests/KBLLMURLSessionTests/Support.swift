import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Offline scaffolding for the transport suite: a lock-guarded box, a bounded real-clock poll,
// and a stub `URLProtocol` that intercepts EVERY request (so nothing reaches the network) and
// can gate its later bytes behind a semaphore so the incremental-delivery test can observe an
// early chunk before a later one is ever sent. The stub drives the REAL `URLSession` code path.

/// A reference-typed, lock-guarded cell shared across tasks. `@unchecked Sendable` because the
/// `NSLock` serializes every access to `value`.
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

/// The scripted behavior of one stub connection: a status, headers, an initial chunk delivered
/// immediately, and an optional trailing chunk plus completion that may be withheld behind a
/// gate (for the incremental test) or never delivered (for the cancellation test).
struct StubPlan: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = ["Content-Type": "text/event-stream"]
    var chunkA: [UInt8] = []
    var chunkB: [UInt8] = []
    /// When true, `chunkB` and completion wait on the gate the test opens.
    var gated = false
    /// When false, completion is never delivered, so the connection stays open until the gate
    /// is opened at teardown; used to give a cancellation something to cancel.
    var finishes = true
}

/// Carries the non-`Sendable` `URLProtocol` handoff across the gate-waiting thread. The URL
/// loading system already invokes the client from arbitrary threads, so this hop is safe.
private final class Handoff: @unchecked Sendable {
    let proto: URLProtocol
    let client: any URLProtocolClient

    init(_ proto: URLProtocol, _ client: any URLProtocolClient) {
        self.proto = proto
        self.client = client
    }
}

/// The shared control block for the stub protocol. `URLSession` instantiates the protocol, so
/// its plan and counters live here, reset per test. `@unchecked Sendable` via an `NSLock`.
final class StubControl: @unchecked Sendable {
    private let lock = NSLock()
    private var plan = StubPlan()
    private var starts = 0
    private var stops = 0
    private let gate = DispatchSemaphore(value: 0)

    func reset(_ plan: StubPlan) {
        lock.lock()
        self.plan = plan
        starts = 0
        stops = 0
        lock.unlock()
        // Drain any signals left over from a prior test so this one starts with a closed gate.
        while gate.wait(timeout: .now()) == .success {}
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    /// Release the gate so any withheld chunk and completion are delivered (or a parked
    /// keep-open thread can exit). Called by the test once it has observed what it needs.
    func openGate() {
        gate.signal()
    }

    private func recordStop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    func start(_ proto: URLProtocol) {
        lock.lock()
        starts += 1
        let plan = self.plan
        lock.unlock()

        guard let client = proto.client, let url = proto.request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: plan.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: plan.headers
        )
        guard let response else { return }
        client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !plan.chunkA.isEmpty {
            client.urlProtocol(proto, didLoad: Data(plan.chunkA))
        }

        let handoff = Handoff(proto, client)
        if plan.gated {
            DispatchQueue.global().async {
                self.gate.wait()
                Self.deliverRest(plan, handoff)
            }
        } else if !plan.finishes {
            // Keep the connection open until teardown opens the gate.
            DispatchQueue.global().async { self.gate.wait() }
        } else {
            Self.deliverRest(plan, handoff)
        }
    }

    func stop() {
        recordStop()
    }

    private static func deliverRest(_ plan: StubPlan, _ handoff: Handoff) {
        if !plan.chunkB.isEmpty {
            handoff.client.urlProtocol(handoff.proto, didLoad: Data(plan.chunkB))
        }
        if plan.finishes {
            handoff.client.urlProtocolDidFinishLoading(handoff.proto)
        }
    }
}

/// A stub `URLProtocol` whose `canInit(with:)` returns true for EVERY request, so no request
/// can escape to the real network. Its behavior is scripted through the shared `control`. Not
/// `final` because its overrides are `class func`s (`canInit`/`canonicalRequest`), which a
/// final class would push toward `static`, and an override cannot be `static`.
class StubURLProtocol: URLProtocol {
    static let control = StubControl()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        StubURLProtocol.control.start(self)
    }

    override func stopLoading() {
        StubURLProtocol.control.stop()
    }
}

/// A `URLSessionConfiguration` whose `protocolClasses` register the stub, so a transport built
/// from it drives the real `URLSession` path entirely offline.
func stubbedConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return configuration
}
