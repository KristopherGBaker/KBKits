import Foundation
import KBLLM

// The ENTIRE FoundationModels translation lives in this one file: it speaks no wire format,
// so there is no request shaping and no SSE grammar. It diffs the framework's CUMULATIVE
// streaming snapshots into `contentDelta`, turns a captured model tool call into one neutral
// `toolCall` plus a `toolCalls` finish, and maps unavailability and any foreign error onto
// the typed `KBLLMError` surface. It talks ONLY to the injected `FoundationModelBackend`
// seam; it owns no `FoundationModels` type, so this file compiles everywhere the seam does.
// It is also the single choke point for every pre-dispatch refusal: a capability the model
// lacks (vision, guidedGeneration, toolCalling), a used-up quota, and a request over the
// model's context size are each refused here, before any backend run.

/// A `LanguageModel` over Apple's `FoundationModels`: the on-device model, or the Private
/// Cloud Compute model on macOS 27, whichever backend is injected. It checks availability,
/// capabilities, quota and context size, runs the request against the backend, diffs
/// cumulative snapshots into deltas, and captures a model tool call as a neutral `toolCall`
/// the caller's `AgentSession` dispatches. It implements only `stream`; the collected path
/// is derived in the core.
public struct AppleModel: LanguageModel {
    private let backend: any FoundationModelBackend

    /// The backend is never defaulted: the adapter picks no model or session for the caller,
    /// and injecting the seam is how tests drive translation logic with no real inference.
    public init(backend: any FoundationModelBackend) {
        self.backend = backend
    }

    /// Whether the backend's model can run here, exactly as the backend reports it, so a
    /// caller can explain an unavailable model before sending anything.
    public var availability: FoundationModelAvailability { backend.availability }

    /// What the backend's model can do. A request that needs a capability missing from this
    /// set is refused before dispatch, so a caller can check it first and adapt the request.
    public var capabilities: Set<FoundationModelCapability> { backend.capabilities }

    /// The backend's usage quota, or `nil` for an unmetered model.
    public var quotaUsage: FoundationModelQuotaUsage? { backend.quotaUsage }

    /// The backend's context size in tokens, or `nil` when it cannot say. A caller holding a
    /// long history trims it to this deliberately, with `trimmedToFit(maxTokens:)`, because the
    /// adapter refuses an over-size request rather than silently dropping turns.
    public func contextSize() async throws -> Int? {
        try await backend.contextSize()
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let backend = self.backend
        return AsyncThrowingStream { continuation in
            // A request this adapter must refuse (RULING 19's schema-plus-tools, or a schema no
            // provider could honour) is rejected before ANY backend run, so `inferenceCount`
            // stays zero.
            if let refusal = Self.preDispatchRefusal(for: request) {
                continuation.finish(throwing: refusal)
                return
            }
            // Availability is checked BEFORE any inference: an unavailable machine must fail
            // as a typed `.unavailable` without ever asking the backend to run, so the
            // no-inference-on-the-unavailable-path guarantee is observable.
            if case .unavailable(let reason) = backend.availability {
                continuation.finish(throwing: KBLLMError.unavailable(reason: reason))
                return
            }
            // A request that needs a capability the model lacks is refused, never downgraded:
            // dropping the picture, the schema or the tools would answer a different question.
            if let refusal = Self.capabilityRefusal(for: request, capabilities: backend.capabilities) {
                continuation.finish(throwing: refusal)
                return
            }
            // A used-up quota is a can't-run-here-now outcome, so it is `.unavailable`, refused
            // here rather than spent on a round trip the service is known to reject.
            if let quota = backend.quotaUsage, quota.isLimitReached {
                continuation.finish(throwing: KBLLMError.unavailable(reason: Self.quotaReason(quota)))
                return
            }
            let task = Task {
                do {
                    // The context check is async (the server model answers it over the
                    // network), so it runs here, still before the backend is asked to run.
                    if let refusal = await Self.contextRefusal(for: request, backend: backend) {
                        throw refusal
                    }
                    // On a structured request the terminal `.completed` is withheld until the
                    // collected document (the diffed snapshot content) is validated against the
                    // supplied schema: an on-device answer that ignores the shape must fail, not
                    // surface as prose.
                    var structured = StructuredCollector(schema: request.responseSchema)
                    // The framework yields the whole answer-so-far each step; `previous`
                    // holds the last snapshot so each emitted delta is the NEW suffix only.
                    // Emitting snapshots verbatim would make the collected content quadratic,
                    // because the core builds it by concatenating deltas.
                    var previous = ""
                    var sawToolCall = false
                    for try await chunk in backend.run(request) {
                        switch chunk {
                        case .snapshot(let snapshot):
                            // An empty or repeated snapshot carries no new text, so it emits
                            // no delta rather than a `""` or a duplicated prefix.
                            if snapshot.isEmpty || snapshot == previous { continue }
                            if request.responseSchema != nil {
                                // A STRUCTURED snapshot is a whole document that the framework
                                // REVISES as it fills fields in, not a growing prefix. Observed
                                // on device: {"word":"nekko","reading":""} is followed by
                                // {"reading":"ねこ","word":"nekko"}, with keys reordered and a
                                // value replaced. Diffing that yields garbage, and the
                                // prefix guard below rejects a perfectly good answer, so the
                                // latest snapshot simply REPLACES the last one and only the
                                // final document is emitted, at completion.
                                previous = snapshot
                                continue
                            }
                            // Free text IS cumulative, so a snapshot that does not extend its
                            // predecessor is a framework contract violation. Fail loudly with
                            // the offending fragment rather than emitting a negative delta or
                            // silently corrupting the collected content.
                            guard snapshot.hasPrefix(previous) else {
                                throw KBLLMError.decoding(
                                    expected: "a cumulative snapshot extending the previous one",
                                    fragment: snapshot
                                )
                            }
                            let delta = String(snapshot.dropFirst(previous.count))
                            previous = snapshot
                            if let forwarded = structured.absorb(.contentDelta(delta)) {
                                continuation.yield(forwarded)
                            }
                        case .toolCall(let name, let id, let argumentsJSON):
                            // The model asked to call a tool. `ToolDefinition` has no body, so
                            // the adapter CANNOT run it: it surfaces the neutral `toolCall`
                            // and a `toolCalls` finish, exactly as the HTTP adapters do, and
                            // `AgentSession` dispatches the real tool in the next turn.
                            sawToolCall = true
                            let record = ToolCallRecord(
                                id: id,
                                name: name,
                                arguments: Data(argumentsJSON.utf8)
                            )
                            if let forwarded = structured.absorb(.toolCall(record)) {
                                continuation.yield(forwarded)
                            }
                        }
                    }
                    // The structured path accumulated nothing as it went, because each snapshot
                    // replaced the last rather than extending it, so the final document is
                    // emitted here as one delta. Its concatenation is still exactly the
                    // document, which is what the streaming contract requires.
                    if request.responseSchema != nil, !previous.isEmpty {
                        if let forwarded = structured.absorb(.contentDelta(previous)) {
                            continuation.yield(forwarded)
                        }
                    }
                    // The terminal is routed through the collector: on a structured request it
                    // is withheld and replaced by `finish()`, which throws `.schemaViolation`
                    // when the collected document does not conform.
                    if let forwarded = structured.absorb(.completed(sawToolCall ? .toolCalls : .stop)) {
                        continuation.yield(forwarded)
                    }
                    if let terminal = try structured.finish() {
                        continuation.yield(terminal)
                    }
                    continuation.finish()
                } catch {
                    // Total mapping: a typed error passes through, any foreign error the
                    // backend surfaces becomes `.upstream` rather than escaping untyped.
                    continuation.finish(throwing: KBLLMError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The typed refusal for a request that must never reach the backend, or `nil` to proceed.
    ///
    /// RULING 19: structured output and caller tools cannot be combined, so both fields are
    /// named rather than one silently dropped. Then the schemas go through the same core
    /// ``JSONSchema/validate()`` the HTTP adapters call before their transport opens, so a
    /// negative `minItems` in the `responseSchema` or any tool's `parameters` is refused here
    /// exactly as it is there. A helper rather than inline so `stream` stays one readable body.
    private static func preDispatchRefusal(for request: ModelRequest) -> KBLLMError? {
        // FoundationModels has no server-side search, on device or on Private Cloud Compute, so
        // a request asking for one is refused rather than answered from the model's own memory.
        if request.webSearch != nil {
            return .invalidRequest(
                field: "webSearch",
                reason: "this model does not support server-side web search (supportsWebSearch is false)"
            )
        }
        if request.responseSchema != nil, !request.tools.isEmpty {
            return .invalidRequest(
                field: "responseSchema+tools",
                reason: "responseSchema and tools cannot be combined in one request"
            )
        }
        do {
            try request.responseSchema?.validate()
            for tool in request.tools { try tool.parameters.validate() }
        } catch {
            return error
        }
        return nil
    }

    /// The typed refusal for a request that needs a capability the backend does not report,
    /// or `nil` to proceed. Each refusal names the field and the missing capability, so a
    /// caller knows what to drop or which model to pick instead.
    private static func capabilityRefusal(
        for request: ModelRequest,
        capabilities: Set<FoundationModelCapability>
    ) -> KBLLMError? {
        if !capabilities.contains(.vision),
           request.messages.contains(where: { $0.content.contains(where: Self.isImage) }) {
            return .invalidRequest(
                field: "content.image",
                reason: "this model does not report the vision capability; image input needs a "
                    + "vision-capable Apple model on macOS 27 or later"
            )
        }
        if !capabilities.contains(.guidedGeneration), request.responseSchema != nil {
            return .invalidRequest(
                field: "responseSchema",
                reason: "this model does not report the guidedGeneration capability, so it cannot "
                    + "constrain its answer to a schema"
            )
        }
        if !capabilities.contains(.toolCalling), !request.tools.isEmpty {
            return .invalidRequest(
                field: "tools",
                reason: "this model does not report the toolCalling capability, so it cannot call tools"
            )
        }
        return nil
    }

    /// The typed refusal for a request whose estimated size exceeds the backend's context
    /// size, or `nil` to proceed. REFUSE, not trim: silently dropping history would answer a
    /// different conversation than the one sent ("never silently downgrade a request"), so the
    /// caller trims deliberately with `trimmedToFit(maxTokens:)`. An unknown size (`nil`) or a
    /// failed lookup dispatches unchecked; the live layer maps the framework's own
    /// `contextSizeExceeded` as the backstop.
    private static func contextRefusal(
        for request: ModelRequest,
        backend: any FoundationModelBackend
    ) async -> KBLLMError? {
        guard let contextSize = try? await backend.contextSize() else { return nil }
        let estimator = CharacterCountEstimator()
        let estimate = request.messages.reduce(0) { $0 + estimator.estimatedTokens(for: $1) }
        guard estimate > contextSize else { return nil }
        return .invalidRequest(
            field: "messages",
            reason: "the request is an estimated \(estimate) tokens, over the model's context size of "
                + "\(contextSize) tokens; trim the history with trimmedToFit(maxTokens:) and resend"
        )
    }

    /// The `.unavailable` reason for a used-up quota, naming when it resets if known.
    private static func quotaReason(_ quota: FoundationModelQuotaUsage) -> String {
        guard let resetDate = quota.resetDate else { return "the model's usage quota is used up" }
        return "the model's usage quota is used up until \(resetDate.formatted(.iso8601))"
    }

    /// Whether a neutral content part is an image, so the adapter can refuse an image-bearing
    /// request before dispatch without duplicating the pattern match at the call site.
    private static func isImage(_ part: MessageContent) -> Bool {
        if case .image = part { return true }
        return false
    }
}
