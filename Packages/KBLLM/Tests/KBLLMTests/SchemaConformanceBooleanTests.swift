import Foundation
import KBLLM
import Testing

/// Booleans and the numbers 1 and 0 are the one JSON discrimination that is easy to get
/// wrong and silent when wrong. `JSONSerialization` hands both back as `NSNumber`, and the
/// portable-looking `value is Bool` answers TRUE for 1 and 0 (though false for 5), so a
/// `.integer` schema built on it would reject the two most common integers there are.
/// These pin the distinction in both directions.
@Suite("JSONSchema conformance: booleans versus numbers")
struct SchemaConformanceBooleanTests {

    private func violation(_ schema: JSONSchema, _ document: String) -> KBLLMError? {
        schema.conformanceViolation(for: document)
    }

    @Test func booleanSchemaAcceptsOnlyTrueAndFalse() {
        let schema = JSONSchema.object(
            properties: ["flag": .boolean(description: nil)], required: ["flag"], description: nil)
        #expect(violation(schema, #"{"flag":true}"#) == nil)
        #expect(violation(schema, #"{"flag":false}"#) == nil)
        #expect(violation(schema, #"{"flag":1}"#) != nil)
        #expect(violation(schema, #"{"flag":0}"#) != nil)
        #expect(violation(schema, #"{"flag":"true"}"#) != nil)
    }

    @Test func integerSchemaAcceptsZeroAndOneAndRejectsBooleans() {
        let schema = JSONSchema.object(
            properties: ["count": .integer(description: nil)], required: ["count"], description: nil)
        // The regression this guards: 0 and 1 must remain numbers.
        #expect(violation(schema, #"{"count":0}"#) == nil)
        #expect(violation(schema, #"{"count":1}"#) == nil)
        #expect(violation(schema, #"{"count":5}"#) == nil)
        #expect(violation(schema, #"{"count":true}"#) != nil)
        #expect(violation(schema, #"{"count":false}"#) != nil)
    }

    @Test func numberSchemaBehavesTheSameWayAsInteger() {
        let schema = JSONSchema.object(
            properties: ["ratio": .number(description: nil)], required: ["ratio"], description: nil)
        #expect(violation(schema, #"{"ratio":0}"#) == nil)
        #expect(violation(schema, #"{"ratio":3.14}"#) == nil)
        #expect(violation(schema, #"{"ratio":true}"#) != nil)
    }

    @Test func nestedArraysAndObjectsKeepTheDistinction() {
        let schema = JSONSchema.object(
            properties: ["flags": .array(items: .boolean(description: nil), description: nil)],
            required: ["flags"],
            description: nil)
        #expect(violation(schema, #"{"flags":[true,false]}"#) == nil)
        #expect(violation(schema, #"{"flags":[1,0]}"#) != nil)
    }

    @Test func topLevelFragmentsStillParse() {
        // The old implementation passed `.fragmentsAllowed`; a bare scalar document must
        // still be validated rather than rejected as unparseable.
        #expect(violation(.string(description: nil), #""hello""#) == nil)
        #expect(violation(.integer(description: nil), "42") == nil)
        #expect(violation(.boolean(description: nil), "true") == nil)
        #expect(violation(.boolean(description: nil), "1") != nil)
        #expect(violation(.string(description: nil), "not json at all") != nil)
    }

    @Test func explicitNullSatisfiesAnUnrequiredProperty() {
        // OpenAI strict mode cannot express absence, so it is sent the nullable form and
        // answers with an explicit null. That must keep validating.
        let schema = JSONSchema.object(
            properties: ["note": .string(description: nil)], required: [], description: nil)
        #expect(violation(schema, #"{"note":null}"#) == nil)
        #expect(violation(schema, #"{}"#) == nil)
        #expect(violation(schema, #"{"note":5}"#) != nil)
    }

    @Test func missingRequiredPropertyStillViolates() {
        let schema = JSONSchema.object(
            properties: ["title": .string(description: nil)], required: ["title"], description: nil)
        #expect(violation(schema, #"{}"#) != nil)
        #expect(violation(schema, #"{"title":"ok"}"#) == nil)
    }
}
