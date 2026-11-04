import Foundation

// The ADAPTER-FACING surface: everything a provider adapter must implement or
// hand back lives in THIS file and only this file, so "what do I implement to add
// a provider" has exactly one answer a reader can find in one place. The protocol
// and its value types (`ModelRequest`, `ModelEvent`, `ModelResponse`) are declared
// together here deliberately; nothing in this set is scattered elsewhere. The one exception
// is the web search payload family in `WebSearch.swift`, which `ModelRequest`, `ModelEvent`
// and `ModelResponse` here carry; it sits beside this file only to keep it within the house
// length limit.

/// A role in a conversation turn.
public enum MessageRole: String, Sendable, Codable, Equatable {
    case system
    case user
    case assistant
    case tool
}

/// One ordered piece of a message. A turn is a SEQUENCE of parts rather than a lone
/// string because tool calls and their results have to live in conversation history in
/// the exact order they happened, and a text-only field could not carry them. The order
/// is significant: the model reads a turn back in the order the parts are listed.
public enum MessageContent: Sendable, Equatable, Codable {
    case text(String)
    case toolCall(ToolCallRecord)
    case toolResult(callID: String, ToolResult)
    /// An image a multimodal caller attaches to a turn, carried as INLINE BYTES plus their
    /// MIME type and nothing else: no URL, no file path, no lazy loader. A remote URL is
    /// deliberately excluded because honouring one would make the core fetch bytes, and the
    /// core ships no HTTP client by design; a caller that holds a URL fetches it with its own
    /// transport and hands over the bytes. This is the THIRD deliberate guarded-enum update,
    /// after `reasoningDelta` and `schemaViolation`. Output is unaffected: images are input
    /// only, so `ModelEvent` does not grow a matching case.
    case image(data: Data, mimeType: String)
}

/// A single conversation turn handed to a model. It carries ORDERED content parts, so a
/// turn can interleave text with the tool calls and tool results the runtime feeds back
/// into history; a plain-text turn is just a one-element `content`.
public struct Message: Sendable, Equatable, Codable {
    public var role: MessageRole
    public var content: [MessageContent]
    /// The reasoning the model streamed (`ModelEvent.reasoningDelta`) while producing this ASSISTANT turn, or nil. It
    /// is a field beside `content` rather than a fourth guarded `MessageContent` case on purpose: reasoning is not a
    /// part of the answer and has no place in its order, and a field leaves every exhaustive switch over
    /// `MessageContent` (here and in callers) untouched. Some providers need it sent back: DeepSeek's thinking mode
    /// answers a tool-using request with a 400 unless every earlier assistant message carries its `reasoning_content`.
    /// Only an adapter told to replay it does so (`OpenAIModel(replaysReasoning:)`); every other adapter ignores it.
    /// Optional and nil by default, so a message without it encodes exactly as before and JSON written before the field
    /// existed still decodes.
    public var reasoning: String?
    /// The provider's own reasoning blocks for this ASSISTANT turn, in the order they arrived
    /// (`ModelEvent.reasoningBlock`), or nil. Anthropic signs each thinking block and asks for it back UNCHANGED, above
    /// all within a tool loop, where it carries the reasoning behind the tool calls; OpenAI's Responses API does the
    /// same with its encrypted reasoning items. Each adapter reads only its own provider's blocks and sends them before
    /// the turn's content. Optional and nil by default, like `reasoning`, so older JSON
    /// decodes and a message without it encodes as before.
    public var reasoningBlocks: [ReasoningBlock]?

    public init(
        role: MessageRole, content: [MessageContent], reasoning: String? = nil, reasoningBlocks: [ReasoningBlock]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.reasoningBlocks = reasoningBlocks
    }

    /// The common case kept a one-liner: a plain-text turn is a single `.text` part, so
    /// callers that never touch tools are not forced to spell out the content array.
    public init(role: MessageRole, text: String) {
        self.init(role: role, content: [.text(text)])
    }
}

/// One reasoning block exactly as the provider returned it, to be sent back with its turn. Anthropic's thinking blocks
/// carry a `signature` over their text (which may be empty: a model whose thinking display is omitted streams none),
/// and a redacted block carries only encrypted `data`; the API refuses either if it comes back modified, so both are
/// kept verbatim. Each case belongs to one provider and only that provider's adapter sends it back (each skips the
/// other's), so a conversation that changes provider loses only the other provider's reasoning, never its turn.
public enum ReasoningBlock: Sendable, Equatable, Codable {
    case thinking(text: String, signature: String)
    case redacted(data: String)
    /// An OpenAI Responses `reasoning` output item (`OpenAIResponsesModel`): its `id`, its `encrypted_content` (the
    /// reasoning itself, which a stateless `store: false` request can only carry this way) and its summary texts. The
    /// API asks for a tool loop's items back with the function calls they led to. A deliberate guarded-enum update.
    case openAIReasoning(id: String, encryptedContent: String, summary: [String])
}

/// The input to a model call. Adapters translate this into their wire format; it
/// carries only what is provider-neutral, so the same request drives any adapter.
public struct ModelRequest: Sendable, Equatable {
    public var messages: [Message]
    public var tools: [ToolDefinition]
    public var responseSchema: JSONSchema?
    /// The neutral sampling controls. Defaulted to an all-nil value so every existing call
    /// site keeps compiling and behaving IDENTICALLY: the default is genuinely inert, adding
    /// no wire key on any adapter, so a request that sets nothing is byte-for-byte what it
    /// was before this field existed.
    public var options: GenerationOptions
    /// Server-side web search, or nil (the default) for none. Defaulted so every existing call
    /// site is unchanged: a nil value adds nothing to any wire body. When set, only a model whose
    /// ``LanguageModel/supportsWebSearch`` is true runs the request; every other adapter refuses
    /// it as `.invalidRequest(field: "webSearch", ...)` before dispatch rather than dropping it.
    public var webSearch: WebSearchOptions?

    public init(
        messages: [Message],
        tools: [ToolDefinition] = [],
        responseSchema: JSONSchema? = nil,
        options: GenerationOptions = GenerationOptions(),
        webSearch: WebSearchOptions? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.responseSchema = responseSchema
        self.options = options
        self.webSearch = webSearch
    }
}

/// Why a model stopped producing output.
public enum FinishReason: String, Sendable, Codable, Equatable {
    case stop
    case toolCalls
    case length
    case contentFilter
    /// The provider paused a long server-side turn (Anthropic `pause_turn`, during web search)
    /// more times than the adapter continues automatically. The content is everything that
    /// arrived up to the last pause, so the answer is INCOMPLETE; this reason exists so that is
    /// never mistaken for `.stop`.
    case paused
}

/// A tool invocation the model asked the caller to perform. The arguments stay as
/// raw JSON bytes so the core never has to know a tool's argument shape.
public struct ToolCallRecord: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var arguments: Data

    public init(id: String, name: String, arguments: Data) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One unit of streamed model output. The stream is the primitive; every richer
/// shape (a collected response, a tool loop) is derived by the caller from these.
/// What one model call consumed, as the provider reported it.
///
/// Only reported, never estimated: a provider that says nothing produces no `TokenUsage` at
/// all rather than a zeroed one, because "0 tokens" and "not told" bill differently and a
/// caller summing them must be able to tell which it has.
///
/// Cache fields are 0 for a provider without prompt caching, which is the honest number
/// there: no cache exists, so nothing was read from or written to it.
public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Prompt-cache reads and writes (Anthropic `cache_read_input_tokens` /
    /// `cache_creation_input_tokens`). Billed at different rates from ordinary input, which
    /// is why they are separate fields rather than folded into `inputTokens`.
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// Server-side web searches the call ran (Anthropic `server_tool_use.web_search_requests`).
    /// Not tokens, but billed per search, so it is reported beside them; 0 when none ran.
    public var webSearchRequests: Int
    /// The part of `cacheWriteTokens` written with a one-hour lifetime (Anthropic
    /// `cache_creation.ephemeral_1h_input_tokens`), billed at a higher rate than the default
    /// five-minute write; the rest of `cacheWriteTokens` is five-minute. 0 when not reported.
    public var cacheWrite1hTokens: Int
    /// What the provider says the call cost, in US dollars, when the response carries it
    /// (OpenRouter's `usage.cost` on an OpenAI-compatible response). nil when the provider
    /// reports tokens only, which is the usual case; callers then estimate from a price table.
    public var reportedCostUSD: Double?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        webSearchRequests: Int = 0,
        cacheWrite1hTokens: Int = 0,
        reportedCostUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.webSearchRequests = webSearchRequests
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.reportedCostUSD = reportedCostUSD
    }

    /// Field-wise sum, for totalling the calls of a multi-call run. Every field is a count
    /// of tokens actually billed, so adding them is meaningful in a way that averaging or
    /// maxing would not be.
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            webSearchRequests: lhs.webSearchRequests + rhs.webSearchRequests,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens,
            // A total is only a reported cost if every call reported one; otherwise part of
            // it would be missing, so it is nil and the caller estimates instead.
            reportedCostUSD: lhs.reportedCostUSD.flatMap { left in rhs.reportedCostUSD.map { left + $0 } }
        )
    }
}

public enum ModelEvent: Sendable, Equatable {
    case contentDelta(String)
    /// A chunk of the model's REASONING, streamed in a field separate from the answer
    /// (OpenAI `delta.reasoning_content`, Anthropic `thinking` blocks). It is a distinct
    /// case, not a `contentDelta`, because reasoning is not the answer: a caller that
    /// ignores it must be unaffected, and `complete` deliberately never folds it into
    /// `ModelResponse.content`. Without it a reasoning model looks like a long hang
    /// followed by a sudden answer.
    case reasoningDelta(String)
    /// A finished reasoning block for the caller to keep on the turn's `Message.reasoningBlocks` and send back
    /// (Anthropic's signed thinking, an OpenAI Responses reasoning item). Emitted when the block ends, after its
    /// `reasoningDelta`s; a caller that only shows reasoning can ignore it. Only an adapter whose provider asks for its
    /// blocks back emits it.
    case reasoningBlock(ReasoningBlock)
    case toolCall(ToolCallRecord)
    /// What the call consumed. Emitted AT MOST ONCE per call, immediately before
    /// `.completed`, even by providers that report usage in pieces across the stream
    /// (Anthropic sends input and cache counts at the start and output counts at the end).
    /// An adapter accumulates and reports once, so a consumer never has to know which
    /// provider splits what, and never double-counts by adding two partial reports.
    ///
    /// Absent entirely when the provider reported nothing.
    case usage(TokenUsage)
    /// A server-side web search the model ran, emitted once its query is complete. Only a
    /// request with `webSearch` set produces this and the two cases below; a caller that ignores
    /// them still gets the answer through `contentDelta`.
    case webSearchCall(WebSearchCall)
    /// The outcome of a search, keyed to its call. A failed search is this event carrying
    /// `.failed`, never a thrown error, because the model carries on and still answers.
    case webSearchResult(WebSearchResult)
    /// A source the model cited for a span of text it has already streamed.
    case citation(WebSearchCitation)
    case completed(FinishReason)
}

/// The collected result of a whole model call. This is what the DERIVED
/// non-streaming path returns; adapters never build it directly, which is why a
/// streaming and a non-streaming call can never disagree.
public struct ModelResponse: Sendable, Equatable {
    public var content: String
    public var toolCalls: [ToolCallRecord]
    public var finishReason: FinishReason?
    /// What the call consumed, or nil when the provider reported nothing. See `TokenUsage`
    /// for why an unreported call is nil rather than zero.
    public var usage: TokenUsage?
    /// The server-side searches the call ran, in order, each joined to its outcome. Empty for a
    /// request without `webSearch`.
    public var webSearches: [WebSearch]
    /// The sources the model cited, in order, each locating its span of `content`.
    public var citations: [WebSearchCitation]
    /// Every `.reasoningDelta` of the call, concatenated; empty when the model streamed none. Kept apart from `content`
    /// (reasoning is not the answer) so a caller can put it on the assistant `Message` it appends
    /// (`Message.reasoning`).
    public var reasoning: String

    public init(
        content: String,
        toolCalls: [ToolCallRecord] = [],
        finishReason: FinishReason? = nil,
        usage: TokenUsage? = nil,
        webSearches: [WebSearch] = [],
        citations: [WebSearchCitation] = [],
        reasoning: String = ""
    ) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
        self.webSearches = webSearches
        self.citations = citations
    }
}

/// The one seam a provider adapter implements. It has exactly ONE requirement an adapter
/// must write, and it streams: every client that ships separate streaming and non-streaming
/// paths lets the second one rot, so there is deliberately no way to implement two. The
/// capability flag beside it is defaulted, so an adapter that lacks the capability writes
/// nothing.
public protocol LanguageModel: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error>

    /// Whether this model runs server-side web search (`ModelRequest.webSearch`). Defaults to
    /// false; a model that reports false refuses a request with `webSearch` set as
    /// `.invalidRequest(field: "webSearch", ...)`. A REQUIREMENT rather than an extension
    /// member so the answer survives being held as `any LanguageModel` or wrapped.
    var supportsWebSearch: Bool { get }
}

public extension LanguageModel {
    /// No server-side web search unless the adapter says otherwise.
    var supportsWebSearch: Bool { false }

    /// The DERIVED non-streaming call. An adapter does not implement this; the core
    /// aggregates the stream so the two paths cannot drift. This is also core
    /// normalization choke point (1): any error surfaced by the adapter's `stream`,
    /// typed or foreign, leaves here as a `KBLLMError`, so a caller of the collected
    /// path gets the typed-error guarantee for free.
    func complete(_ request: ModelRequest) async throws(KBLLMError) -> ModelResponse {
        var content = ""
        var reasoning = ""
        var toolCalls: [ToolCallRecord] = []
        var finishReason: FinishReason?
        var usage: TokenUsage?
        var searches = WebSearchCollector()
        do {
            // Collection honors cancellation itself rather than trusting the adapter to.
            // This first guard keeps an already-cancelled caller from reaching the provider at
            // all, so no request is spent on work nobody is waiting for.
            try Task.checkCancellation()
            for try await event in stream(request) {
                switch event {
                case .contentDelta(let delta):
                    content += delta
                case .reasoningDelta(let delta):
                    // Reasoning is not the answer, so it never joins the collected `content`;
                    // it is collected on its own into `ModelResponse.reasoning`.
                    reasoning += delta
                case .reasoningBlock:
                    // Kept only by a caller that sends a turn back (`Message.reasoningBlocks`); a one-off answer has
                    // none.
                    break
                case .toolCall(let record):
                    toolCalls.append(record)
                case .usage(let reported):
                    usage = reported
                case .webSearchCall, .webSearchResult, .citation:
                    searches.absorb(event)
                case .completed(let reason):
                    finishReason = reason
                }
            }
            // `AsyncThrowingStream` ENDS iteration when its consuming task is cancelled rather
            // than throwing, so without this a cancelled collection is indistinguishable from a
            // model that finished normally and happened to say nothing.
            try Task.checkCancellation()
        } catch {
            throw KBLLMError.from(error)
        }
        return ModelResponse(
            content: content,
            toolCalls: toolCalls,
            finishReason: finishReason,
            usage: usage,
            webSearches: searches.searches,
            citations: searches.citations,
            reasoning: reasoning
        )
    }

    /// Core normalization choke point (2). Streaming consumers cannot lean on the
    /// collected path's catch, so this decorator wraps an adapter's `stream` and maps
    /// any non-typed error it surfaces into the matching `KBLLMError` case. The result
    /// itself conforms to `LanguageModel`, so it drops in wherever the raw adapter did.
    func normalizingErrors() -> some LanguageModel {
        NormalizingModel(base: self)
    }
}

/// The wrapper `normalizingErrors()` returns. Kept next to the protocol because it
/// is part of the same one-obvious-surface story: it is how a streaming consumer
/// gets the error guarantee the collected path gets for free.
struct NormalizingModel<Base: LanguageModel>: LanguageModel {
    let base: Base

    var supportsWebSearch: Bool { base.supportsWebSearch }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in base.stream(request) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: KBLLMError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
