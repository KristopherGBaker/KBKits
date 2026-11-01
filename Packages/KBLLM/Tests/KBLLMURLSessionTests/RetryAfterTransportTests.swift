import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBLLM
@testable import KBLLMURLSession
import Testing

// An extension of `TransportTests`, not a suite of its own, for the reason
// `DelegateByteStreamTests` gives: the stub's control block is shared, and only one serialized
// suite keeps two tests from reading each other's plan.
extension TransportTests {
    // MARK: Retry-After - carried only when asked for, on both streaming paths.

    private func statusError(
        _ transport: KBLLMURLSession, headers: [String: String], delegate: Bool = false
    ) async -> KBLLMError? {
        StubURLProtocol.control.reset(StubPlan(statusCode: 429, headers: headers, chunkA: Array("slow down".utf8)))
        let spec = HTTPRequestSpec(method: .post, url: "https://example.test/v1/chat/completions", headers: [:], body: Data())
        let stream = delegate ? transport.openBytesViaDelegate(spec) : transport.openBytes(spec)
        do {
            for try await _ in stream {}
        } catch {
            return KBLLMError.from(error)
        }
        return nil
    }

    @Test func retryAfterIsCarriedWhenTheTransportIsAskedForIt() async {
        let transport = KBLLMURLSession(configuration: stubbedConfiguration(), reportsRetryAfter: true)
        for delegate in [false, true] {
            let caught = await statusError(transport, headers: ["Retry-After": "7"], delegate: delegate)
            #expect(caught == .httpStatusRetryAfter(code: 429, message: "slow down", retryAfter: 7), "delegate: \(delegate)")
            // An HTTP date in the past is no wait.
            let dated = await statusError(
                transport, headers: ["retry-after": "Wed, 21 Oct 2015 07:28:00 GMT"], delegate: delegate
            )
            #expect(dated?.retryAfter == 0, "delegate: \(delegate)")
            // No header, or one that does not read: the plain status, as always.
            #expect(await statusError(transport, headers: [:], delegate: delegate) == .httpStatus(code: 429, message: "slow down"))
            #expect(
                await statusError(transport, headers: ["Retry-After": "later"], delegate: delegate)
                    == .httpStatus(code: 429, message: "slow down")
            )
        }
    }

    @Test func retryAfterIsNotCarriedByDefault() async {
        let transport = KBLLMURLSession(configuration: stubbedConfiguration())
        for delegate in [false, true] {
            let caught = await statusError(transport, headers: ["Retry-After": "7"], delegate: delegate)
            #expect(caught == .httpStatus(code: 429, message: "slow down"), "delegate: \(delegate)")
        }
    }
}
