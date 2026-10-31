import Foundation
import KBLLM
import Testing
@testable import KBLLMApple

// Private Cloud Compute is live only on macOS 27 AND for a process signed with its entitlement,
// because an unentitled live request traps inside FoundationModels. The factory's branches are
// driven here with an injected entitlement answer, the raw-value decision with real CF values,
// and the public factory in this (unentitled) test process. No test here runs a live backend:
// the live type is only ever checked with `is`, and a run happens only after a type guard has
// confirmed a stand-in.
@Suite struct PCCEntitlementAppleTests {
    @Test func supportedAndEntitledIsTheLiveBackend() async throws {
        let backend = AppleModelBackends.privateCloudCompute(isSupported: true, isEntitled: { true })
        #if canImport(FoundationModels)
        if #available(macOS 27, iOS 27, *) {
            #expect(backend is LivePrivateCloudComputeBackend)
            return
        }
        #endif
        try await expectStandIn(
            backend,
            is: PrivateCloudComputeUnsupportedBackend.self,
            reason: "Private Cloud Compute requires macOS 27 or later"
        )
    }

    @Test func supportedButUnentitledIsTheEntitlementStandIn() async throws {
        var asked = 0
        let backend = AppleModelBackends.privateCloudCompute(isSupported: true, isEntitled: {
            asked += 1
            return false
        })
        guard Self.osSupportsPCC else {
            try await expectStandIn(
                backend,
                is: PrivateCloudComputeUnsupportedBackend.self,
                reason: "Private Cloud Compute requires macOS 27 or later"
            )
            return
        }
        #expect(asked == 1)
        #expect(PrivateCloudComputeUnentitledBackend.reason
            == "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement")
        try await expectStandIn(
            backend,
            is: PrivateCloudComputeUnentitledBackend.self,
            reason: "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement"
        )
    }

    @Test func unsupportedAndEntitledIsThePre27StandIn() async throws {
        var asked = 0
        let backend = AppleModelBackends.privateCloudCompute(isSupported: false, isEntitled: {
            asked += 1
            return true
        })
        // The OS is checked first: an unsupported OS never consults the entitlement.
        #expect(asked == 0)
        try await expectStandIn(
            backend,
            is: PrivateCloudComputeUnsupportedBackend.self,
            reason: "Private Cloud Compute requires macOS 27 or later"
        )
    }

    @Test func unsupportedAndUnentitledIsThePre27StandIn() async throws {
        var asked = 0
        let backend = AppleModelBackends.privateCloudCompute(isSupported: false, isEntitled: {
            asked += 1
            return false
        })
        #expect(asked == 0)
        try await expectStandIn(
            backend,
            is: PrivateCloudComputeUnsupportedBackend.self,
            reason: "Private Cloud Compute requires macOS 27 or later"
        )
    }

    #if canImport(Darwin)
    @Test func entitlementValueIsTrueOnlyForCFBooleanTrue() {
        #expect(PrivateCloudComputeEntitlement.name == "com.apple.developer.private-cloud-compute")
        #expect(PrivateCloudComputeEntitlement.isGranted(value: kCFBooleanTrue))
        // NSNumber(value: true) bridges to the same CFBoolean, as a plist `<true/>` does.
        #expect(PrivateCloudComputeEntitlement.isGranted(value: NSNumber(value: true)))

        #expect(!PrivateCloudComputeEntitlement.isGranted(value: kCFBooleanFalse))
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: nil))
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: "true" as CFString))
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: NSNumber(value: 1 as Int)))
        // Other truthy-looking shapes deny too.
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: NSNumber(value: 1.0 as Double)))
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: "1" as CFString))
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: [true] as CFArray))
        #expect(!PrivateCloudComputeEntitlement.isGranted(value: ["value": true] as CFDictionary))
    }
    #endif

    @Test func publicFactoryInThisUnentitledRunnerIsAStandIn() async throws {
        #if os(macOS)
        // The real read of this test process's signature: swift test is not granted the entitlement.
        #expect(PrivateCloudComputeEntitlement.isGranted() == false)

        let backend = AppleModelBackends.privateCloudCompute()
        if Self.osSupportsPCC {
            guard backend is PrivateCloudComputeUnentitledBackend else {
                Issue.record("expected the entitlement stand-in, got \(type(of: backend)); not running it")
                return
            }
            try await expectStandIn(
                backend,
                is: PrivateCloudComputeUnentitledBackend.self,
                reason: "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement"
            )
        } else {
            guard backend is PrivateCloudComputeUnsupportedBackend else {
                Issue.record("expected the pre-27 stand-in, got \(type(of: backend)); not running it")
                return
            }
            try await expectStandIn(
                backend,
                is: PrivateCloudComputeUnsupportedBackend.self,
                reason: "Private Cloud Compute requires macOS 27 or later"
            )
        }
        #endif
    }

    /// Whether this OS takes the factory past its OS check (macOS 27 with FoundationModels).
    private static var osSupportsPCC: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27, iOS 27, *) { return true }
        #endif
        return false
    }

    /// A stand-in is exactly `StandIn`, reports `.unavailable(reason:)` with no capabilities, no
    /// quota and no context size, and refuses a run (through `AppleModel` and called directly)
    /// with that same `.unavailable` and no events. Call only once the type is known to be a
    /// stand-in: this RUNS the backend.
    private func expectStandIn<StandIn: FoundationModelBackend>(
        _ backend: any FoundationModelBackend,
        is _: StandIn.Type,
        reason: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard backend is StandIn else {
            Issue.record(
                "expected \(StandIn.self), got \(type(of: backend)); not running it",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(backend.availability == .unavailable(reason: reason), sourceLocation: sourceLocation)
        #expect(backend.capabilities.isEmpty, sourceLocation: sourceLocation)
        #expect(backend.quotaUsage == nil, sourceLocation: sourceLocation)
        #expect(try await backend.contextSize() == nil, sourceLocation: sourceLocation)

        let request = ModelRequest(messages: [Message(role: .user, text: "hello")])
        let result = await collect(AppleModel(backend: backend), request)
        #expect(result.error == .unavailable(reason: reason), sourceLocation: sourceLocation)
        #expect(result.events.isEmpty, sourceLocation: sourceLocation)

        #expect(await drain(backend, request) == .unavailable(reason: reason), sourceLocation: sourceLocation)
    }

    private func drain(_ backend: any FoundationModelBackend, _ request: ModelRequest) async -> KBLLMError? {
        do {
            for try await _ in backend.run(request) {}
            return nil
        } catch {
            return KBLLMError.from(error)
        }
    }
}
