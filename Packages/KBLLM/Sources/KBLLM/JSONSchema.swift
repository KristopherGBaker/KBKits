import Foundation

/// A provider-neutral JSON Schema value. It is a closed enum rather than a free-form
/// dictionary so the macros can only emit shapes the client actually understands, and
/// so a reader can see the whole vocabulary in one place. Adapters render this to
/// whatever their wire format wants.
public indirect enum JSONSchema: Sendable, Equatable {
    case object(properties: [String: JSONSchema], required: [String], description: String?)
    /// A JSON string, optionally limited to a fixed set of values.
    ///
    /// `choices` is the list of allowed values, the JSON Schema `enum` keyword on a string node.
    /// It is `nil` (any string) unless the caller asks, and the default keeps every existing
    /// `.string(description:)` construction compiling unchanged. An empty list, a repeated value
    /// or an empty-string value is refused as `.invalidRequest` by ``validate()``, which every
    /// adapter runs before it opens a transport or starts inference.
    ///
    /// Where it is enforced: Anthropic sends `"enum"` in a tool `input_schema`, in the legacy
    /// strict structured tool and in `output_config.format.schema` (whose grammar takes string
    /// enums as written). OpenAI sends it in `response_format.json_schema` (strict, with `null`
    /// added to the list for an optional property, which strict mode sends as nullable) and in
    /// tool `parameters`. Apple renders the node as a `DynamicGenerationSchema` built from the
    /// choices (`anyOf:`), so the on-device and Private Cloud Compute models can only generate
    /// one of them. Whatever the provider does with it, the post-decode conformance check
    /// (``conformanceViolation(for:)``) refuses a structured answer whose string is not one of
    /// the choices with a typed `.schemaViolation` naming them. The macros never emit it.
    case string(description: String?, choices: [String]? = nil)
    case integer(description: String?)
    case number(description: String?)
    case boolean(description: String?)
    /// A JSON array whose every element matches `items`.
    ///
    /// `minItems` is the minimum element count, the JSON Schema keyword of the same name. It
    /// is `nil` (no minimum) unless the caller asks, and the default keeps every existing
    /// `.array(items:description:)` construction compiling unchanged. A negative `minItems`
    /// is refused as `.invalidRequest` by ``validate()``, which every adapter runs before it
    /// opens a transport or starts inference; `0` is allowed and means "may be empty".
    ///
    /// Where it is enforced: Anthropic sends `"minItems"` in a tool `input_schema` (and so in
    /// legacy-route structured output; its `output_config.format` grammar takes only 0 or 1, so
    /// a larger minimum is sent as 1 and stated in the description), OpenAI sends it in `response_format.json_schema`
    /// (strict) and in tool `parameters`, and Apple maps it onto the
    /// `DynamicGenerationSchema` minimum element count. Whatever the provider does with it,
    /// the post-decode conformance check (``conformanceViolation(for:)``) refuses a
    /// structured answer whose array is shorter, so an under-count is a typed
    /// `.schemaViolation`, never a quietly accepted answer. The macros never emit it.
    case array(items: JSONSchema, description: String?, minItems: Int? = nil)
}

public extension JSONSchema {
    /// The JSON Schema `type` keyword for this node, as the string a provider expects.
    var jsonType: String {
        switch self {
        case .object: "object"
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .array: "array"
        }
    }

    /// The node's description, wherever it appears in the vocabulary.
    var schemaDescription: String? {
        switch self {
        case .object(_, _, let description),
             .string(let description, _),
             .integer(let description),
             .number(let description),
             .boolean(let description),
             .array(_, let description, _):
            description
        }
    }

    /// The minimum element count, when this node is an array that sets one.
    var minItems: Int? {
        if case .array(_, _, let minItems) = self { minItems } else { nil }
    }

    /// The allowed values, when this node is a string that sets them.
    var choices: [String]? {
        if case .string(_, let choices) = self { choices } else { nil }
    }

    /// Check that this schema is one a provider can be sent, throwing `.invalidRequest` naming
    /// the offending node when it is not.
    ///
    /// The values a construction can get wrong are a negative `minItems`, and a string's
    /// `choices` that are empty, repeat a value or hold an empty string. The type cannot forbid
    /// them, and a provider would reject them with an opaque 400, ignore them, or constrain the
    /// model to an answer that cannot exist, so they are refused here, before any request
    /// leaves. Every adapter calls this on the
    /// `responseSchema` and on each tool's `parameters` BEFORE it opens a transport or runs
    /// inference, which makes this the single choke point rather than a per-adapter check.
    /// The walk covers the whole tree, and the field uses the parser's path notation
    /// (`root`, `root.<prop>`, `root.<prop>[]`), so the error points at the exact node.
    func validate() throws(KBLLMError) {
        try validate(path: "root")
    }

    private func validate(path: String) throws(KBLLMError) {
        switch self {
        case .object(let properties, _, _):
            for name in properties.keys.sorted() {
                try properties[name]?.validate(path: "\(path).\(name)")
            }
        case .array(let items, _, let minItems):
            if let minItems, minItems < 0 {
                throw KBLLMError.invalidRequest(
                    field: path,
                    reason: "minItems must be a non-negative integer; got \(minItems)"
                )
            }
            try items.validate(path: "\(path)[]")
        case .string(_, let choices):
            if let choices, let problem = Self.problem(withChoices: choices) {
                throw KBLLMError.invalidRequest(field: path, reason: problem)
            }
        case .integer, .number, .boolean:
            break
        }
    }

    /// Why a string's `choices` cannot be sent, or `nil` when they can. Shared with the parser,
    /// so a schema written as JSON and one built in Swift are held to the same rule.
    internal static func problem(withChoices choices: [String]) -> String? {
        if choices.isEmpty {
            return "choices (enum) must list at least one value; an empty list admits no answer"
        }
        if choices.contains("") {
            return "choices (enum) must not contain an empty string"
        }
        var seen: Set<String> = []
        if let repeated = choices.first(where: { !seen.insert($0).inserted }) {
            return "choices (enum) must not repeat a value; \"\(repeated)\" appears more than once"
        }
        return nil
    }

    /// The child property schemas, when this node is an object.
    var properties: [String: JSONSchema]? {
        if case .object(let properties, _, _) = self { properties } else { nil }
    }

    /// The required property names, when this node is an object.
    var requiredProperties: [String]? {
        if case .object(_, let required, _) = self { required } else { nil }
    }
}
