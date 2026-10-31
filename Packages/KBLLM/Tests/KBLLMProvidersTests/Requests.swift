import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI

// Shared neutral requests and the expected neutral output, plus adapter factories. One
// request drives BOTH adapters so the equivalence and discriminator tests diff their output
// directly.

/// The single tool both adapters translate: a `get_weather` with a required `city` string.
let weatherTool = ToolDefinition(
    name: "get_weather",
    description: "Look up the weather for a city",
    parameters: .object(
        properties: ["city": .string(description: "The city to look up")],
        required: ["city"],
        description: "weather query"
    )
)

/// The one request fed to both providers in the equivalence test.
let weatherRequest = ModelRequest(
    messages: [Message(role: .user, text: "What is the weather in Paris?")],
    tools: [weatherTool]
)

/// A request whose history carries an assistant tool-call turn and a tool-result turn, for
/// the history-translation checks.
let historyRequest = ModelRequest(
    messages: [
        Message(role: .user, text: "What is the weather in Paris?"),
        Message(role: .assistant, content: [
            .toolCall(ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8)))
        ]),
        Message(role: .tool, content: [
            .toolResult(
                callID: "call_1",
                ToolResult.success(toolName: "get_weather", content: Data(#"{"temp":"sunny"}"#.utf8))
            )
        ]),
        Message(role: .user, text: "Thanks")
    ],
    tools: [weatherTool]
)

/// A request whose assistant tool-call arguments are NOT valid JSON, to drive the
/// request-building `.invalidRequest` throw site.
let malformedToolRequest = ModelRequest(
    messages: [
        Message(role: .assistant, content: [
            .toolCall(ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data("this is not json".utf8)))
        ])
    ],
    tools: [weatherTool]
)

// MARK: Structured output shared fixtures (unit 6)

/// The nested structured schema every structured assertion drives: an object whose required
/// list includes an array of objects that each carry their OWN required list, with a distinct
/// description at every level (object, array, and leaf), so a translator that drops nesting, a
/// `required` list, or a description is caught on the wire.
let structuredSchema: JSONSchema = .object(
    properties: [
        "title": .string(description: "the card title"),
        "readings": .array(
            items: .object(
                properties: ["value": .string(description: "the reading value")],
                required: ["value"],
                description: "one reading"
            ),
            description: "the list of readings"
        )
    ],
    required: ["title", "readings"],
    description: "a vocabulary card"
)

/// The document that conforms to `structuredSchema`, delivered by every happy-path transcript.
let structuredConformingDocument = #"{"title":"Paris","readings":[{"value":"sunny"}]}"#

/// The two halves a split-streaming transcript delivers; their concatenation is the conforming
/// document, so a reassembled stream equals it exactly.
let structuredConformingFirstHalf = #"{"title":"Paris","#
let structuredConformingSecondHalf = #""readings":[{"value":"sunny"}]}"#

/// Parseable JSON that does NOT conform: it is missing the required `readings` array.
let structuredNonconformingDocument = #"{"title":"Paris"}"#

/// Not parseable JSON at all, to prove a malformed structured answer also fails, not falls back.
let structuredMalformedDocument = #"{"title":"#

/// A structured request: the schema is set and there are no caller tools.
let structuredRequest = ModelRequest(
    messages: [Message(role: .user, text: "Make a vocabulary card for Paris.")],
    responseSchema: structuredSchema
)

/// A request carrying BOTH a schema and a caller tool, which every adapter must reject before
/// dispatch (RULING 19).
let structuredPlusToolsRequest = ModelRequest(
    messages: [Message(role: .user, text: "Make a vocabulary card for Paris.")],
    tools: [weatherTool],
    responseSchema: structuredSchema
)

/// The neutral output both providers must produce for the weather exchange: one accumulated
/// text delta, one complete tool call, and a tool-calls completion.
let expectedWeatherEvents: [ModelEvent] = [
    .contentDelta("The weather in Paris is sunny."),
    .toolCall(ToolCallRecord(id: "call_1", name: "get_weather", arguments: Data(#"{"city":"Paris"}"#.utf8))),
    .completed(.toolCalls)
]

/// A request carrying a system message, for the adapters' system-prompt handling.
let systemRequest = ModelRequest(messages: [
    Message(role: .system, text: "You are terse."),
    Message(role: .user, text: "What is the weather in Paris?")
])

func makeAnthropic(
    _ behavior: RecordingTransport.Behavior,
    credentials: FakeCredentialStore = FakeCredentialStore(response: .secret(sentinelSecret)),
    model: String = "claude-3-5-sonnet-20241022",
    key: String = "ANTHROPIC_API_KEY",
    baseURL: String? = nil
) -> (AnthropicModel, RecordingTransport) {
    let transport = RecordingTransport(behavior)
    // Passing no baseURL exercises the adapter's own public-origin default, so the default
    // path is proved by omission rather than by restating the default here.
    let adapter = baseURL.map {
        AnthropicModel(model: model, credentialKey: key, baseURL: $0, transport: transport, credentials: credentials)
    } ?? AnthropicModel(model: model, credentialKey: key, transport: transport, credentials: credentials)
    return (adapter, transport)
}

func makeOpenAI(
    _ behavior: RecordingTransport.Behavior,
    credentials: FakeCredentialStore = FakeCredentialStore(response: .secret(sentinelSecret)),
    model: String = "gpt-4o",
    key: String = "OPENAI_API_KEY",
    baseURL: String? = nil,
    reasoningEffort: OpenAIModel.ReasoningEffort? = nil,
    outputTokenField: OpenAIModel.OutputTokenField = .maxTokens
) -> (OpenAIModel, RecordingTransport) {
    let transport = RecordingTransport(behavior)
    let adapter = OpenAIModel(
        model: model,
        credentialKey: key,
        baseURL: baseURL ?? "https://api.openai.com/v1",
        reasoningEffort: reasoningEffort,
        outputTokenField: outputTokenField,
        transport: transport,
        credentials: credentials
    )
    return (adapter, transport)
}

/// The tool-call records in an event array, in order.
func toolCallRecords(_ events: [ModelEvent]) -> [ToolCallRecord] {
    events.compactMap { event in
        if case .toolCall(let record) = event { return record }
        return nil
    }
}

/// A tool call's arguments decoded as a flat string map, for value comparison independent of
/// byte ordering.
func decodedArguments(_ record: ToolCallRecord) -> [String: String]? {
    try? JSONDecoder().decode([String: String].self, from: record.arguments)
}

/// True when a drained result is the full weather success: no error, a tool call present, and
/// a tool-calls completion. Used to prove a cross-fed transcript does NOT succeed.
func isWeatherSuccess(_ collected: Collected) -> Bool {
    collected.error == nil
        && !toolCallRecords(collected.events).isEmpty
        && collected.events.contains(.completed(.toolCalls))
}
