import Foundation
import KBLLM

// The OpenAI Responses wire translation, in three files that read as one, split the way `OpenAIModel` is: the model
// here, request shaping in `OpenAIResponsesModel+Request.swift`, and the streaming grammar and neutral event mapping in
// `OpenAIResponsesStreamParser.swift`. It is a sibling of `OpenAIModel`, not a mode of it: OpenAI's current models
// call functions only through `POST /v1/responses` (Chat Completions refuses tools on them unless reasoning is off),
// while the OpenAI-compatible servers (DeepSeek, Groq, OpenRouter, Ollama, LM Studio) speak only Chat Completions, so
// each wire keeps its own adapter. The schema translation, argument validation and redaction are `OpenAIModel`'s,
// shared rather than copied.
//
// Verified 2026-11-05 against the official reference (developers.openai.com/api/reference/resources/responses: the
// create method and the streaming events) and the reasoning and function-calling guides: the request fields
// (`instructions`, `input` items, flat function tools, `max_output_tokens`, `reasoning.effort` and `.summary`,
// `store`, `include`, `prompt_cache_key`, `text.format`), the `reasoning` item (`id`, `summary[].text`,
// `encrypted_content`, to be taken from `response.output_item.done`, since the one in `.added` may be incomplete),
// the usage fields (`input_tokens`, `input_tokens_details.cached_tokens` and `.cache_write_tokens`,
// `output_tokens`), `incomplete_details.reason`, and the event grammar `OpenAIResponsesParser` reads.

/// A `LanguageModel` over the OpenAI Responses streaming API (`POST {baseURL}/responses`). It fetches its key by the
/// caller-supplied `credentialKey`, builds one `HTTPRequestSpec`, opens a byte stream on the transport, parses the
/// bytes with the core SSE parser, and emits neutral `ModelEvent`s. It implements only `stream`; the collected path
/// is derived in the core.
///
/// Every request is stateless (`store: false`): the conversation travels in full each time, as it does on every other
/// adapter, and each reasoning item comes back encrypted, as a `.reasoningBlock(.openAIReasoning…)`, for the caller to
/// keep on the turn's `Message.reasoningBlocks`. They go back on later requests ahead of that turn's output, which is
/// how OpenAI carries a model's reasoning across a tool loop.
public struct OpenAIResponsesModel: LanguageModel {
    private let model: String
    private let credentialKey: String
    private let baseURL: String
    private let extraHeaders: [String: String]
    private let options: Options
    private let transport: any HTTPTransport
    private let credentials: any CredentialStore

    /// How hard a reasoning model thinks before answering: `reasoning.effort`, with the values the reference lists.
    /// Its own enum rather than `OpenAIModel.ReasoningEffort`, which lacks `minimal` and serves servers that know
    /// other sets; a case added there would also break a caller's exhaustive switch for a value only this wire has.
    /// Not every model takes every value (the reasoning guide lists which), and a model refuses one it does not take.
    public enum ReasoningEffort: String, Sendable, Hashable, CaseIterable {
        case none
        case minimal
        case low
        case medium
        case high
        case xhigh
        case max
    }

    /// Which reasoning summary to ask for (`reasoning.summary`), streamed as `.reasoningDelta`. OpenAI never shows the
    /// raw reasoning; without a summary a reasoning model streams none and looks like a hang before its answer.
    /// `auto` is the most detailed summarizer the model has.
    public enum ReasoningSummary: String, Sendable, Hashable, CaseIterable {
        case auto
        case concise
        case detailed
    }

    /// The Responses-only settings, bundled so the initializer keeps the shape of `OpenAIModel`'s.
    public struct Options: Sendable, Hashable {
        /// Sent as `reasoning.effort` when set, omitted when nil so the model's own default holds.
        public var reasoningEffort: ReasoningEffort?
        /// Sent as `reasoning.summary` when set, omitted when nil (no summary, so no `.reasoningDelta`).
        public var reasoningSummary: ReasoningSummary?
        /// Sent as `prompt_cache_key` when set and not empty, as `OpenAIModel(promptCacheKey:)` is: one stable value
        /// per conversation, never anything personal.
        public var promptCacheKey: String?

        public init(
            reasoningEffort: ReasoningEffort? = nil,
            reasoningSummary: ReasoningSummary? = nil,
            promptCacheKey: String? = nil
        ) {
            self.reasoningEffort = reasoningEffort
            self.reasoningSummary = reasoningSummary
            self.promptCacheKey = promptCacheKey.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Neither `model` nor `credentialKey` is defaulted, for the reason `OpenAIModel`'s are not.
    /// - Parameter baseURL: the API root INCLUDING the version segment, to which `/responses` is appended.
    /// - Parameter extraHeaders: additional headers sent with every request; the Authorization and content-type
    ///   headers this adapter sets itself always win, in any letter case, so a caller cannot accidentally replace
    ///   the credential it just supplied. An empty secret from the store sends no Authorization header (a keyless
    ///   server, or one that takes its key in a header the caller passes here), as on `OpenAIModel`.
    /// - Parameter reasoningEffort: `reasoning.effort`, omitted when nil.
    /// - Parameter reasoningSummary: `reasoning.summary`, omitted when nil.
    /// - Parameter promptCacheKey: `prompt_cache_key`, omitted when nil or empty.
    public init(
        model: String,
        credentialKey: String,
        baseURL: String = "https://api.openai.com/v1",
        extraHeaders: [String: String] = [:],
        reasoningEffort: ReasoningEffort? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        promptCacheKey: String? = nil,
        transport: any HTTPTransport,
        credentials: any CredentialStore
    ) {
        self.model = model
        self.credentialKey = credentialKey
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.options = Options(
            reasoningEffort: reasoningEffort, reasoningSummary: reasoningSummary, promptCacheKey: promptCacheKey
        )
        self.transport = transport
        self.credentials = credentials
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let model = self.model
        let credentialKey = self.credentialKey
        let baseURL = self.baseURL
        let extraHeaders = self.extraHeaders
        let options = self.options
        let transport = self.transport
        let credentials = self.credentials
        return AsyncThrowingStream { continuation in
            let task = Task {
                // The endpoint is validated first, as `OpenAIModel` does, so a malformed base fails as
                // `.invalidRequest` without opening the transport and the `.transport` catch names the URL used.
                let endpoint: String
                do {
                    endpoint = try AdapterPlumbing.composeEndpoint(base: baseURL, suffix: Self.pathSuffix)
                } catch {
                    continuation.finish(throwing: KBLLMError.from(error))
                    return
                }
                var secret: String?
                do {
                    let key = try await credentials.resolvedSecret(forKey: credentialKey)
                    secret = key
                    let spec = try Self.buildRequest(
                        request, model: model, secret: key, endpoint: endpoint,
                        extraHeaders: extraHeaders, options: options
                    )
                    try await Self.drain(spec, schema: request.responseSchema, transport: transport) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch let error as KBLLMError {
                    continuation.finish(throwing: error)
                } catch {
                    // A foreign transport failure is reachability; the secret is redacted in case the host stitched
                    // it into the message.
                    let underlying = AdapterPlumbing.redact(String(describing: error), secret: secret)
                    continuation.finish(throwing: KBLLMError.transport(url: endpoint, underlying: underlying))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Open the stream and forward its neutral events. A structured request's terminal is withheld until the collected
    /// document is validated, and a 2xx that yields no usable event (a 200 whose body is an error object) fails as
    /// `.decoding` naming a fragment of what arrived, both exactly as on `OpenAIModel`.
    private static func drain(
        _ spec: HTTPRequestSpec,
        schema: JSONSchema?,
        transport: any HTTPTransport,
        emit: (ModelEvent) -> Void
    ) async throws {
        let body = BodyPrefix()
        var parser = OpenAIResponsesParser()
        var structured = StructuredCollector(schema: schema)
        var eventCount = 0
        for try await frame in SSE.events(from: tapping(transport.openBytes(spec), into: body)) {
            for event in try parser.consume(frame) {
                eventCount += 1
                if let forwarded = structured.absorb(event) { emit(forwarded) }
            }
        }
        if eventCount == 0 {
            throw KBLLMError.decoding(expected: "a usable OpenAI Responses stream", fragment: body.fragment)
        }
        if let terminal = try structured.finish() { emit(terminal) }
    }

    /// The fixed provider path appended onto the caller's base URL.
    private static let pathSuffix = "/responses"
}
