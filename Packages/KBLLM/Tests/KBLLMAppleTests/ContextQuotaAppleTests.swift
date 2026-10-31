import Foundation
import KBLLM
// Deliberately NOT `@testable`: every symbol this file names must be public, so the compiler
// proves the access level of the new seam surface and the Private Cloud Compute entry point.
import KBLLMApple
import Testing

// `AppleModel` REFUSES a request whose estimated size exceeds the backend's context size (it
// never silently drops history), dispatches when the size is unknown or its lookup fails,
// refuses while the quota is used up, and exposes the backend's availability, capabilities,
// quota and context size unchanged so a caller can act on them first.
@Suite struct ContextQuotaAppleTests {
    private func request(characters: Int) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: String(repeating: "a", count: characters))])
    }

    @Test func overContextSizeRefusedPreDispatch() async {
        // 800 characters at 4 per token is an estimate of 200, over a context size of 100.
        let fake = FakeFoundationModelBackend(contextSize: .size(100), script: .snapshots(["ok"]))
        let result = await collect(AppleModel(backend: fake), request(characters: 800))
        guard case .invalidRequest(let field, let reason) = result.error else {
            Issue.record("expected .invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(field == "messages")
        #expect(reason.contains("100"))
        #expect(reason.contains("200"))
        #expect(fake.inferenceCount == 0)
        #expect(result.events.isEmpty)
    }

    @Test func underContextSizeDispatches() async {
        let fits = FakeFoundationModelBackend(contextSize: .size(100), script: .snapshots(["ok"]))
        let fitsResult = await collect(AppleModel(backend: fits), request(characters: 200))
        #expect(fitsResult.error == nil)
        #expect(fits.inferenceCount == 1)

        // An unknown size, or a lookup that fails, dispatches unchecked: the framework's own
        // contextSizeExceeded (mapped in the live layer) is the backstop.
        for script in [FakeFoundationModelBackend.ContextSizeScript.size(nil), .throwing("lookup failed")] {
            let unknown = FakeFoundationModelBackend(contextSize: script, script: .snapshots(["ok"]))
            let result = await collect(AppleModel(backend: unknown), request(characters: 800))
            #expect(result.error == nil, "\(script)")
            #expect(unknown.inferenceCount == 1, "\(script)")
        }
    }

    @Test func trimmedHistoryFitsAndDispatches() async {
        // Five turns of 400 characters (100 tokens each) is 500 tokens against a size of 100.
        let turn = String(repeating: "b", count: 400)
        let history = [
            Message(role: .user, text: turn),
            Message(role: .assistant, text: turn),
            Message(role: .user, text: turn),
            Message(role: .assistant, text: turn),
            Message(role: .user, text: turn)
        ]
        let fake = FakeFoundationModelBackend(contextSize: .size(100), script: .snapshots(["ok"]))
        let model = AppleModel(backend: fake)

        let untrimmed = await collect(model, ModelRequest(messages: history))
        guard case .invalidRequest(let field, _) = untrimmed.error else {
            Issue.record("expected the untrimmed history refused, got \(String(describing: untrimmed.error))")
            return
        }
        #expect(field == "messages")
        #expect(fake.inferenceCount == 0)

        // The caller trims deliberately, to the size the adapter exposes, and resends.
        let trimmed = history.trimmedToFit(maxTokens: 100)
        #expect(trimmed.count < history.count)
        #expect(trimmed.last == history.last)
        let dispatched = await collect(model, ModelRequest(messages: trimmed))
        #expect(dispatched.error == nil)
        #expect(fake.inferenceCount == 1)
    }

    @Test func quotaLimitReachedRefusedPreDispatch() async {
        let quota = FoundationModelQuotaUsage(
            isLimitReached: true,
            isApproachingLimit: false,
            resetDate: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let fake = FakeFoundationModelBackend(quotaUsage: quota, script: .snapshots(["ok"]))
        let result = await collect(AppleModel(backend: fake), request(characters: 20))
        guard case .unavailable(let reason) = result.error else {
            Issue.record("expected .unavailable, got \(String(describing: result.error))")
            return
        }
        #expect(reason.contains("quota"))
        #expect(reason.contains("2027-01-15T08:00:00Z"))
        #expect(fake.inferenceCount == 0)
        #expect(result.events.isEmpty)
    }

    @Test func approachingQuotaStillDispatches() async {
        let quota = FoundationModelQuotaUsage(isLimitReached: false, isApproachingLimit: true)
        let fake = FakeFoundationModelBackend(quotaUsage: quota, script: .snapshots(["ok"]))
        let result = await collect(AppleModel(backend: fake), request(characters: 20))
        #expect(result.error == nil)
        #expect(fake.inferenceCount == 1)
        #expect(result.content == "ok")
    }

    @Test func adapterExposesBackendAvailabilityCapabilitiesQuotaAndContextSize() async throws {
        // Every value differs from the seam's defaults, so a forwarder that returned a default
        // instead of asking the backend fails.
        let quota = FoundationModelQuotaUsage(
            isLimitReached: false,
            isApproachingLimit: true,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fake = FakeFoundationModelBackend(
            availability: .unavailable(reason: "scripted-off-42"),
            capabilities: [.vision, .reasoning],
            contextSize: .size(4321),
            quotaUsage: quota
        )
        let model = AppleModel(backend: fake)
        #expect(model.availability == .unavailable(reason: "scripted-off-42"))
        #expect(model.capabilities == [.vision, .reasoning])
        #expect(model.quotaUsage == quota)
        #expect(model.quotaUsage?.isApproachingLimit == true)
        #expect(model.quotaUsage?.resetDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await model.contextSize() == 4321)
        #expect(fake.inferenceCount == 0)

        // The public Private Cloud Compute entry point, called from a file without `@testable`,
        // so its access level (and the quota fields') is compiler-proven. Metadata only, never a
        // run. Both stand-ins (before macOS 27, or without the entitlement) are unmetered; only
        // the live server model reports a quota.
        let pcc = AppleModel(backend: AppleModelBackends.privateCloudCompute())
        let limitReached: Bool? = pcc.quotaUsage?.isLimitReached
        let standInReasons = [
            "Private Cloud Compute requires macOS 27 or later",
            "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement"
        ]
        if case .unavailable(let reason) = pcc.availability, standInReasons.contains(reason) {
            #expect(limitReached == nil)
        } else {
            #expect(limitReached != nil)
        }
    }
}
