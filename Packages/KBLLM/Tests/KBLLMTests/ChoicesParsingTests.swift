import Foundation
import KBLLM
import Testing

// `enum` through `JSONSchema.parse(_:)`: read into a string node's `choices`, and refused on any
// other node, with a non-string member, or when the list could not be sent.
@Suite struct ChoicesParsingTests {
    @Test func aStringEnumBecomesChoices() throws {
        let schema = try JSONSchema.parse(#"{"type":"string","description":"kind","enum":["a","b"]}"#)
        #expect(schema == .string(description: "kind", choices: ["a", "b"]))
    }

    @Test func choicesKeepTheirOrder() throws {
        let schema = try JSONSchema.parse(#"{"type":"string","enum":["zeta","alpha","mu"]}"#)
        #expect(schema.choices == ["zeta", "alpha", "mu"])
    }

    @Test func nestedChoicesParse() throws {
        let schema = try JSONSchema.parse(#"""
        { "type": "object", "required": ["label", "spans"],
          "properties": {
            "label": { "type": "string", "enum": ["personalClaim", "general", "instruction"] },
            "spans": { "type": "array", "items": { "type": "object", "required": ["kind"],
              "properties": { "kind": { "type": "string", "enum": ["name", "place"] } } } }
          } }
        """#)
        #expect(schema.properties?["label"]?.choices == ["personalClaim", "general", "instruction"])
        guard case .array(let items, _, _)? = schema.properties?["spans"] else {
            Issue.record("expected spans to be an array")
            return
        }
        #expect(items.properties?["kind"]?.choices == ["name", "place"])
    }

    /// A choices list holds only strings, so `null` is refused whatever the type says: on a plain
    /// string, on the nullable union, at the root and inside an object, and when it is the only
    /// member. Never dropped, which would quietly turn the list into something else.
    @Test(arguments: [
        (#"{"type":"string","enum":["a",null]}"#, "root"),
        (#"{"type":["string","null"],"enum":["a",null]}"#, "root"),
        (#"{"type":["string","null"],"enum":[null]}"#, "root"),
        (#"{"type":"object","required":["tone"],"properties":{"tone":{"type":["string","null"],"#
            + #""enum":["calm","urgent",null]}}}"#, "root.tone"),
        (#"{"type":"object","required":[],"properties":{"tone":{"type":"string","enum":[null,"calm"]}}}"#,
         "root.tone")
    ])
    func aNullMemberIsRefused(json: String, field: String) {
        let refusal = parseRefusal(json)
        #expect(refusal?.field == field)
        #expect(refusal?.reason.contains("must list only strings; got null") == true)
        #expect(refusal?.reason.contains("leaving the property out of 'required'") == true)
    }

    /// A nullable string with no `enum` is the optional marker, exactly as before choices existed.
    @Test func aNullableStringWithoutEnumStillParses() throws {
        let schema = try JSONSchema.parse(#"""
        { "type": "object", "required": ["label", "tone"],
          "properties": { "label": { "type": "string" }, "tone": { "type": ["string", "null"] } } }
        """#)
        #expect(schema == .object(
            properties: ["label": .string(description: nil), "tone": .string(description: nil)],
            required: ["label"],
            description: nil
        ))
    }

    /// A string-only list parses, on a plain string and on the nullable union (the optional
    /// marker, which leaves the property out of `required`).
    @Test func aStringOnlyEnumStillParses() throws {
        let schema = try JSONSchema.parse(#"""
        { "type": "object", "required": ["label", "tone"],
          "properties": { "label": { "type": "string", "enum": ["general", "instruction"] },
                          "tone": { "type": ["string", "null"], "enum": ["calm", "urgent"] } } }
        """#)
        #expect(schema == .object(
            properties: [
                "label": .string(description: nil, choices: ["general", "instruction"]),
                "tone": .string(description: nil, choices: ["calm", "urgent"])
            ],
            required: ["label"],
            description: nil
        ))
    }

    @Test(arguments: ["integer", "number", "boolean"])
    func enumOnAScalarOfAnotherTypeIsRefused(type: String) {
        let refusal = parseRefusal(#"{"type":"\#(type)","enum":[1]}"#)
        #expect(refusal?.field == "root")
        #expect(refusal?.reason.contains("enum applies only to a string schema") == true)
    }

    @Test func enumOnAnArrayOrObjectIsRefused() {
        let onArray = parseRefusal(#"{"type":"array","items":{"type":"string"},"enum":[["a"]]}"#)
        #expect(onArray?.reason.contains("enum applies only to a string schema") == true)
        let onObject = parseRefusal(#"{"type":"object","properties":{},"required":[],"enum":[{}]}"#)
        #expect(onObject?.reason.contains("enum applies only to a string schema") == true)
    }

    @Test(arguments: [
        (#"{"type":"string","enum":["a",1]}"#, "1"),
        (#"{"type":"string","enum":["a",true]}"#, "true"),
        (#"{"type":"string","enum":["a",{"b":1}]}"#, "an object"),
        (#"{"type":"string","enum":["a",["b"]]}"#, "an array")
    ])
    func aNonStringMemberIsRefused(json: String, shown: String) {
        let refusal = parseRefusal(json)
        #expect(refusal?.reason.contains("must list only strings") == true)
        #expect(refusal?.reason.contains("got \(shown)") == true, "\(String(describing: refusal?.reason))")
    }

    @Test func anEnumThatIsNotAListIsRefused() {
        #expect(parseRefusal(#"{"type":"string","enum":"a"}"#)?.reason.contains("enum must be an array") == true)
    }

    @Test(arguments: [
        (#"{"type":"string","enum":[]}"#, "at least one value"),
        (#"{"type":"string","enum":["a",""]}"#, "empty string"),
        (#"{"type":"string","enum":["a","a"]}"#, "more than once")
    ])
    func anUnsendableListIsRefusedLikeValidate(json: String, fragment: String) {
        #expect(parseRefusal(json)?.reason.contains(fragment) == true)
    }

    @Test func otherKeywordsBesideEnumAreStillRefused() {
        let refusal = parseRefusal(#"{"type":"string","enum":["a"],"const":"a"}"#)
        #expect(refusal?.reason.contains("const") == true)
    }

    private func parseRefusal(_ json: String) -> (field: String, reason: String)? {
        do {
            _ = try JSONSchema.parse(json)
            Issue.record("expected \(json) to be refused")
            return nil
        } catch {
            guard case .invalidRequest(let field, let reason) = error else {
                Issue.record("expected .invalidRequest, got \(error)")
                return nil
            }
            return (field, reason)
        }
    }
}
