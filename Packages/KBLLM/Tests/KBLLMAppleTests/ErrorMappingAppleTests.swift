#if canImport(FoundationModels)
import Foundation
import FoundationModels
import KBLLM
import Testing
@testable import KBLLMApple

// The framework's macOS 27 errors are mapped onto EXISTING `KBLLMError` cases in the live
// layer, before they reach `AppleModel`. Each test injects a responder that throws the real
// framework error into a live backend (scripted available, so the run path is reached on any
// machine) and drives it through `AppleModel`, so the whole seam is exercised: none of these
// may fall through to the un-mapped `.upstream` bucket. Every test is macOS 27 only (Swift
// Testing takes the availability per test, not on the suite type).
@Suite struct ErrorMappingAppleTests {
    private let request = ModelRequest(messages: [Message(role: .user, text: "hello")])

    /// Drive a Private Cloud Compute backend whose response op throws `error` through
    /// `AppleModel`, returning the typed error that came out.
    @available(macOS 27, iOS 27, *)
    private func pccError(for error: any Error) async -> KBLLMError? {
        let backend = LivePrivateCloudComputeBackend(
            responder: ThrowingResponder(error),
            metadata: .scriptedAvailable
        )
        return await collect(AppleModel(backend: backend), request).error
    }

    @available(macOS 27, iOS 27, *)
    @Test func networkFailureMapsToTransport() async {
        let error = await pccError(for: PrivateCloudComputeLanguageModel.Error.networkFailure(
            .init(debugDescription: "offline-xyz")
        ))
        guard case .transport(let url, let underlying) = error else {
            Issue.record("expected .transport, got \(String(describing: error))")
            return
        }
        #expect(url == "Private Cloud Compute")
        #expect(underlying.contains("offline-xyz"))
    }

    @available(macOS 27, iOS 27, *)
    @Test func quotaLimitReachedMapsToUnavailable() async {
        let error = await pccError(for: PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: Date(timeIntervalSince1970: 1_800_000_000), debugDescription: "quota-dbg")
        ))
        guard case .unavailable(let reason) = error else {
            Issue.record("expected .unavailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("quota"))
        #expect(reason.contains("2027-01-15T08:00:00Z"))
    }

    @available(macOS 27, iOS 27, *)
    @Test func serviceUnavailableMapsToUnavailable() async {
        let error = await pccError(for: PrivateCloudComputeLanguageModel.Error.serviceUnavailable(
            .init(debugDescription: "svc-down")
        ))
        guard case .unavailable(let reason) = error else {
            Issue.record("expected .unavailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("svc-down"))
    }

    @available(macOS 27, iOS 27, *)
    @Test func contextSizeExceededMapsToInvalidRequest() async {
        let exceeded = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4096, tokenCount: 5000, debugDescription: "ctx-dbg")
        )
        // Both live backends share the mapping, so both are checked.
        let responder = ThrowingResponder(exceeded)
        let backends: [(String, any FoundationModelBackend)] = [
            ("pcc", LivePrivateCloudComputeBackend(responder: responder, metadata: .scriptedAvailable)),
            ("onDevice", LiveFoundationModelBackend(responder: responder, metadata: .scriptedAvailable))
        ]
        for (label, backend) in backends {
            let error = await collect(AppleModel(backend: backend), request).error
            guard case .invalidRequest(let field, let reason) = error else {
                Issue.record("\(label): expected .invalidRequest, got \(String(describing: error))")
                continue
            }
            #expect(field == "messages", "\(label)")
            #expect(reason.contains("4096"), "\(label)")
            #expect(reason.contains("5000"), "\(label)")
        }
    }

    /// The contrast: an error the mapping does not know still becomes `.upstream`, so the four
    /// cases above are mapped deliberately rather than everything being rewritten.
    @available(macOS 27, iOS 27, *)
    @Test func unknownFrameworkErrorStillMapsToUpstream() async {
        let error = await pccError(for: ForeignFailure(detail: "not-a-framework-error"))
        guard case .upstream(let cause) = error else {
            Issue.record("expected .upstream, got \(String(describing: error))")
            return
        }
        #expect(cause.contains("not-a-framework-error"))
    }
}
#endif
