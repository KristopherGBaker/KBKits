import Foundation
import KBLLM

// The second half of the OpenAI wire translation (see `OpenAIModel.swift`): the Chat
// Completions streaming grammar and its mapping onto neutral events. Nothing here knows
// about transports, credentials, or request shaping.
//
// These types are module-internal rather than `private` only because `private` in Swift is
// FILE-scoped, so the split that satisfied the file-length limit necessarily widened them.
// Nothing outside this target can see them: no product vends this module's internals.

/// Accumulates Chat Completions streaming chunks into neutral events. Tool arguments arrive
/// as `function.arguments` fragments keyed by `index`, possibly interleaved across parallel
/// calls, so fragments are joined per index and one `.toolCall` with complete JSON is
/// emitted per call when `finish_reason` arrives. File scope, not nested, to stay within
/// the house nesting limit.
struct OpenAIResponseParser {
    private var toolCalls: [Int: ToolAccumulator] = [:]
    private var order: [Int] = []
    private var finishReason: FinishReason = .stop
    /// The terminal is WITHHELD when `finish_reason` arrives, because OpenAI reports usage in
    /// a frame that comes AFTER it. Emitting `.completed` on sight would put usage after the
    /// event a streaming consumer is entitled to treat as the end of the call.
    private var pendingTerminal: FinishReason?
    private var pendingUsage: TokenUsage?

    struct ToolAccumulator {
        var id: String
        var name: String
        var arguments: String
        /// The call's `extra_content` (Gemini's thought signature), as JSON text, when the server sent one.
        var extra: String?
    }

    mutating func consume(_ frame: SSEEvent) throws -> [ModelEvent] {
        let payload = frame.data
        // The Chat Completions stream terminates with a literal `[DONE]` sentinel, which is
        // not JSON and carries no event.
        if payload == "[DONE]" { return [] }
        let decoded: OpenAIFrame
        do {
            decoded = try Self.decoder.decode(OpenAIFrame.self, from: Data(payload.utf8))
        } catch {
            throw KBLLMError.decoding(expected: "an OpenAI chat.completion.chunk", fragment: payload)
        }
        // The usage frame carries an EMPTY `choices` array, so it must be read before the
        // guard below rather than after it.
        if let usage = decoded.usage {
            pendingUsage = TokenUsage(
                // `prompt_tokens` as reported: it INCLUDES the cache reads and writes below
                // (OpenAI's own example bills `input - cached - writes` as ordinary input), so a
                // caller pricing them takes both out of it rather than adding them again.
                inputTokens: usage.promptTokens ?? 0,
                outputTokens: usage.completionTokens ?? 0,
                // Both are nested details of `prompt_tokens`. `cached_tokens` counts billed reads
                // only; `cache_write_tokens` is reported by the models that bill writes (GPT-5.6
                // and later, at 1.25x input) and absent before them, which reads as 0 writes.
                // DeepSeek reports its disk-cache hits as `prompt_cache_hit_tokens` (with
                // `prompt_tokens` = hits + misses, the same "input includes cache reads" meaning),
                // and also as `cached_tokens`; the top-level field is the fallback for a server
                // that sends only it. Either way it is read once, never added to the other.
                cacheReadTokens: usage.promptTokensDetails?.cachedTokens ?? usage.promptCacheHitTokens ?? 0,
                cacheWriteTokens: usage.promptTokensDetails?.cacheWriteTokens ?? 0,
                reportedCostUSD: usage.cost
            )
        }
        guard let choice = decoded.choices?.first else { return [] }
        var events: [ModelEvent] = []
        // Reasoning (`delta.reasoning_content`, streamed by LM Studio and DeepSeek) maps to
        // the neutral `.reasoningDelta` BEFORE any answer content, so a caller sees the model
        // thinking rather than a silence. It is never folded into `.contentDelta`.
        if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let content = choice.delta?.content, !content.isEmpty {
            events.append(.contentDelta(content))
        }
        accumulate(choice.delta?.toolCalls)
        accumulateExtras(payload)
        if let reason = choice.finishReason {
            events.append(contentsOf: flush(reason))
        }
        return events
    }

    private mutating func accumulate(_ deltas: [OpenAIFrame.ToolCallDelta]?) {
        guard let deltas else { return }
        for delta in deltas {
            if toolCalls[delta.index] == nil {
                toolCalls[delta.index] = ToolAccumulator(id: "", name: "", arguments: "")
                order.append(delta.index)
            }
            if let id = delta.id { toolCalls[delta.index]?.id = id }
            if let name = delta.function?.name { toolCalls[delta.index]?.name = name }
            if let arguments = delta.function?.arguments { toolCalls[delta.index]?.arguments += arguments }
        }
    }

    /// Each tool call delta's `extra_content` (Gemini's thought signature), read from the raw frame: the typed decoder
    /// converts snake-case keys at every depth, and these must go back exactly as they came.
    private mutating func accumulateExtras(_ payload: String) {
        guard payload.contains("\"extra_content\""),
              let frame = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choice = (frame["choices"] as? [[String: Any]])?.first,
              let calls = (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] else { return }
        for call in calls {
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            guard let index = call["index"] as? Int, let extra = call["extra_content"], toolCalls[index] != nil,
                  let data = try? JSONSerialization.data(withJSONObject: extra, options: options) else { continue }
            toolCalls[index]?.extra = String(bytes: data, encoding: .utf8)
        }
    }

    private mutating func flush(_ reason: String) -> [ModelEvent] {
        var events: [ModelEvent] = []
        for index in order {
            guard let accumulator = toolCalls[index] else { continue }
            // Before its call, so a caller keeping blocks has it when the turn goes back.
            if let extra = accumulator.extra, !accumulator.id.isEmpty {
                events.append(.reasoningBlock(.toolCallExtra(callID: accumulator.id, json: extra)))
            }
            events.append(.toolCall(ToolCallRecord(
                id: accumulator.id,
                name: accumulator.name,
                arguments: Data(accumulator.arguments.utf8)
            )))
        }
        toolCalls.removeAll()
        order.removeAll()
        pendingTerminal = Self.mapFinishReason(reason)
        return events
    }

    /// The end-of-stream flush: the usage frame, if the server sent one, then the withheld
    /// terminal. Returns nothing when no `finish_reason` was ever seen, so a truncated stream
    /// does not get a fabricated ending.
    mutating func flushTerminal() -> [ModelEvent] {
        guard let terminal = pendingTerminal else { return [] }
        pendingTerminal = nil
        var events: [ModelEvent] = []
        if let usage = pendingUsage {
            pendingUsage = nil
            events.append(.usage(usage))
        }
        events.append(.completed(terminal))
        return events
    }

    private static func mapFinishReason(_ reason: String) -> FinishReason {
        switch reason {
        case "tool_calls": .toolCalls
        case "length": .length
        case "content_filter": .contentFilter
        default: .stop
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// The subset of a Chat Completions streaming chunk the adapter reads. Snake-case wire keys
/// (`tool_calls`, `finish_reason`) map to these camel-case fields.
struct OpenAIFrame: Decodable {
    let choices: [Choice]?
    let usage: Usage?

    /// Present only on the final frame, and only when `stream_options.include_usage` was
    /// requested. Every field is optional because a server may report a subset.
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptTokensDetails?
        /// DeepSeek's `prompt_cache_hit_tokens`: the part of `prompt_tokens` read from its context cache.
        let promptCacheHitTokens: Int?
        /// What the call cost in US dollars, sent by some OpenAI-compatible providers
        /// (OpenRouter's `usage.cost`); OpenAI itself does not send it.
        let cost: Double?
    }

    /// A sibling of `Usage` rather than nested inside it, to stay within the house nesting
    /// limit; on the wire it is `usage.prompt_tokens_details`.
    struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?
        /// `cache_write_tokens`: "the unadjusted number of prompt tokens written to cache".
        let cacheWriteTokens: Int?
    }

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?
    }

    struct Delta: Decodable {
        let content: String?
        // `reasoning_content` via `convertFromSnakeCase`: the single reasoning wire form
        // this adapter promises, covered by the `openAIReasoning` fixture.
        let reasoningContent: String?
        let toolCalls: [ToolCallDelta]?
    }

    struct ToolCallDelta: Decodable {
        let index: Int
        let id: String?
        let function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }
}

/// Retains a bounded prefix of a byte stream so the adapter can name a fragment of the raw
/// body when a 2xx drain yields zero usable events (the observed unknown-path case: a 200
/// whose body is an error object, not an event stream). Reference-typed and lock-guarded so
/// the tapping task and the draining task share one buffer safely.
final class BodyPrefix: @unchecked Sendable {
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
func tapping(
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
