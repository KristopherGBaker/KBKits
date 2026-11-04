# ``KBLLM``

Talk to a language model without committing to one.

## Overview

KBLLM is a provider-neutral client. One protocol, ``LanguageModel``, has a single requirement an
adapter must write: stream a request and get events back. (Its one other member,
``LanguageModel/supportsWebSearch``, is a capability flag that defaults to `false`.) Everything else, including the non-streaming
``LanguageModel/complete(_:)``, is derived from it, so a streaming call and a collected call
can never disagree about what the model said.

Adapters live in their own targets, so a consumer links only what it uses: `KBLLMAnthropic`,
`KBLLMOpenAI` (`OpenAIModel` over Chat Completions, which also covers OpenRouter, LM Studio, Ollama and vLLM,
and `OpenAIResponsesModel` over OpenAI's Responses API, which its current models need for function calling), and `KBLLMApple` for
Apple's Foundation Models: the on-device model, and Apple's Private Cloud Compute server model
through `AppleModelBackends.privateCloudCompute()`, which a macOS 26 app can call with no
availability check. That model is live only on macOS 27 and only for an app signed with the
`com.apple.developer.private-cloud-compute` entitlement; otherwise the factory returns a stand-in
that reports why it is unavailable.

```swift
let model = OpenAIModel(
    model: "gpt-4o-mini",
    credentialKey: "OPENAI_API_KEY",
    transport: KBLLMURLSession(),
    credentials: EnvironmentCredentialStore()
)

let reply = try await model.complete(
    ModelRequest(messages: [Message(role: .user, text: "Name three colours.")])
)
print(reply.content, reply.usage?.inputTokens ?? 0)
```

To watch it arrive instead, consume the stream directly:

```swift
for try await event in model.stream(request) {
    if case let .contentDelta(text) = event { print(text, terminator: "") }
}
```

### What the design commits to

**Streaming is the primitive.** A client that ships separate streaming and non-streaming paths
lets the second one rot. There is deliberately no way to implement two.

**Nothing is silently downgraded.** If a request asks for something a provider cannot do, it is
refused by name (``KBLLMError/invalidRequest(field:reason:)``) or reported, never quietly
dropped. The failure this avoids is a caller believing it got a thing it did not get, which
surfaces much later as bad output rather than as an error.

**A schema constraint is enforced, not just forwarded.** An array's `minItems`
(``JSONSchema/array(items:description:minItems:)``) is sent to Anthropic and OpenAI and mapped
onto the on-device schema for Apple, and the post-decode conformance check still refuses a
shorter array as ``KBLLMError/schemaViolation(expected:received:)`` whatever the provider did
with it. A negative minimum is refused before any request leaves, by ``JSONSchema/validate()``.
A string's allowed values (``JSONSchema/string(description:choices:)``, JSON Schema `enum`) work
the same way: sent as `enum` to Anthropic (tool `input_schema`, the legacy structured tool and
`output_config.format`) and OpenAI (strict `response_format` and tool `parameters`), built as
`DynamicGenerationSchema(name:description:anyOf:)` for Apple, and checked on the answer, so a
value outside them is a ``KBLLMError/schemaViolation(expected:received:)`` naming the choices. An
empty, repeating or empty-string list is refused by ``JSONSchema/validate()``.

**Determinism is asked for by name.** ``GenerationOptions/sampling`` set to
``GenerationOptions/Sampling/greedy`` maps to the Foundation Models greedy sampling mode on Apple,
and to `temperature: 0` alone on Anthropic and OpenAI. It wins over a temperature or top-p also
set, and it is dropped, like every sampling hint, on the Anthropic models that removed sampling
parameters (Opus 4.7 and later, and 5.x). Unset, it adds nothing to any request.

**Usage is reported, never estimated.** ``TokenUsage`` carries the prompt-cache split, and a
call the provider said nothing about yields `nil` rather than zeros: "billed nothing" and "was
never told" are different facts.

**Seams, not singletons.** The network, credentials, logging, clock and randomness all arrive
through protocols, so a test needs no network and no keys.

### Searching the web

Set ``ModelRequest/webSearch`` to let the model search the web for current information while it
answers. It is SERVER-SIDE search: the provider runs the searches inside the same call and hands
back what it did, so KBLLM fetches nothing itself.

- **Anthropic only.** `AnthropicModel` reports ``LanguageModel/supportsWebSearch`` as `true`.
  `OpenAIModel` and `AppleModel` refuse a request with `webSearch` set as
  ``KBLLMError/invalidRequest(field:reason:)`` (field `"webSearch"`) before anything is sent,
  rather than answering without the search the caller asked for.
- **What comes back.** The stream adds ``ModelEvent/webSearchCall(_:)`` (each query),
  ``ModelEvent/webSearchResult(_:)`` (the sources, or why a search failed) and
  ``ModelEvent/citation(_:)`` (a source the model cited, with the UTF-16 range of the text it
  covers). The collected ``ModelResponse`` carries the same as ``ModelResponse/webSearches`` and
  ``ModelResponse/citations``. A failed search is data, not a thrown error: the model's text still
  arrives.
- **Privacy.** The model's queries, and the pages they return, pass through the provider.
  Anything in the conversation can end up shaping a query, so only opt in when the user has.
- **Cost.** Each search is billed on top of tokens (Anthropic: $10 per 1,000 searches).
  ``TokenUsage/webSearchRequests`` reports how many ran; ``WebSearchOptions/maxUses`` caps them.
- **Long turns.** When the API pauses a long search turn (`pause_turn`), the adapter continues
  it automatically, up to five times, and the caller sees one merged response. A turn that is
  still paused after that ends with ``FinishReason/paused``, never a silent truncation.
- **Not with structured output.** A request with both `responseSchema` and `webSearch` is refused:
  search results come back cited, and Anthropic rejects citations alongside a structured output
  format. Search first, then ask for the structured answer in a second request.

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
```

## Topics

### Talking to a model

- ``LanguageModel``
- ``ModelRequest``
- ``ModelResponse``
- ``ModelEvent``
- ``GenerationOptions``

### Messages

- ``Message``
- ``MessageRole``
- ``MessageContent``

### Tools and structured output

- ``ToolDefinition``
- ``ToolCallRecord``
- ``ToolResult``
- ``JSONSchema``

### Web search

- ``WebSearchOptions``
- ``WebSearchCall``
- ``WebSearchResult``
- ``WebSearchOutcome``
- ``WebSearchSource``
- ``WebSearchErrorCode``
- ``WebSearch``
- ``WebSearchCitation``

### Accounting

- ``TokenUsage``
- ``FinishReason``

### Fitting a conversation

- ``TokenEstimating``
- ``CharacterCountEstimator``

### Seams

- ``HTTPTransport``
- ``CredentialStore``
- ``LogSink``
- ``ClockSource``
- ``RandomSource``

### Errors

- ``KBLLMError``
