import Foundation

// The shared failure-not-fallback check every adapter runs at stream end. A caller that
// asked for structured output must be handed conforming JSON or a typed error, never
// unconstrained prose silently relabeled as an answer, so the check lives ONCE in the core
// and each adapter calls it rather than re-implementing (and re-diverging on) validation.

public extension JSONSchema {
    /// Validate a collected structured document against this schema, returning the typed
    /// violation to surface when it does not conform, or `nil` when it does.
    ///
    /// The check is intentionally shallow-but-recursive, matching the wire contract: the
    /// document must parse as JSON, its root JSON type must match this schema's, every
    /// `required` name must be present, each array must hold at least its `minItems` elements,
    /// and each present object property and array element is recursed into. It deliberately
    /// does NOT decode to a Swift type (an explicit anti-goal): decoding is the caller's job, on
    /// a document already proven to conform here.
    ///
    /// The `minItems` check is what enforces the minimum for EVERY adapter, including one whose
    /// provider ignores the keyword. Its violation names the node in the parser's path notation
    /// (`root.readings`, `root.groups[].tags`) and the minimum, so the caller can see which
    /// array came up short rather than only that the document failed.
    ///
    /// A string node's `choices` are enforced the same way, for every adapter: a string that is
    /// not one of them is a violation whose `expected` names the node and lists the choices.
    func conformanceViolation(for document: String) -> KBLLMError? {
        guard
            let data = document.data(using: .utf8),
            // `JSONDecoder` rather than `JSONSerialization`: it reads JSON tokens, so a
            // boolean and the numbers 1 and 0 stay distinct without CoreFoundation. It
            // accepts top-level fragments too, matching the old `.fragmentsAllowed`.
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .schemaViolation(expected: expectation, received: document)
        }
        switch mismatch(value, path: "root") {
        case nil:
            return nil
        case .shape:
            return .schemaViolation(expected: expectation, received: document)
        case .tooFewItems(let path, let minimum, let count):
            return .schemaViolation(
                expected: "at least \(minimum) item\(minimum == 1 ? "" : "s") in the array at \(path); got \(count)",
                received: document
            )
        case .notAChoice(let path, let choices, let value):
            return .schemaViolation(
                expected: "one of \(choices) for the string at \(path); got \(String(reflecting: value))",
                received: document
            )
        }
    }

    /// A description of what the schema demanded, for the violation's `expected` field. Never
    /// empty, so the typed error always carries an actionable payload the caller can read.
    private var expectation: String {
        switch self {
        case .object(_, let required, _):
            return "a JSON object with required keys \(required.sorted())"
        case .array:
            return "a JSON array"
        default:
            return "a JSON \(jsonType)"
        }
    }

    /// Why a parsed value fails this schema. A shape failure (wrong type, missing required key)
    /// keeps the root-level expectation it always had; an array under its `minItems` carries
    /// the node's path and the counts, and a string outside its `choices` carries the node's
    /// path, the choices and the value, because "a JSON object with required keys" would not
    /// tell the caller what was actually wrong.
    private enum Mismatch {
        case shape
        case tooFewItems(path: String, minimum: Int, count: Int)
        case notAChoice(path: String, choices: [String], value: String)

        /// Whether this names a node, which is preferred over a generic shape failure.
        var isSpecific: Bool {
            if case .shape = self { false } else { true }
        }
    }

    /// How a parsed JSON value fails this node, or `nil` when it conforms. Recurses into present
    /// object properties and array elements; an absent NON-required property is simply not
    /// checked.
    ///
    /// An under-count or an unlisted choice is reported in preference to a shape failure wherever
    /// both occur, because it is the more specific statement: `{"readings":[1]}` against "at
    /// least 2 reading objects" is wrong twice, and naming `root.readings` and the minimum tells
    /// the caller more than the generic root expectation does. Properties are visited in sorted
    /// order so the reported node is deterministic when more than one node fails. Whether a
    /// document conforms at all is unaffected by this ordering; only which violation is
    /// described changes.
    private func mismatch(_ value: JSONValue, path: String) -> Mismatch? {
        switch self {
        case .object(let properties, let required, _):
            guard case .object(let object) = value else { return .shape }
            return Self.mismatch(object, properties: properties, required: required, path: path)
        case .array(let items, _, let minItems):
            guard case .array(let array) = value else { return .shape }
            // The count is checked BEFORE the elements, so an array that is both too short and
            // holds a wrong element still names its minimum.
            if let minItems, array.count < minItems {
                return .tooFewItems(path: path, minimum: minItems, count: array.count)
            }
            return Self.preferringCount(array.map { items.mismatch($0, path: "\(path)[]") })
        case .string(_, let choices):
            guard case .string(let text) = value else { return .shape }
            if let choices, !choices.contains(text) {
                return .notAChoice(path: path, choices: choices, value: text)
            }
            return nil
        case .boolean:
            if case .bool = value { return nil }
            return .shape
        case .integer, .number:
            // JSON draws no integer/number distinction at the value level, so both accept any
            // numeric literal. A boolean is a DIFFERENT case here rather than a number needing
            // to be told apart from one, which is the whole point of decoding into `JSONValue`.
            if case .number = value { return nil }
            return .shape
        }
    }

    /// How a parsed JSON object fails an object schema's `properties` and `required`, with an
    /// under-count anywhere below preferred over a missing key or a wrong-typed property.
    private static func mismatch(
        _ object: [String: JSONValue],
        properties: [String: JSONSchema],
        required: [String],
        path: String
    ) -> Mismatch? {
        let results = properties.keys.sorted().map { key -> Mismatch? in
            guard let subschema = properties[key], let present = object[key] else { return nil }
            // An explicit null satisfies a property the caller did NOT require. Absent and
            // null are the same statement here, and a provider whose strict mode cannot
            // express absence (OpenAI's) is sent the nullable form, so the answer it
            // returns must validate against the schema as written.
            if case .null = present, !required.contains(key) { return nil }
            return subschema.mismatch(present, path: "\(path).\(key)")
        }
        let missingRequired = required.contains { object[$0] == nil }
        return preferringCount(results) ?? (missingRequired ? .shape : nil)
    }

    /// The first specific failure (an under-count or an unlisted choice) among children's results
    /// if there is one, else any shape failure, else `nil`.
    private static func preferringCount(_ results: [Mismatch?]) -> Mismatch? {
        var found: Mismatch?
        for case let result? in results {
            if result.isSpecific { return result }
            found = result
        }
        return found
    }
}

/// The withhold-and-validate helper each adapter drives on its neutral event production, so the
/// failure-not-fallback rule is applied identically everywhere rather than re-coded per adapter.
///
/// For a plain (schema-absent) request it is a pass-through: every event is forwarded and
/// nothing is withheld. For a structured request it accumulates the content the model streamed
/// and WITHHOLDS the terminal `.completed` until stream end, so a non-conforming answer can be
/// turned into a thrown `.schemaViolation` instead of slipping through as a successful `.stop`.
/// The content deltas themselves are still forwarded as they arrive, so streaming is intact and
/// only the terminal event differs.
public struct StructuredCollector {
    private let schema: JSONSchema?
    private var content = ""
    private var finishReason: FinishReason?

    public init(schema: JSONSchema?) {
        self.schema = schema
    }

    /// Forward `event`, except a structured request's terminal `.completed`, which is captured
    /// and withheld (`nil`) until ``finish()`` has validated the collected document.
    public mutating func absorb(_ event: ModelEvent) -> ModelEvent? {
        guard schema != nil else { return event }
        switch event {
        case .completed(let reason):
            finishReason = reason
            return nil
        case .contentDelta(let delta):
            content += delta
            return event
        default:
            return event
        }
    }

    /// At stream end: `nil` for a plain request (nothing was withheld). For a structured
    /// request, throw `.schemaViolation` when the collected document does not conform, else
    /// return the withheld terminal `.completed`.
    public func finish() throws -> ModelEvent? {
        guard let schema else { return nil }
        if let violation = schema.conformanceViolation(for: content) {
            throw explained(violation)
        }
        return .completed(finishReason ?? .stop)
    }

    /// A document that stopped at the output token limit, or that the model declined to write,
    /// fails conformance for a reason the shape alone does not show: the fix is a larger
    /// `maxOutputTokens`, not a different schema. The finish reason is said out loud.
    private func explained(_ violation: KBLLMError) -> KBLLMError {
        guard case .schemaViolation(let expected, let received) = violation else { return violation }
        switch finishReason {
        case .length:
            return .schemaViolation(
                expected: expected + " (the answer stopped at the output token limit before the "
                    + "document was complete; raise maxOutputTokens)",
                received: received
            )
        case .contentFilter:
            return .schemaViolation(expected: expected + " (the model declined to answer)", received: received)
        default:
            return violation
        }
    }
}
