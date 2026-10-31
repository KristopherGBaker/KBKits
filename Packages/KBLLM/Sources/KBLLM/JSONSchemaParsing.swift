import Foundation

public extension JSONSchema {
    /// Parses a JSON Schema document into the neutral schema this package sends.
    ///
    /// It exists because schemas are often AUTHORED as JSON, not as Swift values: a caller with
    /// a hand-written schema, or one loaded from a file, would otherwise have to transcribe it
    /// into `JSONSchema` cases by hand and keep the two in step.
    ///
    /// It is deliberately STRICT about what it does not understand. This vocabulary covers
    /// objects, arrays, strings, numbers, integers and booleans, plus two constraints: `minItems`
    /// on an array node, which must be a non-negative JSON integer, and `enum` on a string node,
    /// which becomes the node's `choices` and must list distinct, non-empty strings. Anything
    /// beyond that (`anyOf`, `$ref`, `pattern`, `maxItems`, `const` and every other keyword) is
    /// outside the vocabulary. Accepting such a document and dropping the part that does not fit
    /// would send the provider a weaker schema than the caller wrote, and the caller would find
    /// out from a malformed answer rather than from an error. So anything unrepresentable is
    /// named and refused, and so is a `minItems` that is negative, not an integer, or not on an
    /// array, and an `enum` that is not on a string node or lists anything but strings.
    static func parse(_ json: String) throws(KBLLMError) -> JSONSchema {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw KBLLMError.decoding(expected: "a JSON Schema document", fragment: String(json.prefix(512)))
        }
        return try parse(node: object, path: "root").schema
    }

    /// Keywords this parser understands. Everything else in a node is a constraint or a
    /// composition it cannot represent, and is refused by name.
    ///
    /// `additionalProperties` is accepted and ignored ONLY because the emitter sets it to
    /// `false` itself on every object; a document setting it to `true` is asking for the
    /// opposite of what would be sent, so that is refused below rather than silently flipped.
    ///
    /// `minItems` is understood here but valid ONLY on an array node, and `enum` ONLY on a string
    /// node; a node of any other type that sets one is refused by name rather than letting it
    /// ride along unread.
    private static let understood: Set<String> = [
        "type", "properties", "required", "items", "description", "title", "additionalProperties",
        "minItems", "enum"
    ]

    /// A parsed node, plus whether it was written as nullable.
    ///
    /// Nullability is carried alongside rather than as a `JSONSchema` case because it is not a
    /// kind of schema, it is a statement the ENCLOSING object makes about one of its
    /// properties. This vocabulary states that by omission from `required`; the wire states it
    /// with a union type, because OpenAI's strict mode requires every property in `required`
    /// and so leaves no other way to say it. The two are translated into each other at the
    /// boundary, in both directions.
    private typealias ParsedNode = (schema: JSONSchema, isNullable: Bool)

    private static func parse(node: Any, path: String) throws(KBLLMError) -> ParsedNode {
        guard let node = node as? [String: Any] else {
            throw KBLLMError.invalidRequest(field: path, reason: "expected a schema object")
        }
        if let unsupported = node.keys.sorted().first(where: { !understood.contains($0) }) {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "\'\(unsupported)\' is not representable in this schema vocabulary; "
                    + "supported keywords are \(understood.sorted().joined(separator: ", "))"
            )
        }
        if let additional = node["additionalProperties"] as? Bool, additional {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "additionalProperties must be false; strict structured output forbids extra properties"
            )
        }
        let description = node["description"] as? String
        let (type, isNullable) = try typeName(of: node, path: path)
        if type != "array", node["minItems"] != nil {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "minItems applies only to an array schema; this node is \'\(type)\'"
            )
        }
        if type != "string", node["enum"] != nil {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "enum applies only to a string schema; this node is \'\(type)\'"
            )
        }
        return (try schema(ofType: type, node: node, path: path, description: description), isNullable)
    }

    /// A string node's `enum` as its `choices`, or `nil` when the node does not set one.
    ///
    /// Every member must be a JSON string, `null` included: a choices list holds only strings.
    /// An optional choice is expressed by leaving the property out of the enclosing object's
    /// `required` (or, in OpenAI's strict form, by the `["string", "null"]` type union), never by
    /// listing `null` among the values, so a `null` member is refused rather than dropped. The
    /// list is then held to the same rule ``validate()`` applies. A nullable string WITHOUT
    /// `enum` is unaffected and parses as an optional plain string.
    private static func choices(of node: [String: Any], path: String) throws(KBLLMError) -> [String]? {
        guard let raw = node["enum"] else { return nil }
        guard let members = raw as? [Any] else {
            throw KBLLMError.invalidRequest(field: path, reason: "enum must be an array of strings; got \(raw)")
        }
        var choices: [String] = []
        for member in members {
            if member is NSNull {
                throw KBLLMError.invalidRequest(
                    field: path,
                    reason: "enum on a string schema must list only strings; got null. A choices list holds "
                        + "only strings: express an optional choice by leaving the property out of 'required'"
                )
            }
            guard let text = member as? String else {
                let got = token(of: member).map(describe) ?? "\(member)"
                throw KBLLMError.invalidRequest(
                    field: path,
                    reason: "enum on a string schema must list only strings; got \(got)"
                )
            }
            choices.append(text)
        }
        if let problem = problem(withChoices: choices) {
            throw KBLLMError.invalidRequest(field: path, reason: problem)
        }
        return choices
    }

    /// One `JSONSerialization` value read back as a JSON token, so a `true` and a `1` (both
    /// `NSNumber` there) stay distinct; `nil` when it cannot be re-encoded.
    private static func token(of raw: Any) -> JSONValue? {
        (try? JSONSerialization.data(withJSONObject: [raw]))
            .flatMap { try? JSONDecoder().decode([JSONValue].self, from: $0) }?
            .first
    }

    /// An array node's `minItems`, or `nil` when the node does not set one.
    ///
    /// The value is read at the JSON TOKEN level (through ``JSONValue``) rather than by casting
    /// the `JSONSerialization` result: there a `true` and a `1` both arrive as `NSNumber`, and
    /// telling them apart portably is exactly the trap ``JSONValue`` documents. A boolean, a
    /// string, a fractional number or a negative one is refused by name, never coerced.
    ///
    /// The token holds a `Double`, which represents every integer exactly only below 2^53. Above
    /// that, distinct JSON integers collapse onto one value (9007199254740993 reads back as
    /// 9007199254740992), so accepting them would send the provider a minimum the caller never
    /// wrote. They are refused instead; no real array minimum comes anywhere near the bound.
    private static func minItems(of node: [String: Any], path: String) throws(KBLLMError) -> Int? {
        guard let raw = node["minItems"] else { return nil }
        let token = token(of: raw)
        guard case .number(let number) = token, let count = Int(exactly: number), count >= 0 else {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "minItems must be a non-negative integer; got \(token.map(describe) ?? "\(raw)")"
            )
        }
        guard count < exactIntegerLimit else {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "minItems must be below 2^53 (\(exactIntegerLimit)) to be read exactly; got \(raw)"
            )
        }
        return count
    }

    /// 2^53: from here up a `Double` can no longer tell an integer from its successor, so the
    /// parsed value might not be the one written.
    private static let exactIntegerLimit = 1 << 53

    /// A refused `minItems` value as the caller wrote it, so the error shows `"2"` for a
    /// string and `true` for a boolean rather than the bridged `NSNumber` they parsed into.
    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): "\(flag)"
        case .number(let number): "\(number)"
        case .string(let text): "\"\(text)\""
        case .array: "an array"
        case .object: "an object"
        }
    }

    /// The node's type, and whether it was written as a union with null.
    ///
    /// `["string", "null"]` is how a schema authored for OpenAI strict mode says "optional",
    /// and it is exactly what this package EMITS for a property the caller left out of
    /// `required`. Accepting it makes the two directions inverses, so a schema written for
    /// OpenAI parses unchanged instead of needing a rewrite into this vocabulary\'s convention.
    private static func typeName(of node: [String: Any], path: String) throws(KBLLMError) -> (String, Bool) {
        if let type = node["type"] as? String { return (type, false) }
        guard let union = node["type"] as? [String] else {
            throw KBLLMError.invalidRequest(field: path, reason: "missing \'type\'")
        }
        let concrete = union.filter { $0 != "null" }
        guard concrete.count == 1, union.contains("null") else {
            throw KBLLMError.invalidRequest(
                field: path,
                reason: "a union type is supported only as an optional marker, one type plus \'null\'; got \(union)"
            )
        }
        return (concrete[0], true)
    }

    private static func schema(
        ofType type: String,
        node: [String: Any],
        path: String,
        description: String?
    ) throws(KBLLMError) -> JSONSchema {
        switch type {
        case "object":
            let rawProperties = node["properties"] as? [String: Any] ?? [:]
            var properties: [String: JSONSchema] = [:]
            var nullable: Set<String> = []
            for name in rawProperties.keys.sorted() {
                guard let child = rawProperties[name] else { continue }
                let parsed = try parse(node: child, path: "\(path).\(name)")
                properties[name] = parsed.schema
                if parsed.isNullable { nullable.insert(name) }
            }
            let declared = node["required"] as? [String] ?? []
            if let missing = declared.first(where: { properties[$0] == nil }) {
                throw KBLLMError.invalidRequest(
                    field: path,
                    reason: "\'\(missing)\' is listed in \'required\' but is not one of the properties"
                )
            }
            // A nullable property is optional here even though the source lists it as
            // required, which is the whole point of the union on the wire.
            return .object(
                properties: properties,
                required: declared.filter { !nullable.contains($0) },
                description: description
            )
        case "array":
            guard let items = node["items"] else {
                throw KBLLMError.invalidRequest(field: path, reason: "an array schema needs \'items\'")
            }
            return .array(
                items: try parse(node: items, path: "\(path)[]").schema,
                description: description,
                minItems: try minItems(of: node, path: path)
            )
        case "string":
            return .string(description: description, choices: try choices(of: node, path: path))
        case "integer":
            return .integer(description: description)
        case "number":
            return .number(description: description)
        case "boolean":
            return .boolean(description: description)
        default:
            throw KBLLMError.invalidRequest(field: path, reason: "unsupported type \'\(type)\'")
        }
    }
}
