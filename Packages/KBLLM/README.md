# KBLLM

KBLLM is a provider-neutral client for large language models. You write a request once, as plain Swift values, and send
it to Anthropic, OpenAI (or any server that speaks its Chat Completions wire), or Apple's Foundation Models. Every
adapter answers with the same stream of events, the same token accounting and the same typed errors.

It also has `@Tool` and `@Schema` macros that turn a Swift function or type into a tool definition or a JSON schema,
an agent loop (`AgentSession`) that runs a model and its tools turn by turn, and offline fakes for tests.

**What it is not.** It is not a RAG library or a prompt-template engine. It talks to a model. Conversation state,
retrieval and orchestration belong to the caller; `AgentSession` is the one loop it ships, and it keeps no state between
runs.

## Install

KBLLM is part of the KBKits package. Depend on KBKits by version and name the products you use:

```swift
dependencies: [
    .package(url: "https://github.com/KristopherGBaker/KBKits.git", from: "1.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KBLLM", package: "KBKits"),
        .product(name: "KBLLMAnthropic", package: "KBKits"),
        .product(name: "KBLLMURLSession", package: "KBKits")
    ])
]
```

| Product | What it holds |
| --- | --- |
| `KBLLM` | The core: `LanguageModel`, messages, requests, events, `TokenUsage`, `KBLLMError`, `JSONSchema`, tools, the seam protocols, and the `@Tool`, `@Schema` and `@ToolGroup` macros (re-exported, so no second import). |
| `KBLLMAnthropic` | `AnthropicModel` (the Messages API) and `AnthropicModelList`. |
| `KBLLMOpenAI` | `OpenAIModel` (Chat Completions), `OpenAIResponsesModel` (the Responses API) and `OpenAIModelList`. |
| `KBLLMApple` | `AppleModel` over Apple's on-device model and its Private Cloud Compute server model. |
| `KBLLMURLSession` | `KBLLMURLSession`, the live `HTTPTransport`, and the two credential stores, `EnvironmentCredentialStore` and `KeychainCredentialStore`. |
| `KBLLMRuntime` | `AgentSession`, `RunEvent`, `RunResult`, and the middleware (`wrap(_:with:)`, `LoggingMiddleware`, `RetryMiddleware`). |
| `KBLLMTesting` | `ReplayModel`, `FixedClock` and `SeededRandomNumberGenerator`, for offline tests. |

Each adapter is its own product so an app links only the providers it uses. The macro implementation
(`KBLLMMacrosPlugin`, over swift-syntax) is built for the host as a compiler plugin and is not linked into your app.

KBKits needs Swift 6.2 and targets iOS 26 and macOS 26. `KBLLMApple` names macOS 27 types (Private Cloud Compute), so
building it needs the Xcode 27 SDK; see [Apple](#apple-on-device-and-private-cloud-compute).

## Quick start

Ask a model one question and read the whole answer:

```swift
import KBLLM
import KBLLMAnthropic
import KBLLMURLSession

let model = AnthropicModel(
    model: "claude-sonnet-5-5",
    credentialKey: "ANTHROPIC_API_KEY",
    transport: KBLLMURLSession(),
    credentials: EnvironmentCredentialStore()
)

let request = ModelRequest(messages: [
    Message(role: .system, text: "Answer in one sentence."),
    Message(role: .user, text: "What is a Swift actor?")
])

let reply = try await model.complete(request)
print(reply.content)
print(reply.usage?.inputTokens ?? 0, reply.usage?.outputTokens ?? 0)
```

To show the answer as it arrives, consume the stream instead:

```swift
for try await event in model.stream(request) {
    switch event {
    case .contentDelta(let text): print(text, terminator: "")
    case .completed(let reason): print("\n[\(reason)]")
    default: break
    }
}
```

Swap `AnthropicModel` for `OpenAIModel`, `OpenAIResponsesModel` or `AppleModel` and the rest of the code stays the same.

## The core

### `LanguageModel`

`LanguageModel` is the seam every adapter implements. It has one requirement an adapter writes:

```swift
func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error>
```

Everything else is derived from it:

- `complete(_:)` collects the stream into a `ModelResponse` and throws only `KBLLMError` (typed throws). Streaming and
  collected results cannot disagree, because there is only one path.
- `normalizingErrors()` wraps a model so its stream also throws only `KBLLMError`. Use it when you stream and want the
  same typed errors `complete(_:)` gives you.
- `supportsWebSearch` is a capability flag that defaults to `false`. It is a protocol requirement, so the answer survives
  `any LanguageModel`, `normalizingErrors()` and middleware wrapping.

### Messages

A `Message` has a `role` (`.system`, `.user`, `.assistant`, `.tool`) and an ordered list of `MessageContent` parts:

- `.text(String)`
- `.image(data:mimeType:)`: inline bytes only. There is no URL form, because the core ships no HTTP client; fetch the
  bytes yourself and pass them in.
- `.toolCall(ToolCallRecord)`: a call the model asked for (`id`, `name`, raw JSON `arguments`).
- `.toolResult(callID:_:)`: the `ToolResult` you send back for that call.

`Message(role:text:)` is the one-line form for a plain-text turn. An assistant message can also carry the `reasoning` it
streamed and its `reasoningBlocks`; see [Reasoning and replay](#reasoning-and-replay).

### Requests and options

`ModelRequest(messages:tools:responseSchema:options:webSearch:)` carries only what is provider-neutral. Every field but
`messages` has a default that adds nothing to the wire.

- `tools`: the `ToolDefinition`s the model may call.
- `responseSchema`: a `JSONSchema` the answer must match (structured output).
- `options`: `GenerationOptions(temperature:maxOutputTokens:topP:sampling:)`. Each knob is optional, and nil means
  omitted, so the provider's own default holds.
- `webSearch`: `WebSearchOptions` for server-side search (Anthropic only).

`temperature`, `topP` and `sampling` are hints. An adapter drops one the addressed model rejects rather than failing the
request: Anthropic's Opus 4.7 and later and 5.x models are sent none of them, and its 4.x models newer than 4.1 are sent
only `temperature` when both it and `topP` are set. `maxOutputTokens` is required on Anthropic's wire, so that adapter
sends 4,096 when it is nil; a value you set is always honored.

### Events and responses

`ModelEvent` is one unit of streamed output:

| Case | Meaning |
| --- | --- |
| `.contentDelta(String)` | A piece of the answer. |
| `.reasoningDelta(String)` | A piece of the model's reasoning, kept apart from the answer. |
| `.reasoningBlock(ReasoningBlock)` | A finished provider reasoning block to send back with the turn. |
| `.toolCall(ToolCallRecord)` | A tool call the model wants you to run. |
| `.usage(TokenUsage)` | What the call consumed. At most once, immediately before `.completed`. |
| `.webSearchCall`, `.webSearchResult`, `.citation` | Server-side web search activity. |
| `.completed(FinishReason)` | The end: `.stop`, `.toolCalls`, `.length`, `.contentFilter` or `.paused`. |

`ModelResponse`, from `complete(_:)`, holds the collected `content`, `toolCalls`, `finishReason`, `usage`, `reasoning`,
`webSearches` and `citations`.

### Token usage

`TokenUsage` reports `inputTokens`, `outputTokens`, the prompt-cache split (`cacheReadTokens`, `cacheWriteTokens`, and
`cacheWrite1hTokens`, the part of the writes with a one-hour lifetime), `webSearchRequests`, and `reportedCostUSD` when
the provider states the cost itself (OpenRouter's `usage.cost`). `+` sums two usages field by field; the sum has a
reported cost only if both sides had one.

Usage is reported, never estimated. A call the provider said nothing about has `usage == nil`, not zeros: "billed
nothing" and "was never told" are different facts. Cache fields are 0 for a provider without prompt caching.

### Errors

`KBLLMError` is the single error type. Each case carries what you need to fix the problem:

- `.transport(url:underlying:)`, `.httpStatus(code:message:)`, and the opt-in
  `.httpStatusRetryAfter(code:message:retryAfter:)` (see [Retry-After](#retry-after)).
- `.missingCredential(key:)`, `.decoding(expected:fragment:)`, `.unknownTool(name:)`,
  `.invalidRequest(field:reason:)`, `.upstream(cause:)`.
- `.cancelled`: typed throws cannot rethrow `CancellationError`, so cancellation has its own case.
- `.unavailable(reason:)`: the model cannot run here (an Apple model that is off, ineligible or out of quota).
- `.schemaViolation(expected:received:)`: a structured answer that does not match its schema.

`httpStatusCode`, `httpStatusMessage` and `retryAfter` read either HTTP case alike. `KBLLMError.from(_:)` maps any error
into the type; a foreign error becomes `.upstream`.

`KBLLMError` conforms to `LocalizedError`, because these messages reach people: a chat shows one when a turn fails. The
server's own words are carried through rather than paraphrased.

A failing tool is not a `KBLLMError`. It becomes an error `ToolResult` the model can read and recover from.

### Fitting a conversation

`messages.trimmedToFit(maxTokens:estimator:)` returns the newest messages that fit a budget, oldest dropped first.
System messages are always kept, at the front. The default estimator, `CharacterCountEstimator`, divides characters by 4
and charges 1 for each image or tool call. It is deliberately crude and deterministic, so leave headroom. Conform to
`TokenEstimating` for your own estimate.

Nothing in KBLLM trims for you. Dropping history silently would answer a different conversation, so trimming is the
caller's call.

## Providers

Every adapter takes a `transport` (an `HTTPTransport`, normally `KBLLMURLSession()`) and `credentials` (a
`CredentialStore`), and fetches its key by the `credentialKey` you name. Neither `model` nor `credentialKey` has a
default: the adapter never picks a model or a secret for you. `baseURL` defaults to the provider's public origin.

A control that only one provider has lives on that provider's adapter, never on `ModelRequest`, which must not carry one
vendor's vocabulary. `ModelRequest.webSearch` is not an exception to this rule, though only Anthropic implements it:
"search the web while answering" is a capability several providers offer, so the neutral request carries the intent and
each adapter translates it or refuses it by name. A prompt-cache marker or a reasoning-effort enum has no such neutral
meaning.

### Anthropic

```swift
let model = AnthropicModel(
    model: "claude-sonnet-5-5",
    credentialKey: "ANTHROPIC_API_KEY",
    promptCaching: .conversation,
    thinking: .adaptive(summarized: true),
    effort: .high,
    transport: KBLLMURLSession(),
    credentials: EnvironmentCredentialStore()
)
```

- **`baseURL`** is the server root, to which `/v1/messages` is appended (default `https://api.anthropic.com`). This
  differs from the OpenAI adapters, whose base ends in `/v1`. For LM Studio, which speaks both, pass
  `http://localhost:1234` here and `http://localhost:1234/v1` to `OpenAIModel`.
- **`promptCaching`** places Anthropic's prompt-cache breakpoints:
  - `.off` (the default): no breakpoints.
  - `.systemPrompt`: the tools and system prompt, for a long, stable prompt sent with a different question each time.
  - `.conversation`: that plus the newest message, for an agent loop or a chat, so each request reads the history the
    last one wrote.
  - `AnthropicPromptCaching(cachesSystemPrompt:cachesConversation:lifetime:)` with `lifetime: .oneHour` keeps entries an
    hour instead of five minutes (writes cost 2 times base input instead of 1.25).

  Request bodies are written with sorted keys, so the same request has the same bytes in every process and a cache
  entry survives a relaunch. Check `TokenUsage.cacheReadTokens` to see whether caching paid off.
- **`thinking`** (`AnthropicThinking`): `.adaptive(summarized:)`, `.betweenTools` or `.disabled`. nil sends no
  `thinking` field, so the model's default holds. Which values a model accepts differs; the adapter sends what it is
  given. Each signed thinking block the model returns is emitted as a `.reasoningBlock`, whatever this is set to.
- **`effort`** (`AnthropicEffort`): `output_config.effort`, `.low` through `.max`. nil leaves the model's default.
  Changing it mid-conversation invalidates the prompt cache.
- **Structured output** rides `output_config.format` on 4.5 and later models. Older or unrecognized ids get a strict
  tool offered with `tool_choice: auto`, never a forced choice.
- **Web search** is supported; see [Web search](#web-search-anthropic-only).

### OpenAI Chat Completions and compatible servers

`OpenAIModel` speaks Chat Completions, which also covers OpenRouter, DeepSeek, Groq, LM Studio, Ollama and vLLM.

```swift
let model = OpenAIModel(
    model: "deepseek-chat",
    credentialKey: "DEEPSEEK_API_KEY",
    baseURL: "https://api.deepseek.com/v1",
    transport: KBLLMURLSession(),
    credentials: EnvironmentCredentialStore()
)
```

- **`baseURL`** includes the version segment; `/chat/completions` is appended (default `https://api.openai.com/v1`).
- **`extraHeaders`** are sent with every request (OpenRouter attributes traffic by `HTTP-Referer` and `X-Title`). The
  adapter's own Authorization and content-type headers always win, in any letter case. An empty secret from the store
  sends no Authorization header, for a keyless local server.
- **`reasoningEffort`** sends `reasoning_effort` (`.none` through `.max`), omitted when nil. Set it to `.none` to use
  function tools with a reasoning model on Chat Completions: some refuse tools while reasoning is on, answering "use
  /v1/responses or set reasoning_effort to 'none'". Leave it nil for a model that does not take the parameter, which
  rejects an unknown field rather than ignoring it.
- **`outputTokenField`** chooses the field that carries `maxOutputTokens`: `.maxTokens` (`max_tokens`, the default, for
  older OpenAI models and most compatible servers) or `.maxCompletionTokens` (`max_completion_tokens`, which OpenAI's
  newer models require; they reject the old name with a 400).
- **`promptCacheKey`** sends `prompt_cache_key`, omitted when nil (the default) or empty. OpenAI caches prompts on its
  own; the key routes requests that share a prefix to the same cache (more hits before GPT-5.6) and groups their cache
  accounting (GPT-5.6 and later). Pass one stable value per conversation, never anything personal. A compatible server
  that does not know the field may refuse it.
- **`replaysReasoning`** (off by default) sends each assistant message's `reasoning` back as `reasoning_content`, never
  on another role and never when empty. DeepSeek's thinking mode needs it: once a request has tools, a later request
  without each earlier assistant turn's `reasoning_content` is a 400. It is off elsewhere because a strict server may
  refuse an unknown key.
- **`thinking`** (`OpenAIModel.ThinkingSwitch`, `.enabled` or `.disabled`) sends `thinking: {type: …}` for the servers
  that take it beside `reasoning_effort` (DeepSeek, Z.ai). OpenAI itself does not. Omitted when nil.
- **Usage** reads `prompt_tokens_details.cached_tokens` into `cacheReadTokens` and `cache_write_tokens` (sent by the
  models that bill writes, GPT-5.6 and later) into `cacheWriteTokens`; both are parts of `inputTokens`
  (`prompt_tokens`), as OpenAI counts. DeepSeek's `prompt_cache_hit_tokens` is read as the cache reads when
  `cached_tokens` is absent. Request bodies are written with sorted keys.
- **Gemini** (through its OpenAI-compatible endpoint) returns a thought signature in a tool call's `extra_content`. The
  adapter keeps it as `ReasoningBlock.toolCallExtra(callID:json:)` and sends it back on that call unchanged.

### OpenAI Responses

`OpenAIResponsesModel` is OpenAI's `POST /v1/responses`. It is a sibling of `OpenAIModel` rather than a mode of it:
OpenAI's current models call functions only there, while the compatible servers speak only Chat Completions.

```swift
let model = OpenAIResponsesModel(
    model: "gpt-5.6",
    credentialKey: "OPENAI_API_KEY",
    reasoningEffort: .medium,
    reasoningSummary: .auto,
    transport: KBLLMURLSession(),
    credentials: EnvironmentCredentialStore()
)
```

- It takes `baseURL`, `extraHeaders` and `promptCacheKey` as `OpenAIModel` does, plus `reasoningEffort`
  (`reasoning.effort`, `.none` through `.max`, including `.minimal`) and `reasoningSummary` (`reasoning.summary`:
  `.auto`, `.concise` or `.detailed`, streamed as `.reasoningDelta`). Each is omitted when nil. Without a summary a
  reasoning model streams no reasoning at all.
- Every request is stateless (`store: false`, with `include: ["reasoning.encrypted_content"]`). Each reasoning item comes
  back as a `.reasoningBlock(.openAIReasoning(...))` and goes back, unchanged, ahead of its turn's output.
- Usage reads `input_tokens_details.cached_tokens` and `.cache_write_tokens`.
- No web search: a request with `webSearch` set is refused.

### Apple: on-device and Private Cloud Compute

`AppleModel(backend:)` drives either Apple model through the `FoundationModelBackend` seam, which names no
FoundationModels type, so the adapter is testable with a scripted fake.

```swift
import KBLLMApple

let onDevice = AppleModel(backend: LiveFoundationModelBackend())
let cloud = AppleModel(backend: AppleModelBackends.privateCloudCompute())

if case .unavailable(let reason) = cloud.availability {
    print(reason)
}
```

`LiveFoundationModelBackend()` is the on-device model (`SystemLanguageModel.default`; pass another as `model:`). It is
compiled only where FoundationModels can be imported. `AppleModelBackends.privateCloudCompute()` is Apple's Private
Cloud Compute server model, which needs no API key. It is callable from macOS 26 code with no `#available`, and it
answers one of three ways. The OS is checked first:

- **Before macOS 27** (or where FoundationModels is absent): a stand-in whose availability is
  `.unavailable(reason: "Private Cloud Compute requires macOS 27 or later")`.
- **macOS 27, process not signed with the entitlement**: a stand-in whose availability is
  `.unavailable(reason: "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement")`.
- **macOS 27, process signed with the entitlement**: the live `LivePrivateCloudComputeBackend`.

Either stand-in reports no capabilities, no quota and no context size, touches no FoundationModels API, and refuses every
run with its same `.unavailable`. `AppleModel` checks availability before any run, so an unavailable model fails with a
typed `.unavailable` and never starts inference.

**The entitlement.** Private Cloud Compute is gated on the managed `com.apple.developer.private-cloud-compute`
entitlement. Without it, a live request does not throw: it traps inside FoundationModels and takes the process down. That
is why the factory checks the entitlement (on macOS, by reading the running process's own signature) before it hands out
the live backend. To enable it:

1. Request the managed `com.apple.developer.private-cloud-compute` entitlement from Apple for your app's identifier.
2. Add it to the app's entitlements file with the value `true` (a Boolean; a string or number does not count).
3. Sign the app with a provisioning profile that grants it.

Constructing `LivePrivateCloudComputeBackend()` directly skips this gate; go through
`AppleModelBackends.privateCloudCompute()` unless you have checked the entitlement yourself.

**Known gap (iOS).** iOS has no public API for a process to read its own entitlements, so on iOS 27 the factory returns
the live backend without checking the entitlement. An unentitled iOS app that runs it will trap.

**Build and runtime floor.** Building `KBLLMApple` needs the Xcode 27 SDK, because macOS 27 types are named in source.
The runtime floor stays macOS 26 and iOS 26, and every macOS 27 API sits behind `@available` or
`#available(macOS 27, *)`. With a 26 deployment target the compiler rejects an unguarded 27 symbol, so the build itself
proves the guards.

**Capabilities.** Each backend reports a `Set<FoundationModelCapability>`: `vision`, `guidedGeneration`, `reasoning`,
`toolCalling`. `AppleModel.capabilities` forwards it.

| Model and OS | Capabilities |
| --- | --- |
| On-device, macOS 26 | `guidedGeneration`, `toolCalling` (no `vision`) |
| On-device, macOS 27 | mapped from the framework's `LanguageModelCapabilities` |
| Private Cloud Compute, macOS 27, with the entitlement | mapped from the framework's `LanguageModelCapabilities` |
| Private Cloud Compute, macOS 27, without the entitlement | none |
| Private Cloud Compute, before 27 | none |

A custom backend that does not declare capabilities gets `guidedGeneration` and `toolCalling`. `AppleModel` refuses,
before any run, a request that needs a capability the backend does not report: an `.image` part without `vision`
(`.invalidRequest(field: "content.image")`, naming `vision` and macOS 27), a `responseSchema` without `guidedGeneration`
(`.invalidRequest(field: "responseSchema")`), and tools without `toolCalling` (`.invalidRequest(field: "tools")`).
`reasoning` is reported for information only.

**Images.** On macOS 26 an image is refused (no 26 model reports `vision`). On macOS 27 with a vision-capable model,
every `.image` part is decoded and sent, in message order, as an image `Attachment` alongside the prompt text, on both
backends. An image that does not decode is refused as `.invalidRequest(field: "content.image")` before any session is
created.

**Tools.** Foundation Models has no structured channel for tool history, so `AppleModel` renders tool calls and their
results into the prompt (`PromptRendering`). A model tool call ends the turn with `.toolCalls`, for `AgentSession` or
your own loop to run.

**Context size: refused, not trimmed.** `AppleModel.contextSize()` forwards the backend's context size (`nil` when
unknown). Private Cloud Compute reports its size; the on-device backend reports `nil`, so on-device requests dispatch
unchecked. When the size is known and the request's `CharacterCountEstimator` estimate is over it, the request is refused
as `.invalidRequest(field: "messages")` naming both numbers. To fit instead, trim with
`messages.trimmedToFit(maxTokens:)` and the size the adapter exposes. A size that is unknown, or whose lookup throws,
dispatches unchecked, and the framework's own `contextSizeExceeded` is the backstop.

**Quota.** `AppleModel.quotaUsage` exposes `FoundationModelQuotaUsage` (`isLimitReached`, `isApproachingLimit`,
`resetDate`), or `nil` for an unmetered model (on-device). While `isLimitReached` holds, a request is refused as
`.unavailable` naming the quota before any run; approaching the limit still dispatches.

**Error mapping.** The framework's errors are mapped onto existing `KBLLMError` cases. No case was added: a new case
breaks every consumer's exhaustive switch, and each of these already fits one.

| FoundationModels error | `KBLLMError` |
| --- | --- |
| `PrivateCloudComputeLanguageModel.Error.networkFailure` | `.transport(url: "Private Cloud Compute", underlying:)` |
| `.quotaLimitReached` | `.unavailable(reason:)` naming the quota and its ISO-8601 reset date |
| `.serviceUnavailable` | `.unavailable(reason:)` with the service's description |
| `LanguageModelError.contextSizeExceeded` | `.invalidRequest(field: "messages", reason:)` naming both sizes |

Any other framework error arrives as `.upstream`.

### Listing models

`ModelListing` is separate from `LanguageModel`: a settings screen asks for the list, a turn never does.
`AnthropicModelList` (`GET /v1/models`, following its pages) and `OpenAIModelList` (`GET {baseURL}/models`, or a full
`url:` for a catalog that lives elsewhere) take the same base URL, key and transport as their models.

```swift
let list = OpenAIModelList(
    credentialKey: "OPENAI_API_KEY",
    transport: KBLLMURLSession(),
    credentials: EnvironmentCredentialStore()
)
for listed in try await list.listModels() {
    print(listed.id, listed.displayName ?? "")
}
```

## Tools and the macros

A tool is a `ToolDefinition` (name, description, `parameters` schema) plus an invoker. Write it once, as a documented
function, and `@Tool` derives the rest:

```swift
import KBLLM

/// Adds two integers and returns their sum.
/// - Parameter a: The first addend.
/// - Parameter b: The second addend.
@Tool
func add(a: Int, b: Int) -> Int {
    a + b
}
```

`@Tool` generates a peer factory named after the function with a `Tool` suffix, here `addTool()`, returning a `Tool`.
The tool's name is the function's name, its description the doc comment's summary, and each parameter's description its
`- Parameter` line:

```swift
let tool = addTool()
tool.definition.name                                  // "add"
let result = await tool.invoke(Data(#"{"a":2,"b":3}"#.utf8))
result.isError                                        // false
result.text                                           // "5"
```

### What `@Tool` supports

Attach it to a function: a free function, or a method on a `@ToolGroup` type. Any combination of `async` and `throws`
works, including neither. A thrown error, or arguments that do not decode, become a `ToolResult.failure` rather than
escaping. A return value is JSON-encoded, so any `Encodable` works; no return value yields `null`.

Methods on isolated types work without being declared `async`: an `actor`, or a type carrying `@MainActor` or another
global actor, is detected and the generated call awaits. A `nonisolated` method is exempt.

Parameters map to JSON Schema by their written type: the `Int`/`UInt` family to `integer`, `Double`/`Float`/`CGFloat` to
`number`, `Bool` to `boolean`, `String`/`Character` to `string`, and `[T]` to an array of the mapped element. An optional
parameter is described by its wrapped type and left out of `required`. The JSON key is the parameter's argument label, or
its internal name when the label is `_`.

A macro sees syntax, never a resolved type, so any other parameter type falls back to `string` and raises a warning
naming the parameter. That fallback is right for a String-backed enum and wrong for a structured type; if you need a
nested object, take the fields as separate scalar parameters.

### Tool groups

`@ToolGroup` on a type collects its `@Tool` methods into a `toolBox` property (a `ToolBox`), each bound to `self`. Tools
can then capture injected dependencies and stay testable:

```swift
@ToolGroup
struct WeatherTools {
    let temperatures: [String: Double]

    /// Returns the current temperature in a city, in degrees Celsius, or null when it is unknown.
    /// - Parameter city: The city name, such as "Tokyo".
    @Tool
    func currentTemperature(city: String) -> Double? {
        temperatures[city]
    }
}

let box = WeatherTools(temperatures: ["Tokyo": 18, "Osaka": 21]).toolBox
box.definitions               // [ToolDefinition], for ModelRequest.tools
box.tool(named: "currentTemperature")
```

A reference-type or `@MainActor` group works too; the generated invoker captures `self` explicitly.

### Structured output with `@Schema`

`@Schema` on a type generates `static let schema: JSONSchema` from its stored properties, with the same type mapping as
`@Tool` and each property's doc comment as its description. Optional (`T?`) properties are left out of `required`;
computed properties are skipped.

```swift
@Schema
struct Answer: Decodable {
    /// The answer in one sentence.
    let summary: String
    /// How sure the model is, from 0 to 1.
    let confidence: Double
}

let reply = try await model.complete(ModelRequest(
    messages: [Message(role: .user, text: "Is Pluto a planet?")],
    responseSchema: Answer.schema
))
let answer = try JSONDecoder().decode(Answer.self, from: Data(reply.content.utf8))
```

The answer arrives as JSON text in `content`. Every adapter checks it against the schema when the stream ends: a document
that does not parse, has the wrong root type, misses a required property, or has a short array or a string outside its
choices ends in a thrown `.schemaViolation`, never a quiet `.stop`. Decoding into your type is yours to do, on a document
already proven to conform.

Structured output satisfies OpenAI strict mode: `additionalProperties: false` on every object, and an optional property
is sent as a nullable one rather than dropped or promoted.

The generated members (`schema`, `toolBox`, `<name>Tool()`) carry no access modifier, so they are internal to your
module.

### Writing schemas by hand

`JSONSchema` is a closed enum: `.object(properties:required:description:)`, `.string(description:choices:)`,
`.integer(description:)`, `.number(description:)`, `.boolean(description:)` and `.array(items:description:minItems:)`.
`JSONSchema.parse(_:)` reads one from a JSON document. Write or parse a schema when you need what the macros never emit:
string choices and array minimums.

`ToolDefinition(name:description:parameters:rawParameters:)` also takes the arguments' schema as raw JSON, for a schema
`JSONSchema` cannot say (`oneOf`, `anyOf`, `$ref`, `const`), such as an MCP server's `inputSchema`. The Anthropic and
OpenAI adapters send `rawParameters` in place of `parameters`; the Apple adapter cannot and uses `parameters`. It must be
a JSON object whose `type` is `"object"`, or `validate()` refuses it.

**Every adapter validates first.** `JSONSchema.validate()` runs on the `responseSchema` and on each tool's `parameters`
before any transport opens or inference starts, and refuses an unsendable schema as `.invalidRequest` naming the node
(`root`, `root.<prop>`, `root.<prop>[]`).

#### String choices (`enum`)

`JSONSchema.string(description:choices:)` takes an optional list of allowed values, the JSON Schema `enum` on a string
node. It defaults to `nil` (any string). `JSONSchema.parse(_:)` reads `"enum"` on a string node into `choices`, and
refuses it on any other type or with a member that is not a string, `null` included: a choices list holds only strings,
and an optional choice is expressed by leaving the property out of `required`.

```swift
let schema: JSONSchema = .object(
    properties: ["label": .string(description: "the claim kind",
                                  choices: ["personalClaim", "general", "instruction"])],
    required: ["label"],
    description: nil
)
```

- **Anthropic** sends `"enum"` in a tool `input_schema`, in the legacy-route structured tool, and in
  `output_config.format.schema`, whose grammar takes string enums as written, so nothing is degraded.
- **OpenAI** sends it in `response_format.json_schema` (strict mode) and in tool `parameters`. An optional property is
  nullable there, so its list gains `null` (`["calm", "urgent", null]`), or strict mode could never send the property's
  absence. That wire form is output only: `JSONSchema.parse(_:)` refuses a `null` member, so a strict schema with an
  optional choice does not parse back.
- **Apple** (on-device and Private Cloud Compute) builds the node as `DynamicGenerationSchema(name:description:anyOf:)`,
  so the model can only generate one of the values.
- **Every adapter** checks the answer: a string that is not one of the choices ends in a thrown `.schemaViolation`
  naming the node's path and the choices, in nested objects and array items too. Matching is exact: `"General"` is not
  `"general"`.
- **An unsendable list is refused** by `validate()`: an empty list, an empty-string value, or a repeated value.

#### Array minimums (`minItems`)

`JSONSchema.array(items:description:minItems:)` takes an optional minimum element count. It defaults to `nil`, and with
`nil` no `minItems` key is sent at all. `JSONSchema.parse(_:)` accepts `"minItems"` on an array node when it is a
non-negative JSON integer, and refuses it anywhere else.

- **Anthropic** sends `"minItems": n` in a tool `input_schema` and in the legacy-route structured tool. A structured
  request to a current model (4.5 and later) rides `output_config.format`, whose grammar takes only `0` or `1`, so a
  larger minimum is sent as `1` and stated in the array's description; the conformance check still enforces the full
  minimum.
- **OpenAI** sends it in `response_format.json_schema` (strict mode) and in tool `parameters`. An optional array is sent
  as nullable (`["array", "null"]`), listed in `required`, and keeps its `minItems`.
- **Apple** maps it onto `DynamicGenerationSchema(arrayOf:minimumElements:)`, so the on-device model is constrained to it
  while it generates.
- **Every adapter** checks the answer: an array shorter than its minimum ends in a thrown `.schemaViolation` naming the
  array's path and the minimum. That holds even for a provider that ignores the keyword.
- **A negative minimum is refused** by `validate()`. `0` is allowed and means "may be empty".

## The agent session

`AgentSession` (in `KBLLMRuntime`) runs the tool loop: it calls the model, runs the tools it asks for, appends their
results, and calls again until the model stops or `maxToolRoundTrips` (default 8) is reached.

```swift
import KBLLMRuntime

let session = AgentSession(
    model: model,
    tools: WeatherTools(temperatures: ["Tokyo": 18, "Osaka": 21]).toolBox
)

let result = try await session.run(ModelRequest(messages: [
    Message(role: .user, text: "Is it warmer in Tokyo or Osaka right now?")
]))

print(result.content)
result.toolCalls        // every call, in order
result.usage            // summed over every model call in the run
result.messages         // the full history, ready for the next turn
```

To continue the conversation, append the next user message to `result.messages` and run again. The session is a
`Sendable` value that keeps no state between runs.

To show progress, stream `RunEvent`s instead:

```swift
for try await event in session.stream(request) {
    switch event {
    case .contentDelta(let text): print(text, terminator: "")
    case .reasoningDelta: break
    case .toolInvoked(let call): print("\ncalling \(call.name)")
    case .toolReturned(let result): print("returned \(result.text ?? "")")
    case .usage(let usage): print("call used \(usage.inputTokens) in, \(usage.outputTokens) out")
    case .finished(let reason): print("\n[\(reason)]")
    }
}
```

How the loop behaves:

- The session sends its `ToolBox`'s definitions on every turn, in place of the request's `tools`. It carries the
  request's `responseSchema`, `options` and `webSearch` into every turn.
- A turn's tool calls run concurrently, but their results are appended in the model's call order, so the history is the
  same on every run.
- An unknown tool, or a failing one, becomes an error `ToolResult` the model reads (`ToolResult(erroring:toolName:)`,
  whose content is sorted-key JSON from `ToolResult.errorContent(for:)`). Only transport and protocol failures throw.
- Each assistant message it appends carries that turn's `reasoning` and `reasoningBlocks`.
- `.usage` is per model call, not summed, so a run that took six calls shows six. `RunResult.usage` is the sum.
- When the round-trip bound is hit, the run finishes with `.toolCalls`.
- Web search events have no `RunEvent` yet. Stream the model directly when you need sources and citations.

### Middleware

`wrap(_:with:)` composes `LanguageModelMiddleware`s around a model. The first element is the outermost wrapper: it sees
the request first and the response last. Only `stream` is intercepted, which covers `complete(_:)` too, and wrapping
keeps `supportsWebSearch`.

```swift
struct PrintSink: LogSink {
    func log(_ level: LogLevel, _ message: String) { print(level, message) }
}

struct SystemClock: ClockSource {
    var now: Date { Date() }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

let policy = RetryPolicy(delays: [.seconds(1), .seconds(4)]) { error in
    error.httpStatusCode == 429 || error.httpStatusCode == 529
}

let wrapped = wrap(model, with: [
    LoggingMiddleware(sink: PrintSink()),
    RetryMiddleware(policy: policy, clock: SystemClock())
])
```

- `LoggingMiddleware(sink:)` logs each request's text and every event to a `LogSink`.
- `RetryMiddleware(policy:clock:)` retries a failed call per a `RetryPolicy(delays:isRetryable:)`, sleeping through the
  injected `ClockSource`. There is no default policy: retrying is the caller's decision. A non-retryable error is
  rethrown at once. A call that already yielded events is never retried, because re-issuing it would double them.

The core ships no logger and no wall clock, so `LogSink` and `ClockSource` are yours to supply (as above), or the fakes
in `KBLLMTesting`.

## Testing

Nothing in KBLLM needs the network or a key to test. The network, credentials, logging, clock and randomness all arrive
through protocols (`HTTPTransport`, `CredentialStore`, `LogSink`, `ClockSource`, `RandomSource`).

`KBLLMTesting` has the fakes:

```swift
import KBLLM
import KBLLMTesting
import Testing

@Test func greets() async throws {
    let model = ReplayModel(transcript: [
        .contentDelta("Hello"),
        .contentDelta(", world"),
        .usage(TokenUsage(inputTokens: 12, outputTokens: 3)),
        .completed(.stop)
    ])
    let reply = try await model.complete(ModelRequest(messages: [Message(role: .user, text: "Hi")]))
    #expect(reply.content == "Hello, world")
    #expect(reply.usage?.outputTokens == 3)
}
```

- `ReplayModel(transcript:)` replays the same events on every call. In an `AgentSession`, a transcript with a `.toolCall`
  therefore asks for the tool on every turn until `maxToolRoundTrips`. For a scripted multi-turn conversation, write a
  small `LanguageModel` of your own; implementing `stream` is all it takes.
- `FixedClock(instant:)` is frozen at one instant, and its `sleep` returns at once, so `RetryMiddleware` runs at test
  speed.
- `SeededRandomNumberGenerator(seed:)` produces the same sequence for the same seed.
- `EnvironmentCredentialStore(environment:)` reads a fixed map instead of the process environment.
- To test an adapter's wire format, give it an `HTTPTransport` that returns recorded bytes from `openBytes(_:)`. That is
  how KBLLM's own provider tests run.

Tools are plain functions, so test them directly: `await addTool().invoke(Data(#"{"a":2,"b":3}"#.utf8))`.

## Reference notes

### Invariants

- **Streaming is the primitive.** Adapters implement `stream` only.
- **Usage is reported, never estimated.** An unreported call yields `nil`, not zeros.
- **`.usage` is emitted at most once, immediately before `.completed`**, even where the provider reports it in pieces
  (Anthropic) or after the finish reason (OpenAI).
- **A request is never silently downgraded.** What cannot be honored is refused (`.invalidRequest`) or reported.
- **A tool call with no arguments carries `{}`, never an empty string.** Anthropic sends no `input_json_delta` for a
  parameterless tool, so joining its fragments yields nothing; dispatch would then refuse the call as invalid JSON.
- **Cancellation has its own error case**, `.cancelled`. `complete(_:)` checks for cancellation before it sends and after
  the stream ends, so a cancelled call never looks like a model that said nothing.

### Greedy sampling

`GenerationOptions(sampling: .greedy)` asks for deterministic decoding: always the most likely next token. It defaults to
`nil`, which adds nothing to any request. Greedy wins over a `temperature` or `topP` also set, on every adapter.

- **Apple** maps it to FoundationModels' `GenerationOptions.SamplingMode.greedy`, true greedy decoding, with no
  temperature or nucleus mode beside it.
- **Anthropic** sends `temperature: 0` alone to a model that takes sampling parameters (4.1 and older, the 4.x models up
  to Opus 4.6, and any id it cannot place). Opus 4.7 and later and the 5.x models removed sampling parameters, so it is
  dropped there, like every other sampling hint.
- **OpenAI** sends `temperature: 0` alone, to every model, the way a caller's temperature already goes.

Temperature 0 is the closest the HTTP APIs come; neither promises identical answers across calls.

### Web search (Anthropic only)

`ModelRequest.webSearch` lets the model search the web for current information while it answers. It is server-side
search: the provider runs the searches inside the same call and returns what it did as data. KBLLM fetches nothing
itself.

```swift
let request = ModelRequest(
    messages: [Message(role: .user, text: "What changed in the latest Swift release?")],
    webSearch: WebSearchOptions(maxUses: 3, allowedDomains: ["swift.org"])
)
let reply = try await anthropic.complete(request)
for search in reply.webSearches { print("searched:", search.query) }
for citation in reply.citations {
    if let range = citation.range(in: reply.content) {
        print(reply.content[range], "<-", citation.url)
    }
}
print(reply.usage?.webSearchRequests ?? 0)
```

- **Who supports it.** `AnthropicModel`, which sends `web_search_20260209` (dynamic filtering) to Sonnet and Opus 4.6 and
  later and `web_search_20250305` to every other model. `OpenAIModel`, `OpenAIResponsesModel` and `AppleModel` report
  `supportsWebSearch == false` and refuse a request with `webSearch` set as `.invalidRequest(field: "webSearch", ...)`
  before anything is sent. Check `model.supportsWebSearch` before offering the option.
- **Options.** `maxUses` caps the searches (positive when set). Set `allowedDomains` or `blockedDomains`, never both:
  both together, or `maxUses < 1`, is `.invalidRequest` before dispatch. `responseSchema` plus `webSearch` is refused
  too: search results come back cited, and the API rejects citations alongside a structured output format. Search in one
  request, then ask for the structured answer in a second that includes the findings.
- **What comes back.** Each `WebSearch` joins a query to its outcome: `.sources([WebSearchSource])` (url, title, page
  age) or `.failed(WebSearchErrorCode)`. Each `WebSearchCitation` has a url, title, the cited text, and `utf16Range`,
  which locates its span in the collected content; `range(in:)` converts it to `String.Index` bounds.
- **Streaming.** `.webSearchCall` (id and query, once the query is complete), `.webSearchResult`, and `.citation`
  (emitted when the cited text block ends, so the text it points at has already arrived). A request without `webSearch`
  produces none of them.
- **A failed search is data.** An error result (`max_uses_exceeded`, `too_many_requests`, `unavailable`, ...) arrives
  inside a 200 and becomes `.failed(code)`. Nothing throws; the model's text still comes back even when every search
  failed.
- **Long turns (`pause_turn`).** The API may pause a long search turn. The adapter continues it automatically by sending
  the paused assistant turn back unchanged (every block as received, including `encrypted_content` and
  `encrypted_index`, plus the code execution `container` the turn ran in when it named one), up to 5 continuations, and
  the caller sees one merged response with one summed `.usage`. Still paused after that, it ends with
  `FinishReason.paused`, never a silent truncation. Each continuation is a billed call.
- **Privacy.** The model's queries and the pages they return pass through Anthropic. Anything in the conversation can
  shape a query, so opt in only when the user has.
- **Cost.** $10 per 1,000 searches on top of tokens; `TokenUsage.webSearchRequests` counts them.

### Reasoning and replay

Reasoning is never part of the answer. It streams as `.reasoningDelta`, collects into `ModelResponse.reasoning` (never
into `content`), and rides on an assistant `Message` in two fields beside its content:

- `reasoning: String?` is the text the model streamed. Only `OpenAIModel(replaysReasoning: true)` sends it back (as
  `reasoning_content`); every other adapter ignores it.
- `reasoningBlocks: [ReasoningBlock]?` keeps the provider's own reasoning, to send back unchanged:
  Anthropic's signed `.thinking(text:signature:)` and `.redacted(data:)`, OpenAI Responses'
  `.openAIReasoning(id:encryptedContent:summary:)`, and a Chat Completions call's `.toolCallExtra(callID:json:)`. Each
  adapter sends only its own provider's blocks, so a conversation that changes provider loses only the other provider's
  reasoning, never its turn.

`AgentSession` puts both on each assistant message it appends. If you run your own loop, keep them yourself:
`complete(_:)` collects `reasoning` but drops `.reasoningBlock` events, so stream the call and collect them when the
provider needs its blocks back (Anthropic thinking within a tool loop, OpenAI Responses reasoning).

### Retry-After

`KBLLMURLSession(reportsRetryAfter: true)` throws a non-success status whose response carries a readable `Retry-After`
(delay-seconds or an HTTP date, read by `RetryAfter.seconds(from:now:)` and clamped to one day) as
`KBLLMError.httpStatusRetryAfter(code:message:retryAfter:)`, for every adapter on that transport. It is off by default,
so a caller matching `.httpStatus` for its 429s sees what it always did. With it on, read `error.httpStatusCode` and
`error.retryAfter` to treat both cases alike.

### Credential stores

`KBLLMURLSession` ships the two stores a host usually needs:

- `EnvironmentCredentialStore()` resolves a key to the environment variable of the same name, read at each lookup, so a
  variable exported after the store was built is still seen. Right for a tool run from a shell.
- `KeychainCredentialStore(service:)` keeps a key the user typed in the platform vault. Right for a shipped app.

```swift
let keychain = KeychainCredentialStore(service: "com.example.MyApp")
keychain.store(typedKey, forKey: "ANTHROPIC_API_KEY")   // nil or blank removes it
keychain.hasSecret(forKey: "ANTHROPIC_API_KEY")         // true, without returning the key
```

An absent or empty secret throws `.missingCredential(key:)` naming the key, from either store. `hasSecret(forKey:)`
lets a settings screen show "a key is set" without holding the key. Only the vault-backed half is behind
`canImport(Security)`, so the target still builds for Android, where `isAvailable` is false, `store` returns false and
lookups throw: the store never pretends to keep a secret it cannot.

For any other location, conform to `CredentialStore` (`secret(forKey:)`).

### The transport

`KBLLMURLSession` is the only target that imports a networking framework. It takes a `URLSessionConfiguration`
(default `.default`), so a test can register a stub `URLProtocol`. A host transport must surface a non-success status by
throwing `KBLLMError.httpStatus(code:message:)` into the byte stream, never by yielding the error body as content. To
port KBLLM to a platform without `URLSession`, implement `HTTPTransport` (`send(_:)` and `openBytes(_:)`).

### Writing an adapter

Conform to `LanguageModel` and implement `stream(_:)`. The core has the pieces the bundled adapters share:
`SSE.events(from:)` parses a Server-Sent Events byte stream, `StructuredCollector` runs the end-of-stream schema check,
and `PromptRendering.instructions(from:)` and `prompt(from:)` flatten a conversation for a backend that takes one prompt
string. Call `validate()` on the `responseSchema` and each tool definition before you send anything.

## Documentation

The API reference is a DocC catalog (`Sources/KBLLM/KBLLM.docc`). Build or preview it with the Swift-DocC plugin, which
the root manifest adds only when `KBLLM_BUILD_DOCS` is set. From the repository root:

```sh
KBLLM_BUILD_DOCS=1 swift package --disable-sandbox preview-documentation --target KBLLM
```

## Running the tests

From the KBKits repository root:

```sh
swift test --filter KBLLM
```

Provider tests replay recorded wire transcripts through a fake transport; nothing hits the network. Macro tests must be
run from a clean `.build` to be meaningful, because incremental builds reuse cached macro expansions.

A few live checks are skipped unless you opt in:

- `KBLLM_LIVE_WEB_SEARCH=1` with `ANTHROPIC_API_KEY` runs one real search request (`LiveWebSearchTests`; the model can be
  overridden with `KBLLM_LIVE_ANTHROPIC_MODEL`).
- `KBLLM_LIVE_STRUCTURED=1` with `ANTHROPIC_API_KEY` runs real structured-output requests (`LiveStructuredOutputTests`,
  against the comma-separated ids in `KBLLM_LIVE_ANTHROPIC_MODELS` when set).
- `KBLLM_LIVE_APPLE=1 swift test --filter LiveAppleSmokeTests` constructs the live on-device backend and whatever
  `AppleModelBackends.privateCloudCompute()` returns to the test process, and reads their metadata only (availability,
  capabilities, quota, context size), printing one `APPLE-LIVE` line per model. It runs no inference. `swift test` is
  not signed with the entitlement, so on macOS 27 its Private Cloud Compute line reports the entitlement stand-in. The
  same variable also runs `LiveAppleChoicesTests`, one real on-device inference with string choices and greedy sampling.

`Tools/KBLLMSmoke` is a hand-run live check of the OpenAI-wire adapter against a real server, outside every build and
test.
