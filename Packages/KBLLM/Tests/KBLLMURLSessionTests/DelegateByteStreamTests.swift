import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBLLM
@testable import KBLLMURLSession
import Testing

// The delegate-driven streaming path, which is what runs on platforms without
// `URLSession.AsyncBytes` (Linux, Android). It is compiled everywhere precisely so it can
// be tested HERE, on macOS, where it is not the default: otherwise the only machine that
// ever ran it would be a phone, and only in production.
//
// These deliberately mirror the `AsyncBytes` assertions in `TransportTests` rather than
// inventing new ones. The point is that the two paths behave the same, so the contract in
// `HTTPTransport` holds whichever one a platform gets.
//
// They EXTEND `TransportTests` rather than forming a suite of their own, and that is not a
// stylistic choice. `StubURLProtocol.control` is shared static state, and `.serialized`
// orders tests within a suite but does NOT order two suites against each other. A separate
// suite therefore races the original one and reads its scripted plan, which shows up as a
// test receiving bytes it never scripted. Same suite, same serialization, no race.
extension TransportTests {
    private func delegateRequest(_ url: String, method: HTTPMethod = .get) -> HTTPRequestSpec {
        HTTPRequestSpec(method: method, url: url, headers: [:], body: method == .get ? nil : Data())
    }

    @Test func delegateStreamDeliversTheWholeBody() async throws {
        let payload = Array("data: hello\n\n".utf8)
        StubURLProtocol.control.reset(StubPlan(statusCode: 200, chunkA: payload))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        var received: [UInt8] = []
        for try await byte in transport.openBytesViaDelegate(delegateRequest("https://example.test/v1/chat")) {
            received.append(byte)
        }
        #expect(received == payload)
        #expect(StubURLProtocol.control.startCount > 0)
    }

    @Test func delegateStreamIsIncrementalRatherThanBuffered() async throws {
        // The gate holds chunkB back, so seeing chunkA before opening it proves bytes are
        // delivered as they arrive rather than accumulated until the response completes.
        let chunkA = Array("data: first\n\n".utf8)
        let chunkB = Array("data: second\n\n".utf8)
        StubURLProtocol.control.reset(
            StubPlan(statusCode: 200, chunkA: chunkA, chunkB: chunkB, gated: true))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        var received: [UInt8] = []
        var sawFirstChunkBeforeGateOpened = false

        for try await byte in transport.openBytesViaDelegate(delegateRequest("https://example.test/v1/chat")) {
            received.append(byte)
            if received.count == chunkA.count, !sawFirstChunkBeforeGateOpened {
                sawFirstChunkBeforeGateOpened = true
                StubURLProtocol.control.openGate()
            }
        }

        #expect(sawFirstChunkBeforeGateOpened)
        #expect(received == chunkA + chunkB)
    }

    @Test func nonSuccessStatusThrowsHttpStatusAndNeverYieldsTheErrorBody() async {
        let errorBody = Array(#"{"error":{"message":"nope"}}"#.utf8)
        StubURLProtocol.control.reset(StubPlan(statusCode: 429, chunkA: errorBody))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        var received: [UInt8] = []
        var thrown: (any Error)?
        do {
            for try await byte in transport.openBytesViaDelegate(delegateRequest("https://example.test/v1/chat")) {
                received.append(byte)
            }
        } catch {
            thrown = error
        }

        // The obligation has two halves and both matter: the status is thrown, AND the
        // error payload never reached the consumer as if it were content.
        #expect(received.isEmpty)
        guard case .httpStatus(let code, let message)? = thrown as? KBLLMError else {
            Issue.record("expected KBLLMError.httpStatus, got \(String(describing: thrown))")
            return
        }
        #expect(code == 429)
        #expect(message.contains("nope"))
    }

    @Test func malformedRequestURLFinishesWithTheTypedError() async {
        StubURLProtocol.control.reset(StubPlan(statusCode: 200))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        // The empty string, not something that merely LOOKS malformed: current Foundation
        // percent-encodes its way through most junk, so `URL(string: "not a url at all")`
        // now succeeds. The empty string is what still returns nil, and it is therefore the
        // only input that reaches the `.invalidRequest` guard.
        var thrown: (any Error)?
        do {
            for try await _ in transport.openBytesViaDelegate(delegateRequest("")) {}
        } catch {
            thrown = error
        }
        guard case .invalidRequest? = thrown as? KBLLMError else {
            Issue.record("expected KBLLMError.invalidRequest, got \(String(describing: thrown))")
            return
        }
    }

    @Test func cancellingTheConsumerStopsTheUnderlyingTask() async {
        let chunkA = Array("data: first\n\n".utf8)
        StubURLProtocol.control.reset(StubPlan(statusCode: 200, chunkA: chunkA, finishes: false))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        let consumer = Task {
            for try await _ in transport.openBytesViaDelegate(delegateRequest("https://example.test/v1/chat")) {
                break   // take one byte, then let go
            }
        }
        _ = await consumer.result

        let stopped = await waitUntil { StubURLProtocol.control.stopCount > 0 }
        #expect(stopped)
        StubURLProtocol.control.openGate()
    }
}
