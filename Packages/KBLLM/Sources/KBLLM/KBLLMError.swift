import Foundation

/// The single exhaustive error surface for the whole client. Every case carries the
/// fields a caller needs to FIX the problem, not merely a label for what failed, so
/// a `switch` over this enum is enough to write recovery. It is deliberately not
/// extensible from outside: an adapter that hits a novel failure maps it into one of
/// these cases (via ``from(_:)``) rather than inventing a parallel error type.
///
/// Tool failures are NOT represented here. A failing tool becomes an error
/// ``ToolResult`` the model can recover from; only transport-level and protocol
/// failures escape as a thrown `KBLLMError`.
public enum KBLLMError: Error, Sendable, Equatable {
    /// A transport could not reach the provider. Carries the endpoint attempted and a
    /// description of the underlying cause so a caller can retry or reconfigure.
    case transport(url: String, underlying: String)

    /// The provider answered with a non-success HTTP status. Carries the status code
    /// and any server-supplied message so a caller can distinguish 429 from 500.
    case httpStatus(code: Int, message: String)

    /// A required credential was absent or rejected. Carries the key the host's
    /// ``CredentialStore`` must supply.
    case missingCredential(key: String)

    /// The provider's bytes could not be decoded. Carries what was expected and the
    /// offending fragment so the mismatch is diagnosable without a debugger.
    case decoding(expected: String, fragment: String)

    /// The model asked for a tool the caller never registered. Carries the tool name
    /// so the caller knows exactly what to add.
    case unknownTool(name: String)

    /// The request was malformed before dispatch. Carries the offending field and why
    /// it was rejected.
    case invalidRequest(field: String, reason: String)

    /// A foreign error surfaced by an adapter's `stream` that is not itself a
    /// `KBLLMError`. Carries a description of the cause so it is never silently
    /// swallowed. This is the case the core normalization choke points produce.
    case upstream(cause: String)

    /// The work was CANCELLED. It has its own case because `complete` uses typed throws and
    /// therefore cannot rethrow Swift's `CancellationError`, so without this a cancelled call
    /// would arrive as `.upstream(cause: "CancellationError()")` and every caller written the
    /// normal way, catching cancellation to distinguish it from failure, would misread it as an
    /// upstream fault. Found by migrating a real consumer whose retry policy promises never to
    /// retry a cancelled call.
    case cancelled

    /// The requested model cannot run here. Carries the reason so a caller can tell a
    /// machine-cannot outcome ("Apple Intelligence is off", "device not eligible") from a
    /// request-wrong one. This is the honest availability surface for an on-device model:
    /// `.transport` would fabricate an endpoint an on-device model does not have, and
    /// `.upstream` is the un-mapped-foreign bucket that would erase the machine-cannot vs
    /// request-wrong distinction. Added deliberately when the on-device Apple adapter
    /// landed, since no existing case honestly fits an unavailable local model.
    case unavailable(reason: String)

    /// A schema was requested and the answer does not conform. Carries what the schema
    /// demanded and the document that actually arrived, so a caller can see WHY the
    /// structured answer was rejected instead of being handed unconstrained prose. Added
    /// deliberately when structured output landed: the bytes decoded fine, so `.decoding`
    /// would misreport; the request was well-formed, so `.invalidRequest` would misreport;
    /// this is the honest surface for "the model answered but ignored the requested shape",
    /// which is a failure, never a silent fall back to prose.
    case schemaViolation(expected: String, received: String)
}

// `LocalizedError`, because these reach PEOPLE. House style says an error a person will see
// conforms to it, and this one is the surface a chat app shows when a turn fails. Without the
// conformance a caller doing `error as? any LocalizedError` gets nil and falls back to a generic
// sentence, which is how a server explaining exactly what is wrong ends up as "something went
// wrong". The server's own words are carried through rather than replaced: it knows why, and
// paraphrasing it would lose the one detail the reader needs.
extension KBLLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let url, let underlying):
            "Could not reach \(url). \(underlying)"
        case .httpStatus(let code, let message):
            message.isEmpty ? "The server answered \(code)." : "The server answered \(code). \(message)"
        case .missingCredential(let key):
            "No credential is set for \(key)."
        case .decoding(let expected, let fragment):
            "Could not read the response. Expected \(expected), got \(fragment)."
        case .unknownTool(let name):
            "The model asked for a tool that does not exist: \(name)."
        case .invalidRequest(let field, let reason):
            "The request was refused: \(field) \(reason)."
        case .upstream(let cause):
            cause
        case .cancelled:
            "Cancelled."
        case .unavailable(let reason):
            reason
        case .schemaViolation(let expected, let received):
            "The model answered in the wrong shape. Expected \(expected), got \(received)."
        }
    }
}

public extension KBLLMError {
    /// Normalize any error into the typed surface. An error that is already a
    /// `KBLLMError` passes through unchanged; anything foreign is wrapped as
    /// ``upstream(cause:)`` so a non-typed failure can never escape the core.
    static func from(_ error: any Error) -> KBLLMError {
        if let typed = error as? KBLLMError {
            return typed
        }
        // Cancellation is not an upstream fault and must stay distinguishable.
        if error is CancellationError {
            return .cancelled
        }
        return .upstream(cause: String(describing: error))
    }
}
