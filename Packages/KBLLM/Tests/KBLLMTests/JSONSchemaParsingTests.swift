import Foundation
import KBLLM
import Testing

@Suite("JSONSchema.parse")
struct JSONSchemaParsingTests {
    @Test func parsesAnObjectWithNestedPropertiesAndRequired() throws {
        let schema = try JSONSchema.parse(#"""
        {
          "type": "object",
          "description": "a card",
          "properties": {
            "lemma": { "type": "string", "description": "the word" },
            "count": { "type": "integer" },
            "detail": {
              "type": "object",
              "properties": { "reading": { "type": "string" } },
              "required": ["reading"]
            }
          },
          "required": ["lemma"]
        }
        """#)

        guard case let .object(properties, required, description) = schema else {
            Issue.record("expected an object")
            return
        }
        #expect(description == "a card")
        #expect(required == ["lemma"])
        #expect(properties.keys.sorted() == ["count", "detail", "lemma"])
        #expect(properties["lemma"] == .string(description: "the word"))
        #expect(properties["count"] == .integer(description: nil))
        #expect(properties["detail"] == .object(
            properties: ["reading": .string(description: nil)],
            required: ["reading"],
            description: nil
        ))
    }

    @Test func parsesAnArrayOfObjects() throws {
        let schema = try JSONSchema.parse(#"""
        { "type": "array", "items": { "type": "object", "properties": {}, "required": [] } }
        """#)
        #expect(schema == .array(items: .object(properties: [:], required: [], description: nil), description: nil))
    }

    /// The point of refusing rather than dropping: a schema that says "one of these three
    /// values" and arrives as a plain string has been WEAKENED, and the caller would learn
    /// that from a malformed answer rather than from an error.
    @Test func refusesAConstraintItCannotCarry() {
        for (fragment, keyword) in [
            // `enum` is carried on a string node (as `choices`), but on no other type.
            (#"{ "type": "integer", "enum": [1, 2] }"#, "enum"),
            (#"{ "type": "string", "pattern": "^a" }"#, "pattern"),
            (#"{ "anyOf": [{ "type": "string" }] }"#, "anyOf"),
            (##"{ "type": "object", "properties": {}, "required": [], "$ref": "#/x" }"##, "$ref")
        ] {
            do {
                _ = try JSONSchema.parse(fragment)
                Issue.record("expected '\(keyword)' to be refused")
            } catch {
                guard case let .invalidRequest(_, reason) = error else {
                    Issue.record("expected invalidRequest for '\(keyword)'")
                    continue
                }
                #expect(reason.contains(keyword))
            }
        }
    }

    @Test func namesThePathOfTheOffendingNode() {
        do {
            _ = try JSONSchema.parse(#"""
            {
              "type": "object",
              "properties": {
                "outer": {
                  "type": "object",
                  "properties": { "bad": { "type": "string", "enum": [] } }
                }
              },
              "required": []
            }
            """#)
            Issue.record("expected a refusal")
        } catch {
            guard case let .invalidRequest(field, _) = error else {
                Issue.record("expected invalidRequest")
                return
            }
            // The path is what makes a deep schema's failure actionable.
            #expect(field == "root.outer.bad")
        }
    }

    @Test func refusesAdditionalPropertiesTrue() {
        #expect(throws: KBLLMError.self) {
            try JSONSchema.parse(
                #"{ "type": "object", "properties": {}, "required": [], "additionalProperties": true }"#
            )
        }
    }

    @Test func acceptsAdditionalPropertiesFalseBecauseThatIsWhatIsSentAnyway() throws {
        let schema = try JSONSchema.parse(
            #"{ "type": "object", "properties": {}, "required": [], "additionalProperties": false }"#
        )
        #expect(schema == .object(properties: [:], required: [], description: nil))
    }

    @Test func refusesRequiredNamingAPropertyThatDoesNotExist() {
        #expect(throws: KBLLMError.self) {
            try JSONSchema.parse(#"{ "type": "object", "properties": {}, "required": ["ghost"] }"#)
        }
    }

    @Test func refusesMalformedJSONAndAMissingType() {
        #expect(throws: KBLLMError.self) { try JSONSchema.parse("{not json") }
        #expect(throws: KBLLMError.self) { try JSONSchema.parse(#"{ "properties": {} }"#) }
    }

    /// A round trip through the parser is what a caller who authored JSON actually gets, so
    /// the request it produces must be the same one a Swift-authored schema produces.
    @Test func aParsedSchemaIsEqualToTheHandWrittenOne() throws {
        let parsed = try JSONSchema.parse(#"""
        { "type": "object",
          "properties": { "a": { "type": "string" }, "b": { "type": "boolean" } },
          "required": ["a", "b"] }
        """#)
        #expect(parsed == .object(
            properties: ["a": .string(description: nil), "b": .boolean(description: nil)],
            required: ["a", "b"],
            description: nil
        ))
    }

    /// The convention a schema written FOR OpenAI uses: every property in `required`, with the
    /// optional ones typed as a union with null. It has to parse unchanged, because rewriting
    /// a shipped schema into a different convention is not a migration a library should force.
    @Test func aNullUnionParsesAsAnOptionalProperty() throws {
        let schema = try JSONSchema.parse(#"""
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["competency", "score", "note"],
          "properties": {
            "competency": { "type": "string" },
            "score": { "type": "integer" },
            "note": { "type": ["string", "null"] }
          }
        }
        """#)

        guard case let .object(properties, required, _) = schema else {
            Issue.record("expected an object")
            return
        }
        // The union is stripped: the property is a plain string that happens to be optional.
        #expect(properties["note"] == .string(description: nil))
        // And it leaves `required`, because optionality is stated by omission here.
        #expect(required == ["competency", "score"])
    }

    @Test func aNullableObjectParsesAsAnOptionalNestedObject() throws {
        let schema = try JSONSchema.parse(#"""
        {
          "type": "object",
          "required": ["ref"],
          "properties": {
            "ref": {
              "type": ["object", "null"],
              "required": ["start"],
              "properties": { "start": { "type": "integer" } }
            }
          }
        }
        """#)

        guard case let .object(properties, required, _) = schema else {
            Issue.record("expected an object")
            return
        }
        #expect(required.isEmpty)
        #expect(properties["ref"] == .object(
            properties: ["start": .integer(description: nil)],
            required: ["start"],
            description: nil
        ))
    }

    @Test func aUnionThatIsNotAnOptionalMarkerIsRefused() {
        #expect(throws: KBLLMError.self) {
            try JSONSchema.parse(#"{ "type": ["string", "integer"] }"#)
        }
    }
}
