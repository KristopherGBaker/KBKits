import Foundation

// The refusals every adapter makes before a request leaves, whatever the provider: server-side
// search on a model without it, RULING 19's schema-plus-tools, and a schema no provider could
// honour. One copy, so a wording fix or a new neutral rule lands once and every adapter's
// refusal reads the same. `package` access: the adapter targets reach it and the library's
// surface does not grow. Each adapter calls it first and keeps its provider-specific refusals
// in its own module, passing them in when they must run between the neutral rules.

/// How far the pre-dispatch walk looks into each caller tool.
package enum ToolSchemaWalk: Sendable {
    /// ``ToolDefinition/validate()``: the `parameters` rules, and a `rawParameters` that must be an
    /// object schema. For an adapter that sends `rawParameters` as written.
    case definition
    /// The tool's `parameters` alone, for an adapter that never sends `rawParameters` (Apple's
    /// builds the FoundationModels schema from `parameters`, so it has no raw schema to check).
    case parametersOnly
}

extension ModelRequest {
    /// Throw the first neutral refusal this request earns, in a fixed order: search the model
    /// cannot do, then structured output combined with caller tools (RULING 19), then the
    /// adapter's own `providerRules`, then the ``JSONSchema/validate()`` walk over the
    /// `responseSchema` and each tool. The order is part of what a caller sees when a request
    /// breaks several rules at once, so it does not vary by adapter.
    ///
    /// - Parameters:
    ///   - supportsWebSearch: whether the adapter offers server-side search; when it does not, a
    ///     request asking for it is refused rather than answered from the model's own memory,
    ///     stale knowledge dressed as a researched answer.
    ///   - toolWalk: how far the walk looks into each tool.
    ///   - providerRules: the adapter's own refusals that must win over a schema the walk would
    ///     refuse (Anthropic's search-with-schema and prefill rules).
    package func validateNeutralRules(
        supportsWebSearch: Bool,
        toolWalk: ToolSchemaWalk = .definition,
        providerRules: () throws(KBLLMError) -> Void = {}
    ) throws(KBLLMError) {
        if webSearch != nil, !supportsWebSearch {
            throw KBLLMError.invalidRequest(
                field: "webSearch",
                reason: "this model does not support server-side web search (supportsWebSearch is false)"
            )
        }
        // RULING 19: a request cannot ask for BOTH structured output and caller tools. No adapter
        // can honour both on one turn, and honouring one silently would drop what the caller
        // asked for, so it is refused before dispatch, naming both fields.
        if responseSchema != nil, !tools.isEmpty {
            throw KBLLMError.invalidRequest(
                field: "responseSchema+tools",
                reason: "responseSchema and tools cannot be combined in one request"
            )
        }
        try providerRules()
        // A schema no provider could honour (a negative `minItems`) is refused here, before the
        // transport opens or inference runs, by the one core check every adapter shares.
        try responseSchema?.validate()
        for tool in tools {
            switch toolWalk {
            case .definition: try tool.validate()
            case .parametersOnly: try tool.parameters.validate()
            }
        }
    }
}
