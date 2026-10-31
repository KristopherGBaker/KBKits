import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBLLM
import KBLLMURLSession
import Testing

// The `KBLLMURLSession` transport, exercised through a stub `URLProtocol` so the REAL
// `URLSession` code path runs entirely offline. The suite is serialized because the stub's
// control block is shared static state that each test resets and scripts.
@Suite(.serialized)
struct TransportTests {
    private func request(_ url: String, method: HTTPMethod = .get) -> HTTPRequestSpec {
        HTTPRequestSpec(method: method, url: url, headers: [:], body: method == .get ? nil : Data())
    }

    // MARK: Assertion 2 - usable as `any HTTPTransport`; env-var store returns the env value.

    @Test func transportIsUsableAsHTTPTransportAndStreamsTheBody() async throws {
        let payload = Array("data: hello\n\n".utf8)
        StubURLProtocol.control.reset(StubPlan(statusCode: 200, chunkA: payload))
        let transport: any HTTPTransport = KBLLMURLSession(configuration: stubbedConfiguration())

        var received: [UInt8] = []
        for try await byte in transport.openBytes(request("https://example.test/v1/chat/completions")) {
            received.append(byte)
        }
        #expect(received == payload)
        #expect(StubURLProtocol.control.startCount > 0)
    }

    @Test func environmentCredentialStoreReturnsTheValueSetInTheEnvironment() async throws {
        let key = "KBLLM_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        setenv(key, "sekret-value", 1)
        defer { unsetenv(key) }

        let store: any CredentialStore = EnvironmentCredentialStore()
        let value = try await store.secret(forKey: key)
        #expect(value == "sekret-value")

        // An absent variable throws `.missingCredential` naming the key.
        let absentKey = "KBLLM_TEST_ABSENT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        await #expect(throws: KBLLMError.missingCredential(key: absentKey)) {
            _ = try await store.secret(forKey: absentKey)
        }
    }

    // MARK: Assertion 4 - the streaming path is offline AND incremental.

    @Test func streamingIsOfflineAndDeliversIncrementally() async throws {
        let chunkA = Array("AAAA".utf8)
        let chunkB = Array("BBBB".utf8)
        StubURLProtocol.control.reset(StubPlan(statusCode: 200, chunkA: chunkA, chunkB: chunkB, gated: true))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        let collected = Box<[UInt8]>([])
        let finished = Box(false)
        let task = Task {
            do {
                for try await byte in transport.openBytes(request("https://example.test/stream")) {
                    collected.mutate { $0.append(byte) }
                }
            } catch {
                // A buffering or offline-broken implementation may throw; the assertions below
                // (A observed before B, stub counter moved) still capture the failure.
            }
            finished.mutate { $0 = true }
        }

        // Incremental: A must reach the consumer while B is still withheld behind the gate.
        let observedA = await waitUntil { collected.get().count >= chunkA.count }
        // Always release the gate so a buffering implementation cannot wedge the stub.
        StubURLProtocol.control.openGate()
        #expect(observedA, "chunk A must reach the consumer before chunk B is sent")
        // Offline: the stub intercepted the request, so nothing escaped and its counter moved.
        #expect(StubURLProtocol.control.startCount > 0)

        #expect(await waitUntil { finished.get() })
        _ = await task.value
        #expect(collected.get() == chunkA + chunkB)
    }

    // MARK: Assertion 5 - a non-success status throws `.httpStatus`, no bytes yielded first.

    @Test func nonSuccessStatusThrowsHttpStatusCarryingTheServerMessage() async {
        let body = Array(#"{"error":{"message":"bad request body"}}"#.utf8)
        StubURLProtocol.control.reset(
            StubPlan(statusCode: 400, headers: ["Content-Type": "application/json"], chunkA: body)
        )
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        var received: [UInt8] = []
        var caught: KBLLMError?
        do {
            for try await byte in transport.openBytes(request("https://example.test/v1/chat/completions", method: .post)) {
                received.append(byte)
            }
        } catch {
            caught = KBLLMError.from(error)
        }

        #expect(received.isEmpty, "the error body must never be yielded as stream content")
        guard case .httpStatus(let code, let message) = caught else {
            Issue.record("expected .httpStatus, got \(String(describing: caught))")
            return
        }
        #expect(code == 400)
        #expect(message.contains("bad request body"))
    }

    // MARK: Assertion 7 - cancelling the consumer cancels the underlying URLSession task.

    @Test func cancellingTheConsumerCancelsTheUnderlyingTask() async {
        let chunkA = Array("open".utf8)
        // finishes=false keeps the connection open, so a cancel has a live task to cancel.
        StubURLProtocol.control.reset(StubPlan(statusCode: 200, chunkA: chunkA, finishes: false))
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())

        let collected = Box<[UInt8]>([])
        let task = Task {
            do {
                for try await byte in transport.openBytes(request("https://example.test/stream")) {
                    collected.mutate { $0.append(byte) }
                }
            } catch {
                // Cancellation surfaces as a thrown error; the stub's stopLoading is the signal.
            }
        }

        // Wait until the stream is live, then cancel the consuming task.
        _ = await waitUntil { collected.get().count >= chunkA.count }
        task.cancel()
        let stopped = await waitUntil { StubURLProtocol.control.stopCount > 0 }
        // Release the stub's parked keep-open thread so it can exit.
        StubURLProtocol.control.openGate()
        #expect(stopped, "cancelling the consumer must cancel the URLSession task (stopLoading fires)")
        _ = await task.value
    }
}
