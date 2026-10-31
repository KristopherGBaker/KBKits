import Foundation
import KBLLM
import Testing

// A string's `choices` (JSON Schema `enum`) in the core: refused when unsendable by `validate()`,
// and enforced on the answer by the shared conformance check every adapter runs. Parsing lives
// in `ChoicesParsingTests`.
@Suite struct ChoicesSchemaTests {
    static let labels = ["personalClaim", "general", "instruction"]

    /// A claim with a required label, an optional tone, and a list of tagged spans whose items
    /// carry their own choice, so a choice is exercised at the root's property, in an optional
    /// property, and inside array items.
    static let claimSchema: JSONSchema = .object(
        properties: [
            "label": .string(description: "the claim kind", choices: labels),
            "tone": .string(description: nil, choices: ["calm", "urgent"]),
            "spans": .array(
                items: .object(
                    properties: ["kind": .string(description: nil, choices: ["name", "place"])],
                    required: ["kind"],
                    description: nil
                ),
                description: nil
            )
        ],
        required: ["label", "spans"],
        description: nil
    )

    // MARK: Source compatibility

    @Test func theExistingConstructionStillMeansNoChoices() {
        let plain: JSONSchema = .string(description: "free text")
        #expect(plain == .string(description: "free text", choices: nil))
        #expect(plain.choices == nil)
        #expect(plain.schemaDescription == "free text")
        let constrained: JSONSchema = .string(description: "kind", choices: ["a", "b"])
        #expect(constrained.choices == ["a", "b"])
        #expect(constrained.schemaDescription == "kind")
        #expect(constrained != plain)
        #expect(JSONSchema.integer(description: nil).choices == nil)
    }

    // MARK: validate()

    @Test func validChoicesPass() throws {
        try Self.claimSchema.validate()
        try JSONSchema.string(description: nil, choices: ["only"]).validate()
    }

    @Test(arguments: [
        ([String](), "at least one value"),
        (["a", ""], "empty string"),
        (["a", "b", "a"], "\"a\" appears more than once")
    ])
    func unsendableChoicesAreRefusedAtTheRoot(choices: [String], fragment: String) {
        let error = validationError(.string(description: nil, choices: choices))
        guard case .invalidRequest(let field, let reason) = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(field == "root")
        #expect(reason.contains("choices"))
        #expect(reason.contains(fragment))
    }

    @Test func aRefusalNamesTheNestedNode() {
        let inObject: JSONSchema = .object(
            properties: ["outer": .object(
                properties: ["kind": .string(description: nil, choices: [])],
                required: ["kind"],
                description: nil
            )],
            required: [],
            description: nil
        )
        let inItems: JSONSchema = .object(
            properties: ["tags": .array(items: .string(description: nil, choices: ["x", "x"]), description: nil)],
            required: ["tags"],
            description: nil
        )
        guard case .invalidRequest(let objectField, _) = validationError(inObject),
              case .invalidRequest(let itemsField, _) = validationError(inItems)
        else {
            Issue.record("expected both to be refused")
            return
        }
        #expect(objectField == "root.outer.kind")
        #expect(itemsField == "root.tags[]")
    }

    @Test func caseAndWhitespaceMakeDistinctValues() throws {
        // Not duplicates: a model answering "General" has not answered "general".
        try JSONSchema.string(description: nil, choices: ["general", "General", " general"]).validate()
    }

    private func validationError(_ schema: JSONSchema) -> KBLLMError? {
        do {
            try schema.validate()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Conformance

    @Test func aListedValueConforms() {
        let document = #"{"label":"general","tone":"calm","spans":[{"kind":"name"},{"kind":"place"}]}"#
        #expect(Self.claimSchema.conformanceViolation(for: document) == nil)
    }

    @Test func anOptionalChoiceMayBeAbsentOrNull() {
        #expect(Self.claimSchema.conformanceViolation(for: #"{"label":"general","spans":[]}"#) == nil)
        #expect(Self.claimSchema.conformanceViolation(for: #"{"label":"general","tone":null,"spans":[]}"#) == nil)
    }

    @Test func anUnlistedRootPropertyIsAViolationNamingTheChoices() {
        let document = #"{"label":"opinion","spans":[]}"#
        let (expected, received) = violation(Self.claimSchema, document)
        #expect(expected.contains("root.label"))
        #expect(expected.contains(#"["personalClaim", "general", "instruction"]"#))
        #expect(expected.contains(#""opinion""#))
        #expect(received == document)
    }

    @Test func anUnlistedValueInsideArrayItemsIsAViolation() {
        let document = #"{"label":"general","spans":[{"kind":"name"},{"kind":"date"}]}"#
        let (expected, _) = violation(Self.claimSchema, document)
        #expect(expected.contains("root.spans[].kind"))
        #expect(expected.contains(#"["name", "place"]"#))
        #expect(expected.contains(#""date""#))
    }

    @Test func anUnlistedOptionalValueIsAViolation() {
        let (expected, _) = violation(Self.claimSchema, #"{"label":"general","tone":"angry","spans":[]}"#)
        #expect(expected.contains("root.tone"))
    }

    @Test func aRootStringWithChoicesIsChecked() {
        let schema = JSONSchema.string(description: nil, choices: Self.labels)
        #expect(schema.conformanceViolation(for: #""instruction""#) == nil)
        let (expected, _) = violation(schema, #""Instruction""#)
        #expect(expected.contains("at root"))
    }

    @Test func matchingIsExact() {
        for near in [#""General""#, #"" general""#, #""general ""#, #""""#] {
            let schema = JSONSchema.string(description: nil, choices: Self.labels)
            #expect(schema.conformanceViolation(for: near) != nil, "\(near) must not match")
        }
    }

    @Test func aNonStringIsStillAShapeFailure() {
        let schema = JSONSchema.string(description: nil, choices: ["1"])
        let (expected, _) = violation(schema, "1")
        #expect(expected == "a JSON string")
    }

    @Test func anUnlistedChoiceIsNamedInPreferenceToAMissingKey() {
        // Wrong twice: `spans` is missing and the label is unlisted. The specific statement wins.
        let (expected, _) = violation(Self.claimSchema, #"{"label":"opinion"}"#)
        #expect(expected.contains("root.label"))
    }

    @Test func noChoicesMeansAnyString() {
        let schema = JSONSchema.string(description: nil)
        #expect(schema.conformanceViolation(for: #""anything at all""#) == nil)
    }

    private func violation(_ schema: JSONSchema, _ document: String) -> (expected: String, received: String) {
        guard case .schemaViolation(let expected, let received) = schema.conformanceViolation(for: document) else {
            Issue.record("expected a .schemaViolation for \(document)")
            return ("", "")
        }
        return (expected, received)
    }
}
