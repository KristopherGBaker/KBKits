import Foundation
import KBLLM
import Testing

// `minItems` on `JSONSchema.array`, in the core: construction, parsing, the `validate()` choke
// point every adapter calls before dispatch, and post-decode conformance. The provider and
// Apple suites pin what each adapter does with it on the way out.
@Suite struct MinItemsSchemaTests {
    /// `{readings: [string]}` with the given minimum, the shape the conformance tests count.
    private func readings(minItems: Int?) -> JSONSchema {
        .object(
            properties: ["readings": .array(items: .string(description: nil), description: nil, minItems: minItems)],
            required: ["readings"],
            description: nil
        )
    }

    /// `{groups: [{tags: [string]}]}`, an array nested inside an array's element object.
    private func groups(outer: Int? = nil, tags: Int?) -> JSONSchema {
        let tagList = JSONSchema.array(items: .string(description: nil), description: nil, minItems: tags)
        return .object(
            properties: [
                "groups": .array(
                    items: .object(
                        properties: ["tags": tagList],
                        required: ["tags"],
                        description: nil
                    ),
                    description: nil,
                    minItems: outer
                )
            ],
            required: ["groups"],
            description: nil
        )
    }

    // MARK: Construction

    @Test func theDefaultedMinimumKeepsOldConstructionsAndTakesPartInEquality() {
        let items = JSONSchema.string(description: nil)
        let legacy = JSONSchema.array(items: items, description: nil)
        #expect(legacy == .array(items: items, description: nil, minItems: nil))
        #expect(legacy.minItems == nil)
        #expect(JSONSchema.array(items: items, description: nil, minItems: 2) != legacy)
        #expect(JSONSchema.array(items: items, description: nil, minItems: 2).minItems == 2)
        #expect(JSONSchema.array(items: items, description: "d", minItems: 1).schemaDescription == "d")
    }

    /// The macros are unchanged: a `[String]` parameter still becomes an array with no minimum.
    @Test func theToolMacroStillGeneratesNoMinimum() throws {
        let parameters = summarizeTagsTool().definition.parameters
        let tags = try #require(parameters.properties?["tags"])
        #expect(tags.jsonType == "array")
        #expect(tags.minItems == nil)
        // The macro attaches the parameter's doc line as the description; only that differs.
        #expect(tags == .array(items: .string(description: nil), description: tags.schemaDescription))
    }

    // MARK: Parse

    @Test func parseAcceptsANonNegativeMinimum() throws {
        let two = try JSONSchema.parse(#"{"type":"array","items":{"type":"string"},"minItems":2}"#)
        #expect(two == .array(items: .string(description: nil), description: nil, minItems: 2))
        let zero = try JSONSchema.parse(#"{"type":"array","items":{"type":"string"},"minItems":0}"#)
        #expect(zero == .array(items: .string(description: nil), description: nil, minItems: 0))
        let absent = try JSONSchema.parse(#"{"type":"array","items":{"type":"string"}}"#)
        #expect(absent == .array(items: .string(description: nil), description: nil, minItems: nil))
    }

    @Test func parseAcceptsAMinimumOnANullableOptionalArray() throws {
        let schema = try JSONSchema.parse(#"""
        { "type": "object", "required": ["tags"],
          "properties": { "tags": { "type": ["array", "null"], "items": { "type": "string" }, "minItems": 1 } } }
        """#)
        #expect(schema == .object(
            properties: ["tags": .array(items: .string(description: nil), description: nil, minItems: 1)],
            required: [],
            description: nil
        ))
    }

    @Test(arguments: ["-1", "1.5", #""2""#, "true", "false", "null", "[1]", "{}"])
    func parseRefusesAMinimumThatIsNotANonNegativeInteger(value: String) {
        let error = parseError(#"{"type":"array","items":{"type":"string"},"minItems":\#(value)}"#)
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected invalidRequest for minItems \(value), got \(String(describing: error))")
            return
        }
        #expect(field == "root")
        #expect(reason.contains("minItems"))
    }

    @Test(arguments: ["string", "integer", "number", "boolean", "object"])
    func parseRefusesAMinimumOnANonArrayNode(type: String) {
        let error = parseError(#"{"type":"\#(type)","minItems":1}"#)
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected invalidRequest for minItems on \(type), got \(String(describing: error))")
            return
        }
        #expect(field == "root")
        #expect(reason.contains("minItems"))
    }

    @Test func parseNamesTheNestedPathOfANegativeMinimum() {
        let error = parseError(#"""
        { "type": "object", "required": ["tags"],
          "properties": { "tags": { "type": "array", "items": { "type": "string" }, "minItems": -1 } } }
        """#)
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == "root.tags")
        #expect(reason.contains("minItems"))
    }

    /// Accepting `minItems` must not have opened the door to the other constraints.
    @Test func parseStillRefusesEveryOtherConstraint() {
        for (fragment, keyword) in [
            (#"{"type":"array","items":{"type":"string"},"maxItems":3}"#, "maxItems"),
            (#"{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}"#, "maxItems"),
            (#"{"type":"integer","enum":[1]}"#, "enum"),
            (#"{"type":"string","pattern":"^a"}"#, "pattern"),
            (#"{"anyOf":[{"type":"string"}]}"#, "anyOf"),
            (##"{"type":"array","items":{"$ref":"#/x"}}"##, "$ref")
        ] {
            guard case .invalidRequest(_, let reason) = parseError(fragment) else {
                Issue.record("expected '\(keyword)' to be refused")
                continue
            }
            #expect(reason.contains(keyword))
        }
    }

    private func parseError(_ json: String) -> KBLLMError? {
        do {
            _ = try JSONSchema.parse(json)
            return nil
        } catch {
            return error
        }
    }

    // MARK: validate()

    @Test func validateRefusesANegativeMinimumAndNamesTheNode() {
        let error = validateError(groups(outer: -1, tags: nil))
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == "root.groups")
        #expect(reason.contains("minItems"))
    }

    @Test func validateAcceptsZeroAndNil() throws {
        try groups(outer: 0, tags: nil).validate()
        try groups(outer: nil, tags: nil).validate()
        try JSONSchema.array(items: .string(description: nil), description: nil, minItems: 0).validate()
        try JSONSchema.string(description: nil).validate()
    }

    @Test func validateRefusesANegativeMinimumAtTheRoot() {
        let error = validateError(.array(items: .string(description: nil), description: nil, minItems: -3))
        guard case .invalidRequest(let field, _) = error else {
            Issue.record("expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == "root")
    }

    /// The walk reaches an array inside an array's element object, not just the top level.
    @Test func validateRefusesNestedNegative() throws {
        let error = validateError(groups(outer: nil, tags: -1))
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == "root.groups[].tags")
        #expect(reason.contains("minItems"))
        try groups(outer: nil, tags: 0).validate()
    }

    private func validateError(_ schema: JSONSchema) -> KBLLMError? {
        do {
            try schema.validate()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Conformance

    @Test func conformanceAcceptsTheMinimumAndMore() {
        #expect(readings(minItems: 2).conformanceViolation(for: #"{"readings":["a","b"]}"#) == nil)
        #expect(readings(minItems: 2).conformanceViolation(for: #"{"readings":["a","b","c"]}"#) == nil)
    }

    @Test func conformanceRefusesAnUnderCountNamingThePathAndTheMinimum() {
        let document = #"{"readings":["a"]}"#
        guard case .schemaViolation(let expected, let received) = readings(minItems: 2)
            .conformanceViolation(for: document) else {
            Issue.record("expected a schemaViolation for one reading")
            return
        }
        #expect(expected.contains("root.readings"))
        #expect(expected.contains("at least 2"))
        #expect(received == document)
    }

    @Test func conformanceRefusesAnEmptyArrayUnderAMinimum() {
        guard case .schemaViolation(let expected, _) = readings(minItems: 2)
            .conformanceViolation(for: #"{"readings":[]}"#) else {
            Issue.record("expected a schemaViolation for no readings")
            return
        }
        #expect(expected.contains("at least 2"))
    }

    @Test func conformanceAcceptsAnEmptyArrayWithZeroOrNoMinimum() {
        #expect(readings(minItems: 0).conformanceViolation(for: #"{"readings":[]}"#) == nil)
        #expect(readings(minItems: nil).conformanceViolation(for: #"{"readings":[]}"#) == nil)
    }

    @Test func conformanceChecksANestedArrayMinimum() {
        let schema = groups(tags: 1)
        #expect(schema.conformanceViolation(for: #"{"groups":[{"tags":["x"]},{"tags":["y","z"]}]}"#) == nil)
        guard case .schemaViolation(let expected, _) = schema
            .conformanceViolation(for: #"{"groups":[{"tags":["x"]},{"tags":[]}]}"#) else {
            Issue.record("expected a schemaViolation for the empty inner tags")
            return
        }
        #expect(expected.contains("root.groups[]"))
        #expect(expected.contains("root.groups[].tags"))
        #expect(expected.contains("at least 1"))
    }

    @Test func conformanceChecksARootArrayMinimum() {
        let schema = JSONSchema.array(items: .integer(description: nil), description: nil, minItems: 1)
        #expect(schema.conformanceViolation(for: "[1]") == nil)
        guard case .schemaViolation(let expected, _) = schema.conformanceViolation(for: "[]") else {
            Issue.record("expected a schemaViolation for an empty root array")
            return
        }
        #expect(expected.contains("root"))
        #expect(expected.contains("at least 1"))
    }

    /// A shape failure keeps the expectation it always had, so callers matching on it see no
    /// change from the minimum check existing.
    @Test func aShapeFailureKeepsItsRootExpectation() {
        guard case .schemaViolation(let expected, _) = readings(minItems: 2)
            .conformanceViolation(for: #"{"other":1}"#) else {
            Issue.record("expected a schemaViolation for a missing required key")
            return
        }
        #expect(expected == "a JSON object with required keys [\"readings\"]")
    }

    /// An optional array sent as nullable may come back null; the minimum governs an array
    /// that is present, not one the caller allowed to be absent.
    @Test func aNullOptionalArrayIsNotHeldToItsMinimum() {
        let schema = JSONSchema.object(
            properties: ["tags": .array(items: .string(description: nil), description: nil, minItems: 1)],
            required: [],
            description: nil
        )
        #expect(schema.conformanceViolation(for: #"{"tags":null}"#) == nil)
        #expect(schema.conformanceViolation(for: "{}") == nil)
        #expect(schema.conformanceViolation(for: #"{"tags":[]}"#) != nil)
    }
}

// Regressions: a parsed minimum is never silently changed, and an under-count is still named
// when the same document is wrong in other ways too.
extension MinItemsSchemaTests {
    /// The largest integer a `Double` token still holds exactly parses to itself.
    @Test func parseKeepsTheLargestExactMinimum() throws {
        let json = #"{"type":"array","items":{"type":"string"},"minItems":9007199254740991}"#
        #expect(try JSONSchema.parse(json).minItems == 9_007_199_254_740_991)
    }

    /// 9007199254740993 would read back as 9007199254740992: refused, never rounded.
    @Test(arguments: ["9007199254740992", "9007199254740993", "18446744073709551616", "1e300"])
    func parseRefusesAMinimumTooLargeToReadExactly(value: String) {
        let error = parseError(#"{"type":"array","items":{"type":"string"},"minItems":\#(value)}"#)
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected invalidRequest for minItems \(value), got \(String(describing: error))")
            return
        }
        #expect(field == "root")
        #expect(reason.contains("minItems"))
    }

    /// Too short AND holding a wrong element: the minimum is still what the error names.
    @Test func anUnderCountIsNamedEvenWhenTheElementsAreWrongToo() {
        let value: [String: JSONSchema] = ["value": .string(description: nil)]
        let reading = JSONSchema.object(properties: value, required: ["value"], description: nil)
        let schema = JSONSchema.object(
            properties: ["readings": .array(items: reading, description: nil, minItems: 2)],
            required: ["readings"],
            description: nil
        )
        expectUnderCount(schema.conformanceViolation(for: #"{"readings":[1]}"#), path: "root.readings", minimum: 2)
    }

    /// A sibling that fails its shape first (in sorted order), or a missing required key, does
    /// not hide the under-count either.
    @Test func anUnderCountIsPreferredOverAnotherPropertysShapeFailure() {
        let schema = JSONSchema.object(
            properties: [
                "count": .integer(description: nil),
                "readings": .array(items: .string(description: nil), description: nil, minItems: 2),
                "title": .string(description: nil)
            ],
            required: ["count", "readings", "title"],
            description: nil
        )
        let wrongSibling = schema.conformanceViolation(for: #"{"count":"x","readings":["a"]}"#)
        expectUnderCount(wrongSibling, path: "root.readings", minimum: 2)
        let missingKeys = schema.conformanceViolation(for: #"{"readings":[]}"#)
        expectUnderCount(missingKeys, path: "root.readings", minimum: 2)
    }

    /// A wrong element earlier in an array does not hide a later element's short inner array.
    @Test func aNestedUnderCountIsPreferredOverAnEarlierElementsShapeFailure() {
        expectUnderCount(
            groups(tags: 1).conformanceViolation(for: #"{"groups":[{"tags":"x"},{"tags":[]}]}"#),
            path: "root.groups[].tags",
            minimum: 1
        )
    }

    private func expectUnderCount(_ violation: KBLLMError?, path: String, minimum: Int) {
        guard case .schemaViolation(let expected, _) = violation else {
            Issue.record("expected a schemaViolation, got \(String(describing: violation))")
            return
        }
        #expect(expected.contains(path))
        #expect(expected.contains("at least \(minimum)"))
    }
}
