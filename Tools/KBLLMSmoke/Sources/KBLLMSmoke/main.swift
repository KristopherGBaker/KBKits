import Foundation
import KBLLM
import KBLLMAnthropic
import KBLLMOpenAI
import KBLLMURLSession

// A dev-only LIVE check, not a test: it talks to a REAL server, so it is inherently
// non-deterministic and lives in Tools/, never in the KBLLM test suite. It drives the shipped
// transport and adapter end to end so a mismatch here is a mismatch a user would hit.
//
//   OPENAI_API_KEY=sk-... swift run --package-path Tools/KBLLMSmoke \
//       KBLLMSmoke <baseURL> <model> [openai|anthropic]
//
// against LM Studio, which serves BOTH wire formats off the same base URL, so the same
// server exercises either adapter:
//
//   OPENAI_API_KEY=lm-studio    ... KBLLMSmoke http://localhost:1234/v1 <model> openai
//   ANTHROPIC_API_KEY=lm-studio ... KBLLMSmoke http://localhost:1234/v1 <model> anthropic

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: KBLLMSmoke <baseURL> <model> [openai|anthropic]\n".utf8)
    )
    exit(2)
}

let baseURL = arguments[1]
let modelName = arguments[2]
let provider = arguments.count > 3 ? arguments[3].lowercased() : "openai"
guard provider == "openai" || provider == "anthropic" else {
    FileHandle.standardError.write(Data("unknown provider '\(provider)'\n".utf8))
    exit(2)
}

// Both adapters satisfy the same one-method seam, so everything below this point is
// provider-agnostic: the harness never learns which wire format it is driving.
let adapter: any LanguageModel = provider == "anthropic"
    ? AnthropicModel(
        model: modelName,
        credentialKey: "ANTHROPIC_API_KEY",
        baseURL: baseURL,
        transport: KBLLMURLSession(),
        credentials: EnvironmentCredentialStore()
    )
    : OpenAIModel(
        model: modelName,
        credentialKey: "OPENAI_API_KEY",
        baseURL: baseURL,
        transport: KBLLMURLSession(),
        credentials: EnvironmentCredentialStore()
    )

let weatherTool = ToolDefinition(
    name: "get_weather",
    description: "Look up the current weather for a city",
    parameters: .object(
        properties: ["city": .string(description: "The city to look up")],
        required: ["city"],
        description: "weather query"
    )
)

/// Run one streaming completion and print each neutral event as it arrives, so a reasoning
/// model's `.reasoningDelta` progress is visible rather than a long silence. Returns whether
/// the stream completed without throwing.
func runStreamingCompletion() async -> Bool {
    print("== streaming completion ==")
    let request = ModelRequest(messages: [Message(role: .user, text: "In one sentence, say hello from KBLLM.")])
    do {
        for try await event in adapter.stream(request) {
            switch event {
            case .reasoningDelta(let text): print("  reasoning: \(text)")
            case .contentDelta(let text): print("  content: \(text)")
            case .toolCall(let call): print("  toolCall: \(call.name)")
            case .usage(let usage): print("  usage: \(usage.inputTokens) in, \(usage.outputTokens) out")
            case .webSearchCall(let call): print("  webSearch: \(call.query)")
            case .webSearchResult(let result): print("  webSearchResult: \(result.searchID)")
            case .citation(let citation): print("  citation: \(citation.url)")
            case .completed(let reason): print("  completed: \(reason.rawValue)")
            }
        }
        print("streaming completion: OK")
        return true
    } catch {
        print("streaming completion FAILED: \(KBLLMError.from(error))")
        return false
    }
}

/// Run one tool round trip: ask a question that should trigger `get_weather`, feed a fabricated
/// tool result back into history, then stream the follow-up answer. Returns whether both legs
/// completed without throwing and a tool call was observed.
func runToolRoundTrip() async -> Bool {
    print("== tool round trip ==")
    let firstRequest = ModelRequest(
        messages: [Message(role: .user, text: "What is the weather in Paris? Use the tool.")],
        tools: [weatherTool]
    )
    var toolCall: ToolCallRecord?
    do {
        for try await event in adapter.stream(firstRequest) {
            if case .toolCall(let call) = event {
                toolCall = call
                print("  requested tool: \(call.name)")
            }
        }
    } catch {
        print("tool round trip FAILED (first leg): \(KBLLMError.from(error))")
        return false
    }

    guard let toolCall else {
        print("tool round trip: the model did not request a tool (server/model dependent)")
        return false
    }

    let followUp = ModelRequest(
        messages: [
            Message(role: .user, text: "What is the weather in Paris? Use the tool."),
            Message(role: .assistant, content: [.toolCall(toolCall)]),
            Message(role: .tool, content: [
                .toolResult(
                    callID: toolCall.id,
                    ToolResult.success(toolName: toolCall.name, content: Data(#"{"temp":"sunny"}"#.utf8))
                )
            ])
        ],
        tools: [weatherTool]
    )
    do {
        for try await event in adapter.stream(followUp) {
            if case .contentDelta(let text) = event { print("  answer: \(text)") }
        }
        print("tool round trip: OK")
        return true
    } catch {
        print("tool round trip FAILED (follow-up): \(KBLLMError.from(error))")
        return false
    }
}

let streamingOK = await runStreamingCompletion()
let toolOK = await runToolRoundTrip()

if streamingOK, toolOK {
    print("SMOKE OK against \(baseURL) [\(modelName)] via \(provider)")
    exit(0)
}
print("SMOKE FAILED against \(baseURL) [\(modelName)] via \(provider)")
exit(1)
