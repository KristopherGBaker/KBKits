# KBLLM

A provider-neutral LLM client. One `LanguageModel` protocol whose single adapter-written
requirement is `stream(_:)`, value-typed messages and requests, `@Tool`/`@Schema` macros, and adapters for
Apple Foundation Models, Anthropic, OpenAI's Responses API, and any OpenAI-compatible (Chat Completions) endpoint.

**What it is not.** Not an agent framework, not a RAG library, not a prompt-template engine. It
talks to a model. Conversation state, retrieval, and orchestration belong to the caller.

## Key types

- `LanguageModel`: the seam. ONE requirement an adapter writes, `stream(_:) -> AsyncThrowingStream<ModelEvent, any Error>`.
  `complete(_:)` is derived in an extension, so streaming and collected results cannot disagree.
  `supportsWebSearch` is a capability flag that defaults to `false`.
- `Message` / `MessageContent`: `.text`, `.image(data:mimeType:)`, `.toolCall`, `.toolResult`. An
  assistant `Message` may carry the `reasoning` it streamed (a field, not a content part), and
  `ModelResponse.reasoning` collects a call's `.reasoningDelta`s; `AgentSession` puts each turn's on
  the assistant message it appends. Only `OpenAIModel(replaysReasoning:)` sends it back. Its
  `reasoningBlocks` keep the provider's own reasoning to send back unchanged (`ReasoningBlock`: Anthropic's
  signed `.thinking` and `.redacted`, OpenAI's encrypted `.openAIReasoning`); each adapter sends only its own.
- `ModelRequest`: messages, tools, `responseSchema`, `GenerationOptions`, `webSearch`.
- `ModelEvent`: `.contentDelta`, `.reasoningDelta`, `.reasoningBlock`, `.toolCall`, `.usage`, `.webSearchCall`,
  `.webSearchResult`, `.citation`, `.completed`.
- `TokenUsage`: input/output, the prompt-cache read/write split, and `webSearchRequests`.
- `KBLLMError`: the typed error surface, including `.cancelled` and the opt-in `.httpStatusRetryAfter`.
- `JSONSchema` + `JSONSchema.parse(_:)`: schemas as values, or parsed from a JSON document.
- `EnvironmentCredentialStore` / `KeychainCredentialStore` (KBLLMURLSession): the two host
  secret stores: the environment for a shell tool, the platform vault for a shipped app.
  Only the vault-backed half is behind `canImport(Security)`, so the target still builds
  for Android, where `isAvailable` and `store` are honest about there being no vault.
- `AgentSession` (KBLLMRuntime): the tool loop.
- `@Tool` / `@Schema` (KBLLMMacros): a Swift function becomes a tool definition.
- `WebSearchOptions` and its results (`WebSearch`, `WebSearchCitation`, ...): server-side web
  search, Anthropic only. See below.

## What `@Tool` supports

Attach it to a FUNCTION: a free function, or a method on a `@ToolGroup` type. Any combination
of `async` and `throws` works, including neither; a thrown error becomes a `ToolResult.failure`
rather than escaping. A return value is JSON-encoded, so any `Encodable` works; no return value
yields `null`.

Methods on isolated types work without being declared `async`: an `actor`, or a type carrying
`@MainActor` or another global actor, is detected and the generated call awaits. A `nonisolated`
method is exempt.

Parameters map to JSON Schema by their written type: the `Int`/`UInt` family to `integer`,
`Double`/`Float`/`CGFloat` to `number`, `Bool` to `boolean`, `String`/`Character` to `string`,
and `[T]` to an array of the mapped element. An optional parameter is described by its WRAPPED
type and left out of `required`.

A macro sees syntax, never a resolved type, so any other parameter type falls back to `string`
and raises a warning naming the parameter. That fallback is right for a String-backed enum and
wrong for a structured type; if you need a nested object, take the fields as separate scalar
parameters.

## Array minimums (`minItems`)

`JSONSchema.array(items:description:minItems:)` takes an optional minimum element count. It
defaults to `nil`, so every existing `.array(items:description:)` still compiles and means
what it meant. `JSONSchema.parse(_:)` accepts `"minItems"` on an array node when it is a
non-negative JSON integer, and refuses it anywhere else.

- **Anthropic** sends `"minItems": n` in a tool `input_schema`, and in the legacy-route structured
  tool. A structured request to a current model (4.5 and later) rides `output_config.format`,
  whose grammar takes only `0` or `1`, so a larger minimum is sent as `1` and stated in the
  array's description; the conformance check below still enforces the full minimum.
- **OpenAI** sends it in `response_format.json_schema` (strict mode) and in tool `parameters`. An
  optional array is still sent as nullable (`["array", "null"]`) and listed in `required`, and
  it keeps its `minItems`.
- **Apple** maps it onto the FoundationModels `DynamicGenerationSchema(arrayOf:minimumElements:)`,
  so the on-device model is constrained to it while it generates.
- **Every adapter** also runs the post-decode conformance check: a structured answer whose array
  is shorter than its minimum ends in a thrown `.schemaViolation` naming the array's path and the
  minimum, never a quiet `.stop`. That holds even for a provider that ignores the keyword.
- **A negative minimum is refused** as `.invalidRequest` by `JSONSchema.validate()`, which every
  adapter calls on the `responseSchema` and on each tool's `parameters` before it opens a
  transport or runs inference. `0` is allowed. With `nil` no `minItems` key is sent at all.
- **The macros never emit it.** `@Tool` and `@Schema` still describe a `[T]` parameter as an
  array with no minimum; write the schema by hand, or parse it, when you need one.

## String choices (`enum`)

`JSONSchema.string(description:choices:)` takes an optional list of allowed values, the JSON
Schema `enum` on a string node. It defaults to `nil` (any string), so every existing
`.string(description:)` still compiles and means what it meant. `JSONSchema.parse(_:)` reads
`"enum"` on a string node into `choices`, and refuses it on any other type or with a member that
is not a string, `null` included: a choices list holds only strings, and an optional choice is
expressed by leaving the property out of `required`. A nullable string without `enum` parses as
before.

```swift
let schema: JSONSchema = .object(
    properties: ["label": .string(description: "the claim kind",
                                  choices: ["personalClaim", "general", "instruction"])],
    required: ["label"],
    description: nil
)
```

- **Anthropic** sends `"enum"` in a tool `input_schema`, in the legacy-route structured tool, and
  in `output_config.format.schema`, whose structured-outputs grammar takes string enums as
  written, so nothing is degraded.
- **OpenAI** sends it in `response_format.json_schema` (strict mode) and in tool `parameters`. An
  optional property is nullable there, so its list gains `null` (`["calm", "urgent", null]`), or
  strict mode could never send the property's absence. That wire form is output only:
  `JSONSchema.parse(_:)` refuses a `null` member, so a strict schema with an optional choice does
  not parse back.
- **Apple** (on-device and Private Cloud Compute) builds the node as
  `DynamicGenerationSchema(name:description:anyOf:)`, so the model can only generate one of the
  values.
- **Every adapter** also runs the post-decode conformance check: a string that is not one of the
  choices ends in a thrown `.schemaViolation` naming the node's path and the choices, in nested
  objects and array items too. Matching is exact: `"General"` is not `"general"`.
- **An unsendable list is refused** as `.invalidRequest` by `JSONSchema.validate()` before any
  transport or inference starts: an empty list, an empty-string value, or a repeated value.
- **The macros never emit it.** A `@Schema` property typed as a String-backed enum is still
  described as a plain string (see `@Tool` above); write the schema by hand when you need choices.

## Greedy sampling

`GenerationOptions(sampling: .greedy)` asks for deterministic decoding: always the most likely
next token. It defaults to `nil`, which adds nothing to any request. Greedy WINS over a
`temperature` or `topP` also set, on every adapter.

- **Apple** maps it to FoundationModels' `GenerationOptions.SamplingMode.greedy`, true greedy
  decoding, with no temperature or nucleus mode beside it.
- **Anthropic** sends `temperature: 0` alone to a model that takes sampling parameters (4.1 and
  older, the 4.x models up to Opus 4.6, and any id it cannot place). Opus 4.7+ and the 5.x models
  removed sampling parameters, so it is dropped there, like every other sampling hint.
- **OpenAI** sends `temperature: 0` alone, to every model, the way a caller's temperature already
  goes.

Temperature 0 is the closest the HTTP APIs come; neither promises identical answers across calls.

## Web search (Anthropic only)

`ModelRequest.webSearch` lets the model search the web for current information while it
answers. It is SERVER-SIDE search: the provider runs the searches inside the same call and
returns what it did as data. KBLLM fetches nothing itself.

```swift
let request = ModelRequest(
    messages: [Message(role: .user, text: "What changed in the latest Swift release?")],
    webSearch: WebSearchOptions(maxUses: 3, allowedDomains: ["swift.org"])
)
let reply = try await anthropic.complete(request)
reply.webSearches   // [WebSearch]: each query joined to its sources (url, title, page age) or error
reply.citations     // [WebSearchCitation]: url, title, cited text, and range(in: reply.content)
reply.usage?.webSearchRequests
```

- **Who supports it.** `AnthropicModel`, which sends `web_search_20260209` (dynamic filtering) to
  Sonnet and Opus 4.6 and later and `web_search_20250305` to every other model. `OpenAIModel` and
  `AppleModel` report `supportsWebSearch == false` and refuse a request with `webSearch` set as
  `.invalidRequest(field: "webSearch", ...)` before anything is sent. Check
  `model.supportsWebSearch` (it survives `any LanguageModel`, `normalizingErrors()` and
  middleware wrapping) before offering the option.
- **Options.** `maxUses` caps the searches (positive when set). `allowedDomains` OR
  `blockedDomains`, never both: both together, or `maxUses < 1`, is `.invalidRequest` before
  dispatch. `responseSchema` plus `webSearch` is refused too: search results come back cited,
  and the API rejects citations alongside a structured output format. Search in one request,
  then ask for the structured answer in a second that includes the findings.
- **Streaming.** `.webSearchCall` (id and query, once the query is complete),
  `.webSearchResult` (`.sources([WebSearchSource])` or `.failed(WebSearchErrorCode)`), and
  `.citation` (emitted when the cited text block ends; `utf16Range` locates it in the
  concatenated `contentDelta`s). A request without `webSearch` produces none of them.
- **A failed search is data.** An error result (`max_uses_exceeded`, `too_many_requests`,
  `unavailable`, ...) arrives inside a 200 and becomes `.failed(code)`. Nothing throws; the
  model's text still comes back even when every search failed.
- **Long turns (`pause_turn`).** The API may pause a long search turn. The adapter continues
  it automatically by sending the paused assistant turn back unchanged (every block as
  received, including `encrypted_content` and `encrypted_index`, plus the code execution
  `container` the turn ran in when it named one), up to 5 continuations, and
  the caller sees one merged response with one summed `.usage`. Still paused after that, it
  ends with `FinishReason.paused`, never a silent truncation. Each continuation is a billed call.
- **Privacy.** The model's queries and the pages they return pass through Anthropic. Anything
  in the conversation can shape a query, so opt in only when the user has.
- **Cost.** $10 per 1,000 searches on top of tokens; `TokenUsage.webSearchRequests` counts them.
- **AgentSession** carries `webSearch` (and `options`) into every turn; the search events themselves have no
  `RunEvent` yet, so stream the model directly when you need sources and citations.
- **Live check.** `KBLLM_LIVE_WEB_SEARCH=1` plus `ANTHROPIC_API_KEY` runs one real search
  request (`LiveWebSearchTests`, model overridable with `KBLLM_LIVE_ANTHROPIC_MODEL`); without
  them it is skipped.

## Apple: on-device and Private Cloud Compute

`AppleModel(backend:)` drives either Apple model through the neutral `FoundationModelBackend`
seam. `LiveFoundationModelBackend()` is the on-device model. `AppleModelBackends.privateCloudCompute()`
is Apple's Private Cloud Compute server model (no API key). It is callable from macOS 26 code with
no `#available`, and it answers one of three ways. The OS is checked first:

- **Before macOS 27** (or where FoundationModels is absent): a stand-in whose availability is
  `.unavailable(reason: "Private Cloud Compute requires macOS 27 or later")`.
- **macOS 27, process not signed with the entitlement**: a stand-in whose availability is
  `.unavailable(reason: "Private Cloud Compute needs the com.apple.developer.private-cloud-compute entitlement")`.
- **macOS 27, process signed with the entitlement**: the live `LivePrivateCloudComputeBackend`.

Either stand-in reports no capabilities, no quota and no context size, touches no FoundationModels
API, and refuses every run with its same `.unavailable`.

**The entitlement.** Private Cloud Compute is gated on the managed
`com.apple.developer.private-cloud-compute` entitlement. Without it, a live request does not throw:
it traps inside FoundationModels and takes the process down. That is why the factory checks the
entitlement (on macOS, by reading the running process's own signature) before it hands out the
live backend. To enable it:

1. Request the managed `com.apple.developer.private-cloud-compute` entitlement from Apple for
   your app's identifier.
2. Add it to the app's entitlements file with the value `true` (a Boolean; a string or number does
   not count).
3. Sign the app with a provisioning profile that grants it.

Constructing `LivePrivateCloudComputeBackend()` directly skips this gate; go through
`AppleModelBackends.privateCloudCompute()` unless you have checked the entitlement yourself.

**Known gap (iOS).** iOS has no public API for a process to read its own entitlements, so on iOS
the factory keeps its earlier behaviour: iOS 27 returns the live backend without checking the
entitlement. An unentitled iOS app that runs it will trap.

**Build and runtime floor, an explicit decision.** Building KBLLM needs the Xcode 27 SDK, because
macOS 27 types are named in source. The runtime floor stays macOS 26: `platforms` are still
`.macOS(.v26)` / `.iOS(.v26)`, and every macOS 27 API sits behind `@available` /
`#available(macOS 27, *)`. With a 26 deployment target the compiler rejects an unguarded 27
symbol, so `swift build` itself proves the guards.

**Capabilities.** Each backend reports a neutral `Set<FoundationModelCapability>`: `vision`,
`guidedGeneration`, `reasoning`, `toolCalling`. `AppleModel.capabilities` forwards it.

| Model / OS | Capabilities |
| --- | --- |
| On-device, macOS 26 | `guidedGeneration`, `toolCalling` (no `vision`) |
| On-device, macOS 27 | mapped from the framework's `LanguageModelCapabilities` |
| Private Cloud Compute, macOS 27, with the entitlement | mapped from the framework's `LanguageModelCapabilities` |
| Private Cloud Compute, macOS 27, without the entitlement | none |
| Private Cloud Compute, before 27 | none |

A custom backend that does not declare capabilities gets `guidedGeneration` and `toolCalling`.
`AppleModel` refuses, before any run, a request that needs a capability the backend does not
report: an `.image` part without `vision` (`.invalidRequest(field: "content.image")`, naming
`vision` and macOS 27), a `responseSchema` without `guidedGeneration`
(`.invalidRequest(field: "responseSchema")`), and tools without `toolCalling`
(`.invalidRequest(field: "tools")`). `reasoning` is reported for information only.

**Images.** On macOS 26 an image is refused (no 26 model reports `vision`). On macOS 27 with a
vision-capable model, every `.image` part is decoded and sent, in message order, as an image
`Attachment` alongside the prompt text, on both the on-device and the Private Cloud Compute
backend. An image that does not decode is refused as `.invalidRequest(field: "content.image")`
before any session is created.

**Context size: refused, not trimmed.** `AppleModel.contextSize()` forwards the backend's context
size (`nil` when unknown). Private Cloud Compute reports its size; the on-device backend reports
`nil`, so on-device requests dispatch exactly as they always have. When it is known and the request's
`CharacterCountEstimator` estimate is over it, the request is refused as
`.invalidRequest(field: "messages")` naming both numbers. Silently dropping history would answer
a different conversation, so trimming is the caller's deliberate call:
`messages.trimmedToFit(maxTokens:)` with the size the adapter exposes. A size that is unknown, or
whose lookup throws, dispatches unchecked, and the framework's own `contextSizeExceeded` is the
backstop.

**Quota.** `AppleModel.quotaUsage` exposes `FoundationModelQuotaUsage` (`isLimitReached`,
`isApproachingLimit`, `resetDate`), or `nil` for an unmetered model (on-device). While
`isLimitReached` holds, a request is refused as `.unavailable` naming the quota before any run;
approaching the limit still dispatches.

**Error mapping.** The framework's errors are mapped in the live layer onto existing
`KBLLMError` cases. No case was added: a new case breaks every consumer's exhaustive switch, and
each of these already fits one.

| FoundationModels error | `KBLLMError` |
| --- | --- |
| `PrivateCloudComputeLanguageModel.Error.networkFailure` | `.transport(url: "Private Cloud Compute", underlying:)` |
| `.quotaLimitReached` | `.unavailable(reason:)` naming the quota and its ISO-8601 reset date |
| `.serviceUnavailable` | `.unavailable(reason:)` with the service's description |
| `LanguageModelError.contextSizeExceeded` | `.invalidRequest(field: "messages", reason:)` naming both sizes |

Any other framework error still arrives as `.upstream`.

**Live smoke.** `KBLLM_LIVE_APPLE=1 swift test --filter LiveAppleSmokeTests` constructs the
live on-device backend and whatever `AppleModelBackends.privateCloudCompute()` returns to the test
process, and reads their metadata only (availability, capabilities, quota, context size),
printing one `APPLE-LIVE` line per model. `swift test` is not signed with the entitlement, so on
macOS 27 its Private Cloud Compute line reports the entitlement stand-in. It runs no inference,
and without the variable it is skipped.

## Targets

`KBLLM` (core) · `KBLLMAnthropic` · `KBLLMOpenAI` · `KBLLMApple` · `KBLLMRuntime` ·
`KBLLMMacros` · `KBLLMURLSession` (the live transport) · `KBLLMTesting` (fakes).

An adapter target exists so a consumer links only the providers it uses.

## Adapter knobs

A control that only ONE provider has lives on that provider's adapter, never on `ModelRequest`,
which must not carry one vendor's vocabulary. There are these:

- `AnthropicModel(promptCaching:)` places Anthropic's prompt-cache breakpoints: `.off` (the default),
  `.systemPrompt` (the tools and system prompt, for a stable prompt sent with a different question
  each time), or `.conversation` (that plus the newest message, for an agent loop or a chat, so each
  request reads the history the last one wrote). `AnthropicPromptCaching(lifetime: .oneHour)` keeps
  entries an hour instead of five minutes. Request bodies are written with sorted keys, so the same
  request has the same bytes in every process and a cache entry survives a relaunch.
- `OpenAIModel(reasoningEffort:)` sends `reasoning_effort`, omitted entirely when nil. Set it to
  `.none` to use FUNCTION TOOLS with a reasoning model on Chat Completions: some refuse tools
  while reasoning is on, answering with "use /v1/responses or set reasoning_effort to 'none'".
  Leave it nil for a model that does not take the parameter, which rejects an unknown field
  rather than ignoring it.
- `OpenAIModel(promptCacheKey:)` sends `prompt_cache_key`, omitted when nil (the default) or empty.
  OpenAI caches prompts on its own; the key routes requests that share a prefix to the same cache
  (more hits before GPT-5.6) and groups their cache accounting (GPT-5.6 and later). Pass one stable
  value per conversation, never anything personal. Usage reads `prompt_tokens_details.cached_tokens`
  into `cacheReadTokens` and `cache_write_tokens` (sent by the models that bill writes, GPT-5.6 and
  later) into `cacheWriteTokens`; both are parts of `inputTokens` (`prompt_tokens`), as OpenAI counts.
  DeepSeek's `prompt_cache_hit_tokens` (also part of `prompt_tokens`) is read as the cache reads
  when `cached_tokens` is absent. Request bodies are written with sorted keys.
- `OpenAIModel(replaysReasoning:)` (off by default) sends each assistant message's `reasoning` back
  as `reasoning_content`, never on another role and never when empty. DeepSeek's thinking mode needs
  it: once a request has tools, a later request without each earlier assistant turn's
  `reasoning_content` is a 400. Off elsewhere, because a strict server may refuse an unknown key.
- `OpenAIResponsesModel` is OpenAI's `POST /v1/responses`, a sibling of `OpenAIModel` rather than a mode of it:
  OpenAI's current models call functions only there, while the OpenAI-compatible servers speak only Chat
  Completions. It takes `baseURL`, `extraHeaders`, `promptCacheKey` (as above), `reasoningEffort`
  (`reasoning.effort`: `none` through `max`, including `minimal`) and `reasoningSummary` (`reasoning.summary`,
  streamed as `.reasoningDelta`), each omitted when nil. Every request is stateless (`store: false`, with
  `include: ["reasoning.encrypted_content"]`); each reasoning item comes back as a
  `.reasoningBlock(.openAIReasoning(...))` and goes back, unchanged, ahead of its turn's output. Usage reads
  `input_tokens_details.cached_tokens` and `.cache_write_tokens`. No web search: it is refused.

**Retry-After.** `KBLLMURLSession(reportsRetryAfter: true)` throws a non-success status whose response
carries a readable `Retry-After` (delay-seconds or an HTTP date, `RetryAfter.seconds(from:now:)`) as
`KBLLMError.httpStatusRetryAfter(code:message:retryAfter:)`, for every adapter on that transport.
It is off by default, so a caller matching `.httpStatus` for its 429s sees what it always did; with
it on, read `error.httpStatusCode` and `error.retryAfter` to treat both cases alike.

`ModelRequest.webSearch` is NOT an exception to this rule, though only Anthropic implements it
today: "search the web while answering" is a capability several providers offer under their own
vocabulary, so the neutral request carries the intent and each adapter either translates it or
refuses it by name. A prompt-cache marker or a reasoning-effort enum has no such neutral meaning.

## Invariants

- **Streaming is the primitive.** Adapters implement `stream` only.
- **Usage is reported, never estimated.** An unreported call yields `nil`, not zeros: "billed
  nothing" and "was never told" are different facts.
- **`.usage` is emitted at most once, immediately before `.completed`**, even where the provider
  reports it in pieces (Anthropic) or after the finish reason (OpenAI).
- **A request is never silently downgraded.** What cannot be honoured is refused
  (`.invalidRequest`) or reported.
- **Structured output satisfies OpenAI strict mode**: `additionalProperties: false` on every
  object, and an optional property is emitted as a nullable one rather than dropped or promoted.
- **`KBLLMError` is `LocalizedError`.** These reach people: a chat shows one when a turn fails,
  and a caller doing `as? any LocalizedError` used to get nil and fall back to a generic sentence,
  which turned a server explaining exactly what was wrong into "something went wrong". The
  server's own words are carried through rather than paraphrased.
- **A tool call with no arguments carries `{}`, never an empty string.** Anthropic sends no
  `input_json_delta` for a parameterless tool, so joining its fragments yields nothing; dispatch
  then refuses the call as invalid JSON, killing a run over arguments that were never in doubt.
- **Cancellation has its own error case.** Typed throws cannot rethrow `CancellationError`.

## Documentation

The API reference is a DocC catalog. Build or preview it with the Swift-DocC plugin, which the
manifest adds only when `KBLLM_BUILD_DOCS` is set:

```sh
cd Packages/KBLLM
KBLLM_BUILD_DOCS=1 swift package --disable-sandbox preview-documentation --target KBLLM
```

## Testing

`swift test` in `Packages/KBLLM`. Provider tests replay recorded wire transcripts through a
fake transport; nothing hits the network. Macro tests must be run from a clean `.build` to be
meaningful, because incremental builds reuse cached macro expansions.
