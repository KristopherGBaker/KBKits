import Foundation
import KBLLM
import Testing
@testable import KBLLMApple
#if canImport(FoundationModels)
import FoundationModels
#endif

// The Private Cloud Compute entry point is callable from macOS 26 code with no `#available`:
// before 27 it is an unavailable stand-in that answers and refuses every run. On 27 the
// factory also gates on the entitlement (PCCEntitlementAppleTests covers those branches and
// the public factory in this process). The neutral capability set is mapped from the
// framework's own `LanguageModelCapabilities`, and a conformer written before capabilities
// existed reports today's on-device set by default.
@Suite struct PCCAvailabilityAppleTests {
    @Test func pccReportsRequiresMacOS27OnSimulatedPre27Path() async {
        let backend = AppleModelBackends.privateCloudCompute(isSupported: false)
        guard case .unavailable(let reason) = backend.availability else {
            Issue.record("expected .unavailable, got \(backend.availability)")
            return
        }
        #expect(reason.contains("requires macOS 27"))
        #expect(backend.capabilities.isEmpty)

        let request = ModelRequest(messages: [Message(role: .user, text: "hello")])
        let result = await collect(AppleModel(backend: backend), request)
        guard case .unavailable(let thrown) = result.error else {
            Issue.record("expected .unavailable, got \(String(describing: result.error))")
            return
        }
        #expect(thrown.contains("macOS 27"))
        #expect(result.events.isEmpty)

        // Called directly, the stand-in's run refuses with the same reason rather than trying.
        #expect(await drainStandIn(backend, request) == .unavailable(reason: reason))
    }

    #if canImport(FoundationModels)
    @available(macOS 27, iOS 27, *)
    @Test func neutralCapabilitiesMapFromLanguageModelCapabilities() {
        #expect(
            FoundationModelCapability.set(from: LanguageModelCapabilities([.vision, .reasoning]))
                == [.vision, .reasoning]
        )
        #expect(
            FoundationModelCapability.set(from: LanguageModelCapabilities([.guidedGeneration, .toolCalling]))
                == [.guidedGeneration, .toolCalling]
        )
        #expect(FoundationModelCapability.set(from: LanguageModelCapabilities([])).isEmpty)
    }
    #endif

    @Test func defaultSeamCapabilitiesMatchTodaysOnDevice() async throws {
        let backend = AvailabilityAndRunOnlyBackend()
        #expect(backend.capabilities == [.guidedGeneration, .toolCalling])
        #expect(try await backend.contextSize() == nil)
        #expect(backend.quotaUsage == nil)
    }

    private func drainStandIn(_ backend: any FoundationModelBackend, _ request: ModelRequest) async -> KBLLMError? {
        do {
            for try await _ in backend.run(request) {}
            return nil
        } catch {
            return KBLLMError.from(error)
        }
    }
}

/// A conformer that declares ONLY what the seam required before capabilities, context size
/// and quota existed, so it sees the protocol defaults.
private struct AvailabilityAndRunOnlyBackend: FoundationModelBackend {
    var availability: FoundationModelAvailability { .available }

    func run(_ request: ModelRequest) -> AsyncThrowingStream<FoundationModelChunk, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
