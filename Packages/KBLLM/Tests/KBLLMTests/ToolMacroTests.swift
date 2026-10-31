import Foundation
import KBLLM
import Testing

@Suite struct ToolMacroTests {
    @Test func toolGeneratesSchemaDefinitionAndInvokerForTwoDistinctTools() async throws {
        // Tool one: an add-style integer tool.
        let additionTool = addTool()
        #expect(additionTool.definition.name == "add")
        #expect(additionTool.definition.parameters.properties?["a"]?.jsonType == "integer")
        #expect(additionTool.definition.parameters.properties?["b"]?.jsonType == "integer")
        let addResult = await additionTool.invoke(json(["a": 2, "b": 3]))
        #expect(addResult.isError == false)
        #expect(addResult.text == "5")

        // Tool two: a differently-typed string tool. A macro that hardcoded one schema
        // could not produce both of these.
        let greetingTool = greetTool()
        #expect(greetingTool.definition.name == "greet")
        #expect(greetingTool.definition.parameters.properties?["subject"]?.jsonType == "string")
        let greetResult = await greetingTool.invoke(json(["subject": "Ada"]))
        #expect(greetResult.isError == false)
        #expect(greetResult.text == "\"Hello, Ada!\"")
    }

    @Test func malformedArgumentsBecomeAnErrorResultWithoutThrowing() async {
        // Missing the required "b", and "a" is the wrong JSON type.
        let result = await addTool().invoke(Data(#"{"a":"not-a-number"}"#.utf8))
        #expect(result.isError == true)
        #expect((result.text?.isEmpty == false))
    }

    @Test(.enabled(if: SourceReader.sourcesAvailable))
    func parameterDescriptionsComeFromDocCommentVerbatim() {
        // Read the description back from its own declaration and compare, so nothing is
        // hardcoded here (which would defeat the single-source guarantee).
        let fixtures = SourceReader.testsRoot
            .appendingPathComponent("KBLLMTests")
            .appendingPathComponent("Fixtures.swift")
        let expectedA = SourceReader.parameterDescription(named: "a", in: fixtures)
        let expectedB = SourceReader.parameterDescription(named: "b", in: fixtures)
        #expect(expectedA?.isEmpty == false)
        #expect(expectedB?.isEmpty == false)

        let schema = addTool().definition.parameters
        #expect(schema.properties?["a"]?.schemaDescription == expectedA)
        #expect(schema.properties?["b"]?.schemaDescription == expectedB)
    }

    @Test func schemaMacroDescribesStoredPropertiesWithCorrectTypes() {
        let schema = Person.schema
        #expect(schema.jsonType == "object")
        #expect(schema.properties?["displayName"]?.jsonType == "string")
        #expect(schema.properties?["age"]?.jsonType == "integer")
    }

    @Test func toolGroupCollectsToolsReflectingInjectedDependency() async throws {
        let tools = MathTools(base: 10)
        let box = tools.toolBox
        #expect(box.tools.isEmpty == false)
        let tool = try #require(box.tool(named: "addBase"))
        let result = await tool.invoke(json(["value": 5]))
        // 10 (injected base) + 5 (argument) = 15; a degenerate empty box could not do this.
        #expect(result.isError == false)
        #expect(result.text == "15")
    }
}

/// Encode a small JSON object of string-keyed integers or strings as arguments.
private func json(_ object: [String: Int]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func json(_ object: [String: String]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

@Suite struct ReferenceTypeToolGroupTests {
    /// A class-based group must compile AND its tool must mutate the instance the group
    /// holds, which is what makes app control possible: the tools an app exposes are
    /// methods on the object that owns its state.
    @MainActor
    @Test func classToolGroupMutatesTheInstanceItCaptured() async throws {
        let controller = MutableCounterTools()
        let box = controller.toolBox
        let tool = try #require(box.tool(named: "addToTotal"))

        _ = await tool.invoke(Data(#"{"amount":7}"#.utf8))
        let second = await tool.invoke(Data(#"{"amount":5}"#.utf8))

        // The second call sees the first call's mutation, proving the tool is bound to the
        // captured instance rather than to a fresh copy.
        #expect(second.text == "12")
        #expect(controller.total == 12)
    }

    // MARK: Isolation and optionality

    /// A non-async method on an ACTOR. Before isolation detection this did not compile at all,
    /// so the value here is as much that the fixture exists as what it returns.
    @Test func aNonAsyncActorMethodIsCallableAsATool() async throws {
        let tools = IsolatedCounterTools()
        let tool = await tools.addIsolatedTool()

        let first = await tool.invoke(Data(#"{"amount":5}"#.utf8))
        let second = await tool.invoke(Data(#"{"amount":3}"#.utf8))

        #expect(first.text == "5")
        // The state is the actor's, so the second call sees the first one's effect.
        #expect(second.text == "8")
    }

    /// The same for a `@MainActor` type, which is the shape an app actually has.
    @MainActor
    @Test func aNonAsyncMainActorMethodIsCallableAsATool() async throws {
        let tool = MainActorTools().doubleValueTool()
        #expect(await tool.invoke(Data(#"{"value":21}"#.utf8)).text == "42")
    }

    @Test(.enabled(if: SourceReader.sourcesAvailable))
    func anOptionalParameterIsDescribedByItsWrappedTypeAndIsNotRequired() throws {
        let definition = summarizeTagsTool().definition
        guard case let .object(properties, required, _) = definition.parameters else {
            Issue.record("expected an object schema")
            return
        }

        // `Int?` is an INTEGER that may be absent, not a string that must be present. Both
        // halves were wrong before: the wrapper fell through to the string fallback, and every
        // parameter was listed as required.
        //
        // The expected description is READ from the fixture rather than repeated here, because
        // repeating it would be the second copy the single-source rule exists to prevent.
        let fixtures = SourceReader.testsRoot
            .appendingPathComponent("KBLLMTests")
            .appendingPathComponent("Fixtures.swift")
        let expected = SourceReader.parameterDescriptions(in: fixtures)
            .first { $0.contains("cap on how many") }
        #expect(properties["limit"] == .integer(description: try #require(expected)))
        #expect(required == ["tags"])
    }

    @Test func anOptionalParameterCanBeOmittedByTheCaller() async throws {
        let tool = summarizeTagsTool()
        #expect(await tool.invoke(Data(#"{"tags":["a","b","c"],"limit":2}"#.utf8)).text == #"["a","b"]"#)
        #expect(await tool.invoke(Data(#"{"tags":["a","b"]}"#.utf8)).text == #"["a","b"]"#)
    }
}
