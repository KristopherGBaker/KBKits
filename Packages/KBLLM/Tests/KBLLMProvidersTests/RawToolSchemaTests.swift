import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import Testing

/// A tool's `rawParameters`, a JSON Schema `JSONSchema` cannot say (here `oneOf` and `$ref`), goes out exactly as
/// written in Anthropic's `input_schema` and OpenAI's (Chat Completions and Responses) `parameters`; one that is not an
/// object schema is refused before any transport opens. Offline.
@Suite struct RawToolSchemaTests {
    static let raw = ##"{"$defs":{"unit":{"enum":["c","f"]}},"properties":{"##
        + ##""place":{"oneOf":[{"type":"string"},{"type":"integer"}]},"##
        + ##""unit":{"$ref":"#/$defs/unit"}},"required":["place"],"type":"object"}"##

    static let tool = ToolDefinition(
        name: "lookup", description: "Look something up",
        parameters: .object(properties: [:], required: [], description: nil), rawParameters: Data(raw.utf8)
    )

    static func request(_ tool: ToolDefinition) -> ModelRequest {
        ModelRequest(messages: [Message(role: .user, text: "Look up Paris")], tools: [tool])
    }

    private static func sentTool(_ transport: RecordingTransport) throws -> [String: Any] {
        let body = try #require(transport.requests.get().first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require((json["tools"] as? [[String: Any]])?.first)
    }

    private static func canonical(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static let expected: String = {
        let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [:]
        return (try? canonical(object)) ?? ""
    }()

    @Test func anthropicSendsTheRawSchemaAsInputSchema() async throws {
        let (model, transport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        _ = await collect(model, Self.request(Self.tool))
        let sent = try Self.sentTool(transport)
        #expect(try Self.canonical(try #require(sent["input_schema"])) == Self.expected)
    }

    @Test func chatCompletionsSendsTheRawSchemaAsParameters() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(model, Self.request(Self.tool))
        let function = try #require(try Self.sentTool(transport)["function"] as? [String: Any])
        #expect(try Self.canonical(try #require(function["parameters"])) == Self.expected)
    }

    @Test func responsesSendsTheRawSchemaAsParameters() async throws {
        let (model, transport) = makeResponses(.replay(Fixtures.responsesText))
        _ = await collect(model, Self.request(Self.tool))
        #expect(try Self.canonical(try #require(try Self.sentTool(transport)["parameters"])) == Self.expected)
    }

    @Test func withoutARawSchemaTheParametersAreSentAsBefore() async throws {
        let (model, transport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        _ = await collect(model, weatherRequest)
        let function = try #require(try Self.sentTool(transport)["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["city"])
    }

    @Test(arguments: [#"[1,2]"#, #"{"type":"string"}"#, "not json"])
    func aRawSchemaThatIsNotAnObjectSchemaIsRefusedBeforeDispatch(raw: String) async {
        let bad = ToolDefinition(
            name: "lookup", description: "d", parameters: .object(properties: [:], required: [], description: nil),
            rawParameters: Data(raw.utf8)
        )
        let (anthropic, anthropicTransport) = makeAnthropic(.replay(Fixtures.anthropicWeather))
        let (openAI, openAITransport) = makeOpenAI(.replay(Fixtures.openAIWeather))
        let (responses, responsesTransport) = makeResponses(.replay(Fixtures.responsesText))
        for error in [
            await collect(anthropic, Self.request(bad)).error,
            await collect(openAI, Self.request(bad)).error,
            await collect(responses, Self.request(bad)).error
        ] {
            guard case .invalidRequest(let field, _) = error else {
                Issue.record("expected .invalidRequest, got \(String(describing: error))")
                continue
            }
            #expect(field == "tools.lookup.rawParameters")
        }
        let opened = anthropicTransport.openCount.get() + openAITransport.openCount.get()
            + responsesTransport.openCount.get()
        #expect(opened == 0)
    }
}
