import Foundation
import KBLLM

// The FoundationModels analogue of `HTTPTransport`: the seam `AppleModel` talks to, in
// place of a wire transport. It names NO `FoundationModels` type in its signatures, so the
// adapter's translation logic (snapshot diffing, tool capture, availability mapping) is
// testable against a scripted fake on a machine with no Apple Intelligence, and the whole
// seam is declared OUTSIDE any `canImport(FoundationModels)` guard so the module vends its
// surface even where the framework is absent. Only the FM-backed implementation is gated.

/// Whether an on-device model can run here, reduced to neutral Swift so the seam carries no
/// `FoundationModels` type. `.unavailable` keeps the framework's reason as a string so the
/// adapter can surface WHY a machine cannot run inference, not merely that it cannot.
public enum FoundationModelAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// One piece of output from a FoundationModels run, already reduced to neutral Swift types.
///
/// A `snapshot` is CUMULATIVE: the framework yields the whole answer-so-far each step, each
/// a prefix-extension of the last, so the adapter (not the seam) owns diffing them into
/// deltas. A `toolCall` is a captured model tool invocation that ENDS the turn: the FM
/// session wants to run tools itself, but a `ToolDefinition` has no executable body, so the
/// backend captures the arguments and ends the turn, and the adapter turns this into a
/// neutral `toolCall` plus a `toolCalls` finish for `AgentSession` to dispatch.
public enum FoundationModelChunk: Sendable, Equatable {
    case snapshot(String)
    case toolCall(name: String, id: String, argumentsJSON: String)
}

/// What a backend's model can do, reduced to neutral Swift so the seam carries no
/// `FoundationModels` type. On macOS 27 the live backends map the framework's
/// `LanguageModelCapabilities` onto this; on macOS 26 the on-device model reports what it has
/// always had (guided generation and tool calling, no vision). `AppleModel` refuses a request
/// that needs a capability the backend does not report, before any run.
public enum FoundationModelCapability: Hashable, Sendable {
    /// Image input: a request's `.image` parts can reach the model.
    case vision
    /// Schema-constrained output: a request's `responseSchema` can be honoured.
    case guidedGeneration
    /// The model reasons before answering. Reported for information; nothing is gated on it.
    case reasoning
    /// The model can ask for a caller tool.
    case toolCalling
}

/// A metered model's usage quota, reduced to neutral Swift. Only the server-backed Private
/// Cloud Compute model is metered; the on-device model reports none (`nil`). `AppleModel`
/// refuses a request while `isLimitReached` holds, before any run, rather than sending one
/// the service is known to reject.
public struct FoundationModelQuotaUsage: Sendable, Equatable {
    /// The quota is used up: no request will be served until `resetDate`.
    public let isLimitReached: Bool
    /// Still below the limit, but close to it. Requests are still dispatched.
    public let isApproachingLimit: Bool
    /// When the quota resets, if the service said.
    public let resetDate: Date?

    public init(isLimitReached: Bool, isApproachingLimit: Bool, resetDate: Date? = nil) {
        self.isLimitReached = isLimitReached
        self.isApproachingLimit = isApproachingLimit
        self.resetDate = resetDate
    }
}

/// The seam `AppleModel` consumes. A host (or a test) supplies availability and a run that
/// yields cumulative snapshots and any captured tool call; the adapter owns every neutral
/// translation. Availability is a property, not a call, so the adapter can check it BEFORE
/// asking for any inference and a fake can prove no inference happened on the unavailable
/// path. Modeled on `HTTPTransport`: the adapter names no framework type, only this seam.
///
/// `capabilities`, `contextSize()` and `quotaUsage` each have a default in the extension
/// below, so a conformer written before they existed compiles unchanged and behaves as the
/// macOS 26 on-device model always has.
public protocol FoundationModelBackend: Sendable {
    /// Whether inference can run here, checked before any run so an unavailable machine
    /// never starts inference it cannot finish.
    var availability: FoundationModelAvailability { get }

    /// What the backend's model can do. `AppleModel` refuses an image without `.vision`, a
    /// `responseSchema` without `.guidedGeneration` and tools without `.toolCalling`.
    var capabilities: Set<FoundationModelCapability> { get }

    /// The model's context size in tokens, or `nil` when the backend cannot say. Async and
    /// throwing because the server model answers it over the network. `AppleModel` refuses a
    /// request whose estimated size exceeds it; `nil` or a throw dispatches unchecked.
    func contextSize() async throws -> Int?

    /// The model's usage quota, or `nil` for an unmetered model.
    var quotaUsage: FoundationModelQuotaUsage? { get }

    /// Run one request against a FRESH session and yield its cumulative snapshots (and any
    /// captured tool call). A fresh session per call is the no-caching guarantee: a session
    /// carries conversation state the caller already owns, so it is never reused across
    /// calls. The returned stream is finite.
    func run(_ request: ModelRequest) -> AsyncThrowingStream<FoundationModelChunk, any Error>
}

public extension FoundationModelBackend {
    /// Today's on-device behaviour on macOS 26: guided generation and tool calling, no vision.
    var capabilities: Set<FoundationModelCapability> { [.guidedGeneration, .toolCalling] }

    /// Unknown, so `AppleModel` dispatches without a context check.
    func contextSize() async throws -> Int? { nil }

    /// Unmetered.
    var quotaUsage: FoundationModelQuotaUsage? { nil }
}
