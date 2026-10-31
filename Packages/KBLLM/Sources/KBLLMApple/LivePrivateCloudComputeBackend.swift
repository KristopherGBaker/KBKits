#if canImport(FoundationModels)
import Foundation
import FoundationModels
import KBLLM

// The Private Cloud Compute `FoundationModelBackend`: Apple's server model, macOS 27 only. It
// shares the on-device backend's run path (`LiveRun`), so tools, schemas, images and error
// mapping behave identically; only the model, its metadata and the session it builds differ.
// Callers on a macOS 26 floor reach it through `AppleModelBackends.privateCloudCompute()`,
// which needs no `#available` and returns an unavailable stand-in before 27, and on 27 also
// gates on the com.apple.developer.private-cloud-compute entitlement (an unentitled request
// traps inside FoundationModels). Constructing this type directly skips that gate.

/// Wraps the real `PrivateCloudComputeLanguageModel`: maps availability, capabilities, quota
/// and context size onto the neutral seam, and runs each request against a FRESH
/// `LanguageModelSession` (never cached across calls, since a session carries conversation
/// state the caller already owns).
@available(macOS 27, iOS 27, *)
public struct LivePrivateCloudComputeBackend: FoundationModelBackend {
    private let model: PrivateCloudComputeLanguageModel
    private let responder: any FoundationModelResponder
    private let metadata: LiveModelMetadata?

    /// The server model needs no key and no configuration; the response operation is the real
    /// session op.
    public init(model: PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel()) {
        self.model = model
        self.responder = SessionResponder { tools, instructions in
            LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        self.metadata = nil
    }

    /// Inject a fake response operation, and optionally scripted metadata, so a test drives the
    /// real run path and error mapping with no network and no inference. Internal, so only a
    /// `@testable` test reaches it.
    init(
        model: PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel(),
        responder: any FoundationModelResponder,
        metadata: LiveModelMetadata? = nil
    ) {
        self.model = model
        self.responder = responder
        self.metadata = metadata
    }

    public var availability: FoundationModelAvailability {
        if let metadata { return metadata.availability() }
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        }
    }

    public var capabilities: Set<FoundationModelCapability> {
        if let metadata { return metadata.capabilities() }
        return FoundationModelCapability.set(from: model.capabilities)
    }

    public func contextSize() async throws -> Int? {
        if let metadata { return try await metadata.contextSize() }
        return try await model.contextSize
    }

    public var quotaUsage: FoundationModelQuotaUsage? {
        if let metadata { return metadata.quotaUsage() }
        let usage = model.quotaUsage
        var approaching = false
        if case .belowLimit(let below) = usage.status { approaching = below.isApproachingLimit }
        return FoundationModelQuotaUsage(
            isLimitReached: usage.isLimitReached,
            isApproachingLimit: approaching,
            resetDate: usage.resetDate
        )
    }

    public func run(_ request: ModelRequest) -> AsyncThrowingStream<FoundationModelChunk, any Error> {
        LiveRun.run(request, responder: responder)
    }

    /// Map the framework's reason onto a stable string, as the on-device backend does.
    private static func describe(
        _ reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible: return "deviceNotEligible"
        case .systemNotReady: return "systemNotReady"
        @unknown default: return "unavailable"
        }
    }
}
#endif
