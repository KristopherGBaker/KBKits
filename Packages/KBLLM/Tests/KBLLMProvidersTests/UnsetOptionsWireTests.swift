import Foundation
import KBLLM
import KBLLMOpenAI
import Testing
@testable import KBLLMAnthropic

// Request bodies pinned in full, written with ONLY the API that existed before string choices
// and greedy sampling, so neither feature can change a body that does not ask for it. The pins
// are canonical (sorted keys): two serializations of an equal dictionary need not order their
// keys alike, so raw bytes are not a stable fixture.
@Suite struct UnsetOptionsWireTests {
    private static let options = GenerationOptions(temperature: 0.5, maxOutputTokens: 700, topP: 0.25)

    private static let schema: JSONSchema = .object(
        properties: [
            "label": .string(description: "the claim kind"),
            "tone": .string(description: nil),
            "tags": .array(items: .string(description: nil), description: nil)
        ],
        required: ["label", "tags"],
        description: nil
    )

    private static let tool = ToolDefinition(
        name: "classify",
        description: "Record the claim kind",
        parameters: .object(properties: ["label": .string(description: "kind")], required: ["label"], description: nil)
    )

    private static let hi = [Message(role: .user, text: "hi")]

    private func body(_ transport: RecordingTransport) -> String {
        canonicalJSON(requestBodies(transport).first)
    }

    private func anthropic(_ model: String, _ request: ModelRequest, reply: [UInt8]) async -> String {
        let (adapter, transport) = makeAnthropic(.replay(reply), model: model)
        _ = await collect(adapter, request)
        return body(transport)
    }

    private func openAI(_ request: ModelRequest, reply: [UInt8]) async -> String {
        let (adapter, transport) = makeOpenAI(.replay(reply))
        _ = await collect(adapter, request)
        return body(transport)
    }

    private static let anthropicMessages = #""messages":[{"content":[{"text":"hi","type":"text"}],"role":"user"}]"#

    @Test func anthropicSamplingBodies() async {
        let request = ModelRequest(messages: Self.hi, options: Self.options)
        let reply = Fixtures.anthropicWithUsage
        #expect(await anthropic("claude-opus-4-1", request, reply: reply) == "{\"max_tokens\":700,"
            + Self.anthropicMessages + #","model":"claude-opus-4-1","stream":true,"temperature":0.5,"top_p":0.25}"#)
        #expect(await anthropic("claude-sonnet-4-5", request, reply: reply) == "{\"max_tokens\":700,"
            + Self.anthropicMessages + #","model":"claude-sonnet-4-5","stream":true,"temperature":0.5}"#)
        #expect(await anthropic("claude-sonnet-5-5", request, reply: reply) == "{\"max_tokens\":700,"
            + Self.anthropicMessages + #","model":"claude-sonnet-5-5","stream":true}"#)
    }

    @Test func openAISamplingBody() async {
        let request = ModelRequest(messages: Self.hi, options: Self.options)
        #expect(await openAI(request, reply: Fixtures.openAIWeather) == #"{"max_tokens":700,"#
            + #""messages":[{"content":"hi","role":"user"}],"model":"gpt-4o","stream":true,"#
            + #""stream_options":{"include_usage":true},"temperature":0.5,"top_p":0.25}"#)
    }

    @Test func anthropicStructuredBodies() async {
        let request = ModelRequest(messages: Self.hi, responseSchema: Self.schema)
        let document = #"{"label":"a","tags":[]}"#
        let legacy = await anthropic(
            "claude-3-5-sonnet-20241022",
            request,
            reply: Fixtures.anthropicStructured(toolName: AnthropicModel.structuredToolName, fragments: [document])
        )
        #expect(legacy.contains(#""input_schema":{"additionalProperties":false,"properties":{"#
            + #""label":{"description":"the claim kind","type":"string"},"#
            + #""tags":{"items":{"type":"string"},"type":"array"},"#
            + #""tone":{"type":"string"}},"required":["label","tags"],"type":"object"}"#))
        let current = await anthropic(
            "claude-sonnet-5-5",
            request,
            reply: Fixtures.structuredOutputAnswer(model: "claude-sonnet-5-5", document: document)
        )
        #expect(current == #"{"max_tokens":4096,"# + Self.anthropicMessages + #","model":"claude-sonnet-5-5","#
            + #""output_config":{"format":{"schema":{"additionalProperties":false,"properties":{"#
            + #""label":{"description":"the claim kind","type":"string"},"#
            + #""tags":{"items":{"type":"string"},"type":"array"},"#
            + #""tone":{"type":"string"}},"required":["label","tags"],"type":"object"},"#
            + #""type":"json_schema"}},"stream":true}"#)
    }

    @Test func openAIStructuredBody() async {
        let request = ModelRequest(messages: Self.hi, responseSchema: Self.schema)
        let reply = Fixtures.openAIStructured(contentChunks: [#"{"label":"a","tags":[],"tone":null}"#])
        #expect(await openAI(request, reply: reply) == #"{"messages":[{"content":"hi","role":"user"}],"#
            + #""model":"gpt-4o","response_format":{"json_schema":{"name":"structured_response","#
            + #""schema":{"additionalProperties":false,"properties":{"#
            + #""label":{"description":"the claim kind","type":"string"},"#
            + #""tags":{"items":{"type":"string"},"type":"array"},"#
            + #""tone":{"type":["string","null"]}},"required":["label","tags","tone"],"type":"object"},"#
            + #""strict":true},"type":"json_schema"},"stream":true,"stream_options":{"include_usage":true}}"#)
    }

    @Test func toolBodies() async {
        let request = ModelRequest(messages: Self.hi, tools: [Self.tool])
        let anthropicBody = await anthropic("claude-sonnet-5-5", request, reply: Fixtures.anthropicWeather)
        #expect(anthropicBody.contains(#""tools":[{"description":"Record the claim kind","#
            + #""input_schema":{"properties":{"label":{"description":"kind","type":"string"}},"#
            + #""required":["label"],"type":"object"},"name":"classify"}]"#))
        let openAIBody = await openAI(request, reply: Fixtures.openAIWeather)
        #expect(openAIBody.contains(#""tools":[{"function":{"description":"Record the claim kind","#
            + #""name":"classify","parameters":{"additionalProperties":false,"#
            + #""properties":{"label":{"description":"kind","type":"string"}},"#
            + #""required":["label"],"type":"object"}},"type":"function"}]"#))
    }
}
