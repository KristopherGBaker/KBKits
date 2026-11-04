import Foundation
import KBLLM

// The OpenAI wire translation, in three files that read as one: the model here, request
// shaping in `OpenAIModel+Request.swift`, and the streaming grammar and neutral event mapping
// in `OpenAIStreamParser.swift`. It was one
// file, matching the Anthropic adapter, until usage reporting pushed it past the house
// file-length limit; the split falls on the seam that was already there, since the parser
// touches neither the transport nor the credential store. The adapter talks only to the
// injected `HTTPTransport` and `CredentialStore` seams; it owns no networking type.

/// A `LanguageModel` over the OpenAI Chat Completions streaming API. It fetches its key by
/// the caller-supplied `credentialKey`, builds one `HTTPRequestSpec`, opens a byte stream
/// on the transport, parses the bytes with the core SSE parser, and emits neutral
/// `ModelEvent`s. It implements only `stream`; the collected path is derived in the core.
public struct OpenAIModel: LanguageModel {
    private let model: String
    private let credentialKey: String
    private let baseURL: String
    private let extraHeaders: [String: String]
    private let reasoningEffort: ReasoningEffort?
    private let outputTokenField: OutputTokenField
    private let promptCacheKey: String?
    private let replaysReasoning: Bool
    private let thinking: ThinkingSwitch?
    private let transport: any HTTPTransport
    private let credentials: any CredentialStore

    /// How hard a reasoning model should think before answering.
    ///
    /// An adapter-level knob for the same reason `AnthropicModel`'s `promptCaching` is one: no
    /// other provider has the concept, and a neutral `ModelRequest` must not carry one vendor's
    /// vocabulary. `none` is the case that earns this its place, because some reasoning models
    /// refuse FUNCTION TOOLS on Chat Completions unless reasoning is off, answering a tool-using
    /// request with "use /v1/responses or set reasoning_effort to 'none'".
    public enum ReasoningEffort: String, Sendable, Hashable, CaseIterable {
        case none
        case low
        case medium
        case high
        /// Above `high`, on the models that take it (DeepSeek maps it to `high`).
        case xhigh
        /// The most, on the models that take it (DeepSeek's highest).
        case max
    }

    /// The `thinking: {type: "enabled" | "disabled"}` switch some OpenAI-compatible providers take beside
    /// `reasoning_effort` (DeepSeek, whose thinking is on by default, Z.ai). OpenAI itself does not: it turns reasoning
    /// down with `reasoning_effort` alone.
    public enum ThinkingSwitch: String, Sendable, Hashable, CaseIterable {
        case enabled
        case disabled
    }

    /// Which field carries the output-token limit.
    ///
    /// OpenAI renamed `max_tokens` to `max_completion_tokens` on Chat Completions, and the
    /// newer models REJECT the old name outright rather than ignoring it: the request comes
    /// back 400 with `unsupported_parameter`. The older models, and several
    /// OpenAI-compatible servers, only understand the old one. There is no name that works
    /// everywhere, so this is a caller's choice like `reasoningEffort` and
    /// `promptCaching` before it.
    ///
    /// It defaults to `.maxTokens`, which is what this adapter has always sent, so no
    /// existing caller changes behaviour by upgrading.
    public enum OutputTokenField: String, Sendable, Hashable, CaseIterable {
        /// `max_tokens`. Older OpenAI models, LM Studio, Ollama, vLLM.
        case maxTokens = "max_tokens"
        /// `max_completion_tokens`. Required by OpenAI's newer models.
        case maxCompletionTokens = "max_completion_tokens"
    }

    /// Neither `model` nor `credentialKey` is defaulted: the adapter never picks a model or
    /// a secret for the caller, so a caller cannot accidentally ship the wrong one. `baseURL`
    /// IS defaulted to the public origin, so the common case stays a one-liner while pointing
    /// at LM Studio/Ollama/vLLM (which speak this same wire format) is a single argument.
    /// - Parameter baseURL: the API root INCLUDING the version segment, to which
    ///   `/chat/completions` is appended. Note this differs from `AnthropicModel`, whose base
    ///   excludes the version, because each adapter follows its own provider's documented
    ///   base. For LM Studio, Ollama, or vLLM that means `http://localhost:1234/v1` here and
    ///   `http://localhost:1234` there.
    /// - Parameter extraHeaders: additional headers sent with every request. The
    ///   OpenAI-compatible endpoints differ in what they want beyond the wire format itself
    ///   (OpenRouter attributes traffic by `HTTP-Referer` and `X-Title`), and inventing a
    ///   named option per host would make this adapter grow one field per vendor. The
    ///   Authorization and content-type headers this adapter sets itself always win, in any
    ///   letter case, so a caller cannot accidentally replace the credential it just supplied.
    ///   An empty secret from the store sends no Authorization header (a keyless server, or one
    ///   that takes its key in a header the caller passes here).
    /// - Parameter reasoningEffort: sent as `reasoning_effort` when set, and omitted entirely
    ///   when nil so the model's own default holds. Set it to `.none` to use function tools with
    ///   a reasoning model on Chat Completions; leave it nil for a model that does not take the
    ///   parameter at all, which will reject an unknown field rather than ignore it.
    /// - Parameter outputTokenField: which field carries `GenerationOptions.maxOutputTokens`.
    ///   Defaults to `max_tokens`, the name this adapter has always sent. Set it to
    ///   `.maxCompletionTokens` for OpenAI's newer models, which reject the old name with a
    ///   400 rather than ignoring it.
    /// - Parameter promptCacheKey: sent as `prompt_cache_key` when set (and not empty), omitted
    ///   when nil, which is the default, so a caller that never sets it sends exactly the body it
    ///   always did. OpenAI caches prompts automatically; the key routes requests that share a
    ///   prefix to the same cache, which raises the hit rate on the models before GPT-5.6, and
    ///   from GPT-5.6 it groups their cache accounting. Pass one stable value per conversation,
    ///   never anything personal (a name, a key, the content). An OpenAI-compatible server that
    ///   does not know the field may refuse it, so leave it nil there.
    /// - Parameter replaysReasoning: when true, each assistant message's `Message.reasoning` (when not empty) is sent
    ///   back as `reasoning_content` on its wire message. DeepSeek's thinking mode REQUIRES it: once a request has
    ///   tools, every later request must carry each earlier assistant message's `reasoning_content`, or it is refused
    ///   with a 400 (without tools it is ignored). Off by default, so a caller that never sets it sends exactly the
    ///   body it always did: a strict OpenAI-compatible server may refuse a message key it does not know. Never sent on
    ///   a user, system or tool message.
    /// - Parameter thinking: sent as `thinking: {type: …}` when set, omitted when nil (the default), so a server that
    ///   does not know the field is never sent it.
    public init(
        model: String,
        credentialKey: String,
        baseURL: String = "https://api.openai.com/v1",
        extraHeaders: [String: String] = [:],
        reasoningEffort: ReasoningEffort? = nil,
        outputTokenField: OutputTokenField = .maxTokens,
        promptCacheKey: String? = nil,
        replaysReasoning: Bool = false,
        thinking: ThinkingSwitch? = nil,
        transport: any HTTPTransport,
        credentials: any CredentialStore
    ) {
        self.model = model
        self.credentialKey = credentialKey
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.reasoningEffort = reasoningEffort
        self.outputTokenField = outputTokenField
        self.promptCacheKey = promptCacheKey.flatMap { $0.isEmpty ? nil : $0 }
        self.replaysReasoning = replaysReasoning
        self.thinking = thinking
        self.transport = transport
        self.credentials = credentials
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let model = self.model
        let credentialKey = self.credentialKey
        let baseURL = self.baseURL
        let extraHeaders = self.extraHeaders
        let reasoningEffort = self.reasoningEffort
        let outputTokenField = self.outputTokenField
        let promptCacheKey = self.promptCacheKey
        let replaysReasoning = self.replaysReasoning
        let thinking = self.thinking
        let transport = self.transport
        let credentials = self.credentials
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Compose and validate the endpoint BEFORE anything else: a malformed base
                // URL must fail as `.invalidRequest` without ever opening the transport, and
                // `endpoint` must be in scope for the `.transport` catch to report the exact
                // URL actually used, not the default.
                let endpoint: String
                do {
                    endpoint = try Self.composeEndpoint(baseURL)
                } catch {
                    continuation.finish(throwing: KBLLMError.from(error))
                    return
                }
                // `secret` is captured so a foreign transport error carrying it in its
                // message can be redacted before it reaches a `.transport` value.
                var secret: String?
                do {
                    let key: String
                    do {
                        key = try await credentials.secret(forKey: credentialKey)
                    } catch {
                        // Throw site 1: the store could not supply the key. The caller's
                        // key names what to configure; the store's raw error never escapes.
                        throw KBLLMError.missingCredential(key: credentialKey)
                    }
                    secret = key

                    // Throw site 2: building the provider body (`.invalidRequest`).
                    let spec = try Self.buildRequest(
                        request,
                        model: model,
                        secret: key,
                        endpoint: endpoint,
                        extraHeaders: extraHeaders,
                        reasoningEffort: reasoningEffort,
                        outputTokenField: outputTokenField,
                        promptCacheKey: promptCacheKey,
                        replaysReasoning: replaysReasoning,
                        thinking: thinking
                    )

                    // Throw sites 3 (transport reachability), 4 (`.httpStatus` from the
                    // host), and 5 (`.decoding`) all surface while draining this stream. The
                    // raw body is tapped so a 2xx drain that produces no usable event can name
                    // a fragment of what it actually received.
                    let body = BodyPrefix()
                    var parser = OpenAIResponseParser()
                    var eventCount = 0
                    // In structured mode the terminal `.completed` is WITHHELD until the collected
                    // document is validated: a structured answer that does not conform must fail,
                    // not slip through as a successful `.stop`. Deltas still stream as they arrive;
                    // only the terminal differs.
                    let schema = request.responseSchema
                    var structured = StructuredCollector(schema: schema)
                    for try await frame in SSE.events(from: tapping(transport.openBytes(spec), into: body)) {
                        for event in try parser.consume(frame) {
                            eventCount += 1
                            if let forwarded = structured.absorb(event) {
                                continuation.yield(forwarded)
                            }
                        }
                    }
                    // The terminal was withheld inside the parser so usage (which OpenAI sends
                    // in a frame AFTER `finish_reason`) can precede it. These count toward
                    // `eventCount` exactly as they did when emitted inline, so a model that
                    // answers with nothing but a stop reason is still a successful empty answer
                    // rather than the no-usable-event failure below.
                    for event in parser.flushTerminal() {
                        eventCount += 1
                        if let forwarded = structured.absorb(event) {
                            continuation.yield(forwarded)
                        }
                    }
                    if eventCount == 0 {
                        // A 2xx that yielded no usable event is the observed unknown-path case
                        // (a 200 whose body is an error object, not a stream). Fail loudly so a
                        // misconfigured base URL is not mistaken for a model that said nothing.
                        throw KBLLMError.decoding(
                            expected: "a usable OpenAI chat.completion stream",
                            fragment: body.fragment
                        )
                    }
                    // On a structured request this throws `.schemaViolation` when the collected
                    // document does not conform, and otherwise yields the withheld terminal.
                    if let terminal = try structured.finish() {
                        continuation.yield(terminal)
                    }
                    continuation.finish()
                } catch let error as KBLLMError {
                    // A typed error (`.missingCredential`, `.invalidRequest`, a host
                    // `.httpStatus`, or a `.decoding`) passes through untouched.
                    continuation.finish(throwing: error)
                } catch {
                    // A foreign transport failure is reachability. Redact the secret in case
                    // the host stitched it into the underlying message.
                    let underlying = Self.redact(String(describing: error), secret: secret)
                    continuation.finish(throwing: KBLLMError.transport(url: endpoint, underlying: underlying))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The fixed provider path appended onto the caller's base URL to reach Chat Completions.
    private static let pathSuffix = "/chat/completions"

    /// The `json_schema.name` a structured request carries. OpenAI requires the block to be
    /// named; the value is not otherwise significant, so one stable label serves every request.
    static let structuredSchemaName = "structured_response"

    /// Compose the endpoint from the base URL and validate it. A base that cannot form a
    /// valid URL is rejected as `.invalidRequest` naming the base, rather than concatenated
    /// into a broken request the transport would fail on opaquely.
    private static func composeEndpoint(_ baseURL: String) throws -> String {
        let endpoint = baseURL + pathSuffix
        guard URL(string: endpoint) != nil else {
            throw KBLLMError.invalidRequest(field: "baseURL", reason: "malformed base URL: \(baseURL)")
        }
        return endpoint
    }

}
