import Foundation
import KBLLM

// The Anthropic wire translation. This file holds the adapter and its call loop; the rest
// reads as one with it, split by subject only to stay within the house length limits:
// request shaping in `AnthropicModel+Request.swift`, the streaming Messages grammar and the
// neutral event mapping in `AnthropicResponseParser.swift` (its web search half in
// `+WebSearch`), the decoded frame shapes in `AnthropicFrame.swift`, and the raw record of a
// turn that a `pause_turn` continuation echoes in `AnthropicTurnRecorder.swift`. The adapter
// talks only to the injected `HTTPTransport` and `CredentialStore` seams; it owns no
// networking type.

/// A `LanguageModel` over the Anthropic Messages streaming API. It fetches its key by the
/// caller-supplied `credentialKey`, builds one `HTTPRequestSpec`, opens a byte stream on
/// the transport, parses the bytes with the core SSE parser, and emits neutral
/// `ModelEvent`s. It implements only `stream`; the collected path is derived in the core.
///
/// It supports server-side web search (`ModelRequest.webSearch`): the API runs the searches
/// inside the call and this adapter surfaces them as `webSearchCall`, `webSearchResult` and
/// `citation` events. A long search turn the API pauses (`pause_turn`) is continued
/// automatically, so the caller sees one merged response.
///
/// Request shapes follow the model id. Structured output (`ModelRequest.responseSchema`) rides
/// `output_config.format` on 4.5 and later models; older or unrecognised ids get a strict tool
/// offered with `tool_choice: auto`, never a forced choice. Web search sends
/// `web_search_20260209` to Sonnet and Opus 4.6 and later, `web_search_20250305` otherwise.
/// Sampling hints (`temperature`, `topP`) are dropped where the model rejects them: neither on
/// Opus 4.7+ and 5.x, at most one (temperature preferred) on 4.x newer than 4.1.
public struct AnthropicModel: LanguageModel {
    private let model: String
    private let credentialKey: String
    private let baseURL: String
    private let promptCaching: AnthropicPromptCaching
    private let thinking: AnthropicThinking?
    private let effort: AnthropicEffort?
    private let transport: any HTTPTransport
    private let credentials: any CredentialStore

    /// Neither `model` nor `credentialKey` is defaulted: the adapter never picks a model or
    /// a secret for the caller, so a caller cannot accidentally ship the wrong one. `baseURL`
    /// IS defaulted to the public origin, so the common case stays a one-liner while a proxy
    /// or a gateway is a single argument.
    /// - Parameter baseURL: the server root, to which `/v1/messages` is appended. Note this
    ///   differs from `OpenAIModel`, whose base already ENDS in `/v1`, because each adapter
    ///   follows its own provider's documented base. Pointing both at one local server that
    ///   speaks both formats therefore needs two different strings: LM Studio wants
    ///   `http://localhost:1234` here and `http://localhost:1234/v1` there. Passing the
    ///   OpenAI-shaped base to this initializer requests `/v1/v1/messages` and fails.
    /// - Parameter promptCaching: where Anthropic's prompt-cache breakpoints go (see
    ///   `AnthropicPromptCaching`). Off by default because it is not free to get wrong: a cache
    ///   entry is written on the first call and read by later ones only while the prefix is
    ///   byte-identical, so a prompt that varies per call pays for writes it never reads back.
    ///   `.systemPrompt` suits a long, stable prompt sent with a different question each time;
    ///   `.conversation` suits an agent loop or a chat, where each request repeats the last and
    ///   adds to it. Those are cases a caller can recognize and this adapter cannot. It is an
    ///   adapter-level knob rather than a field on `ModelRequest` because no other provider has
    ///   this concept, and a neutral request must not carry one provider's vocabulary. Whether it
    ///   paid off is visible in `TokenUsage.cacheReadTokens`.
    /// - Parameter thinking: the `thinking` field, or nil (the default) for none, so the model's own default holds.
    ///   Each thinking block the model returns, signed, is emitted as a `.reasoningBlock` and sent back with its turn
    ///   (`Message.reasoningBlocks`) whatever this is.
    /// - Parameter effort: `output_config.effort`, or nil (the default) for the model's own.
    public init(
        model: String,
        credentialKey: String,
        baseURL: String = "https://api.anthropic.com",
        promptCaching: AnthropicPromptCaching = .off,
        thinking: AnthropicThinking? = nil,
        effort: AnthropicEffort? = nil,
        transport: any HTTPTransport,
        credentials: any CredentialStore
    ) {
        self.model = model
        self.credentialKey = credentialKey
        self.baseURL = baseURL
        self.promptCaching = promptCaching
        self.thinking = thinking
        self.effort = effort
        self.transport = transport
        self.credentials = credentials
    }

    /// True: the Messages API runs web search as a server tool.
    public var supportsWebSearch: Bool { true }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let model = self.model
        let credentialKey = self.credentialKey
        let baseURL = self.baseURL
        let promptCaching = self.promptCaching
        let reasoning = AnthropicReasoningSettings(thinking: thinking, effort: effort)
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

                    // A structured answer arrives as text on the structured-outputs route, or, on
                    // the legacy route, as the `structuredToolName` tool's input, which the parser
                    // converts to content (never a `.toolCall`). Either way the terminal
                    // `.completed` is withheld until the collected document is validated.
                    let structuredTool = Self.usesStructuredTool(request, profile: AnthropicModelProfile(model))
                    var structured = StructuredCollector(schema: request.responseSchema)
                    // The paused assistant turn so far, echoed on each continuation, and how many
                    // continuations have been sent. Without search there is never a pause, so
                    // this loop runs exactly once.
                    var pausedTurn = PausedTurn()
                    var continuations = 0
                    var parser = AnthropicResponseParser(
                        structuredToolName: structuredTool ? Self.structuredToolName : nil,
                        mayContinue: Self.maxPauseContinuations > 0
                    )
                    while true {
                        // Throw site 2: building the provider body (`.invalidRequest`).
                        let spec = try Self.buildRequest(
                            request,
                            model: model,
                            secret: key,
                            endpoint: endpoint,
                            promptCaching: promptCaching,
                            reasoning: reasoning,
                            pausedTurn: pausedTurn
                        )
                        // Throw sites 3 (transport reachability), 4 (`.httpStatus` from the
                        // host), and 5 (`.decoding`) all surface while draining this stream. The
                        // raw body is tapped so a 2xx drain that produces no usable event can
                        // name a fragment of what it actually received.
                        let body = BodyPrefix()
                        var eventCount = 0
                        for try await frame in SSE.events(from: tapping(transport.openBytes(spec), into: body)) {
                            for event in try parser.consume(frame) {
                                eventCount += 1
                                if let forwarded = structured.absorb(event) {
                                    continuation.yield(forwarded)
                                }
                            }
                        }
                        if eventCount == 0, !parser.continuesAfterPause {
                            // A 2xx that yielded no usable event is the observed unknown-path
                            // case (a 200 whose body is an error object, not a stream). Fail
                            // loudly so a misconfigured base URL is not mistaken for a model
                            // that said nothing.
                            throw KBLLMError.decoding(
                                expected: "a usable Anthropic Messages stream",
                                fragment: body.fragment
                            )
                        }
                        // A consumer that has gone away gets no further billed continuation.
                        guard parser.continuesAfterPause, !Task.isCancelled else { break }
                        // `pause_turn`: send the turn back exactly as received so the API resumes
                        // it. The next parser carries the merged response's length and usage, and
                        // the cap's last continuation may not continue again, which ends the
                        // stream as `.paused` rather than looping or truncating silently.
                        pausedTurn.append(parser)
                        continuations += 1
                        parser = AnthropicResponseParser(
                            structuredToolName: parser.structuredToolName,
                            mayContinue: continuations < Self.maxPauseContinuations,
                            contentOffset: parser.contentLength,
                            priorUsage: parser.totalUsage
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

    /// The fixed provider path appended onto the caller's base URL to reach Messages.
    private static let pathSuffix = "/v1/messages"

    /// The `max_tokens` used ONLY when the caller supplied none. Anthropic rejects a request
    /// with no `max_tokens`, so a value must be sent; this one is chosen deliberately to sit
    /// comfortably above the old fixed value so ordinary work is not truncated, while staying
    /// within current Anthropic model output limits. It is a fallback for the absent case, not
    /// a cap: a caller value always reaches the wire unchanged.
    static let maxOutputTokensFallback = 4096

    /// How many times one call continues a `pause_turn` before it stops and reports `.paused`.
    /// A pause is the API cutting a long search turn into pieces, so a few continuations finish
    /// any ordinary research turn; the cap exists so a turn that keeps pausing cannot keep
    /// spending searches and tokens without end. Each continuation is a separate billed call.
    static let maxPauseContinuations = 5

    /// The name of the single synthetic tool a structured request injects on the LEGACY route
    /// (a model older than structured outputs, or one this adapter cannot place). The schema
    /// rides as this tool's `input_schema`, offered with `tool_choice: auto`, and the answer
    /// arrives as a `tool_use` block with this name, which the response path converts BACK into
    /// ordinary content. Current models use `output_config.format` instead and never see it.
    /// Internal (not public) so the closed public surface is unchanged, yet a `@testable` test
    /// can key its fixture's block name to this exact value.
    static let structuredToolName = "structured_response"

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

    /// Replace any occurrence of the secret with a fixed marker so a host-supplied error
    /// message can never smuggle the key into a `.transport` value.
    private static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
    }
}

/// Retains a bounded prefix of a byte stream so the adapter can name a fragment of the raw
/// body when a 2xx drain yields zero usable events (the observed unknown-path case: a 200
/// whose body is an error object, not an event stream). Reference-typed and lock-guarded so
/// the tapping task and the draining task share one buffer safely.
private final class BodyPrefix: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private let limit = 512

    func append(_ byte: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        if bytes.count < limit { bytes.append(byte) }
    }

    var fragment: String {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

/// Forward a byte stream unchanged while retaining a bounded prefix in `prefix`, so the SSE
/// parser sees an ordinary byte sequence and the adapter can still describe the raw body if
/// the drain produced nothing usable. A free function so the drain loop reads as one line.
private func tapping(
    _ upstream: AsyncThrowingStream<UInt8, any Error>,
    into prefix: BodyPrefix
) -> AsyncThrowingStream<UInt8, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await byte in upstream {
                    prefix.append(byte)
                    continuation.yield(byte)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
