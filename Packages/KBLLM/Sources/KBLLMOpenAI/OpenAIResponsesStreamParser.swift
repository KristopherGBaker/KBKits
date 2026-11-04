import Foundation
import KBLLM

// The third part of the OpenAI Responses translation (see `OpenAIResponsesModel.swift`): the streaming event grammar
// and its mapping onto neutral events. Nothing here knows about transports, credentials, or request shaping. Module
// internal for the reason `OpenAIStreamParser.swift` gives.
//
// The events read, by `type` (every other type, such as `response.created`, `response.in_progress`,
// `response.content_part.added` and the built-in tool events, carries nothing a neutral event needs and is skipped):
//   response.output_text.delta              -> .contentDelta
//   response.refusal.delta                  -> .contentDelta, and the turn ends .contentFilter
//   response.reasoning_summary_part.added   -> a blank line between two summary parts
//   response.reasoning_summary_text.delta   -> .reasoningDelta
//   response.function_call_arguments.delta  -> kept by item, in case the finished item lacks its arguments
//   response.output_item.done               -> .toolCall for a `function_call`, .reasoningBlock for a `reasoning`
//   response.completed                      -> .usage, then .completed(.stop or .toolCalls)
//   response.incomplete                     -> .usage, then .completed(.length or .contentFilter)
//   response.failed, error                  -> a thrown `.httpStatus`

/// Maps Responses streaming events onto neutral events. A function call is emitted whole from its finished output
/// item, never from the argument deltas, so its arguments are complete JSON; the deltas are kept only as the fallback
/// for an item that arrives without them.
struct OpenAIResponsesParser {
    private var argumentsByItem: [String: String] = [:]
    private var sawToolCall = false
    private var refused = false

    mutating func consume(_ frame: SSEEvent) throws -> [ModelEvent] {
        let payload = frame.data
        if payload == "[DONE]" { return [] }
        let event: ResponsesEvent
        do {
            event = try Self.decoder.decode(ResponsesEvent.self, from: Data(payload.utf8))
        } catch {
            throw KBLLMError.decoding(expected: "an OpenAI Responses streaming event", fragment: payload)
        }
        if let streamed = streamed(event) { return streamed }
        return try ended(event)
    }

    /// The events that stream a part of the turn, or nil for any other type.
    private mutating func streamed(_ event: ResponsesEvent) -> [ModelEvent]? {
        switch event.type {
        case "response.output_text.delta":
            return text(event.delta)
        case "response.refusal.delta":
            refused = true
            return text(event.delta)
        case "response.reasoning_summary_part.added":
            // Each part is a paragraph of its own, so a reader of the concatenated deltas sees them apart.
            return (event.summaryIndex ?? 0) > 0 ? [.reasoningDelta("\n\n")] : []
        case "response.reasoning_summary_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [.reasoningDelta(delta)]
        case "response.function_call_arguments.delta":
            if let itemID = event.itemId { argumentsByItem[itemID, default: ""] += event.delta ?? "" }
            return []
        default:
            return nil
        }
    }

    /// The events that finish an output item or the response; every other type is skipped.
    private mutating func ended(_ event: ResponsesEvent) throws -> [ModelEvent] {
        switch event.type {
        case "response.output_item.done":
            guard let item = event.item else { return [] }
            return finished(item)
        case "response.completed":
            return terminal(event.response, reason: completedReason)
        case "response.incomplete":
            let cause = event.response?.incompleteDetails?.reason
            return terminal(event.response, reason: cause == "content_filter" ? .contentFilter : .length)
        case "response.failed":
            let error = event.response?.error
            throw Self.streamError(code: error?.code, message: error?.message)
        case "error":
            throw Self.streamError(code: event.code, message: event.message)
        default:
            return []
        }
    }

    /// A completed turn that called functions ended to call them; one that refused ended on the content filter.
    private var completedReason: FinishReason {
        if sawToolCall { return .toolCalls }
        return refused ? .contentFilter : .stop
    }

    private func text(_ delta: String?) -> [ModelEvent] {
        guard let delta, !delta.isEmpty else { return [] }
        return [.contentDelta(delta)]
    }

    /// A finished output item. The reasoning item's `encrypted_content` is read here and only here: the reference
    /// says the one in `response.output_item.added` may be incomplete. An item without it (a stored response, which
    /// this adapter never asks for) could not be sent back statelessly, so it is not kept.
    private mutating func finished(_ item: ResponsesEvent.Item) -> [ModelEvent] {
        switch item.type {
        case "function_call":
            sawToolCall = true
            let streamed = item.id.flatMap { argumentsByItem.removeValue(forKey: $0) }
            let arguments = item.arguments ?? streamed ?? ""
            return [.toolCall(ToolCallRecord(
                id: item.callId ?? item.id ?? "",
                name: item.name ?? "",
                // A call that takes no arguments may finish with an empty string, which is not JSON.
                arguments: Data((arguments.isEmpty ? "{}" : arguments).utf8)
            ))]
        case "reasoning":
            guard let id = item.id, let encrypted = item.encryptedContent else { return [] }
            let summary = (item.summary ?? []).map(\.text)
            return [.reasoningBlock(.openAIReasoning(id: id, encryptedContent: encrypted, summary: summary))]
        default:
            return []
        }
    }

    private func terminal(_ response: ResponsesEvent.Response?, reason: FinishReason) -> [ModelEvent] {
        guard let usage = response?.usage else { return [.completed(reason)] }
        return [.usage(TokenUsage(
            // `input_tokens` as reported: it INCLUDES the cache reads and writes, as Chat Completions' `prompt_tokens`
            // does, so a caller pricing them takes both out of it.
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheReadTokens: usage.inputTokensDetails?.cachedTokens ?? 0,
            // `cache_write_tokens`, "input tokens that were written to the cache". Its `cache_write_tokens_details`
            // splits it by 30-minute and 12-hour retention, neither of which is Anthropic's one-hour write that
            // `cacheWrite1hTokens` means, so the split is not reported.
            cacheWriteTokens: usage.inputTokensDetails?.cacheWriteTokens ?? 0
        )), .completed(reason)]
    }

    /// The typed error for a failed response or an in-band `error` event: the HTTP status the same failure carries
    /// before the stream opens, so a caller's retry policy treats both alike (as `AnthropicResponseParser` does).
    static func streamError(code: String?, message: String?) -> KBLLMError {
        let status = switch code ?? "" {
        case "rate_limit_exceeded": 429
        case let code where code.hasPrefix("invalid_") || code.hasPrefix("image_"): 400
        default: 500
        }
        let text = [code, message].compactMap { $0 }.joined(separator: ": ")
        return .httpStatus(code: status, message: text.isEmpty ? "the response failed" : text)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// The subset of a Responses streaming event the parser reads. One flat shape for every event type, each field
/// optional, because each type uses a different few of them.
struct ResponsesEvent: Decodable {
    let type: String
    let delta: String?
    let itemId: String?
    let summaryIndex: Int?
    let item: Item?
    let response: Response?
    /// The `error` event's own fields.
    let code: String?
    let message: String?

    /// An output item, a `function_call` or a `reasoning` one among the types read.
    struct Item: Decodable {
        let type: String
        let id: String?
        let callId: String?
        let name: String?
        let arguments: String?
        let encryptedContent: String?
        let summary: [ResponsesSummaryText]?
    }

    /// The response a terminal event carries.
    struct Response: Decodable {
        let usage: ResponsesUsage?
        let error: ResponsesError?
        let incompleteDetails: ResponsesIncompleteDetails?
    }
}

/// Siblings of `ResponsesEvent` rather than nested in it, to stay within the house nesting limit.
struct ResponsesSummaryText: Decodable {
    let text: String
}

struct ResponsesUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let inputTokensDetails: ResponsesInputTokensDetails?
}

struct ResponsesInputTokensDetails: Decodable {
    let cachedTokens: Int?
    let cacheWriteTokens: Int?
}

struct ResponsesError: Decodable {
    let code: String?
    let message: String?
}

struct ResponsesIncompleteDetails: Decodable {
    let reason: String?
}
