import Foundation
import KBLLM

/// Accumulates Anthropic Messages streaming frames into neutral events. Tool arguments
/// arrive as `input_json_delta` fragments and are joined per content block, so exactly one
/// `.toolCall` with complete JSON is emitted when the block stops.
///
/// One parser reads ONE HTTP call. A `pause_turn` continuation is a second call, so the adapter
/// starts a fresh parser seeded with what the merged response has already said (its content
/// length, for citation ranges, and its usage, so the single `.usage` report covers every call).
struct AnthropicResponseParser {
    /// Non-nil ONLY on a structured request that rides the legacy synthetic tool: the tool's
    /// name, whose `tool_use` block is unwrapped back into content rather than surfaced as a
    /// `.toolCall`. A caller registered no tool for it, so emitting a `.toolCall` would make
    /// `AgentSession` try to dispatch a tool that does not exist and fail with `unknownTool`.
    /// Nil on the structured-outputs route, whose answer is ordinary text.
    let structuredToolName: String?
    /// Whether a `pause_turn` from this call will be continued. False once the adapter's
    /// continuation cap is reached, in which case the pause ends the stream as `.paused`.
    let mayContinue: Bool
    private var toolBlocks: [Int: ToolAccumulator] = [:]
    /// The block indices carrying the synthetic tool's structured answer, so their
    /// `input_json_delta` fragments stream as content and their stop emits nothing.
    private var structuredBlocks: Set<Int> = []
    /// On the legacy structured route the tool is offered, not forced, so the model may write
    /// text first ("Here is the plan.") and then call it, or answer in text alone. Text is held
    /// here until the call ends: dropped if the tool answered, else released as the content, so
    /// a remark never corrupts the document and a text-only answer is still validated.
    private var heldText = ""
    private var sawStructuredBlock = false
    /// The code execution container the call reported, for a continuation to name.
    private(set) var containerID: String?
    /// Open `server_tool_use` blocks for web search; the query arrives as `input_json_delta`.
    private var searchBlocks: [Int: SearchAccumulator] = [:]
    /// Open text blocks, keyed by index, to where each began in the collected content, so a
    /// citation can name the span it covers once the block ends.
    private var textBlockStarts: [Int: Int] = [:]
    /// Open thinking blocks, keyed by index: their text and signature so far, emitted whole as a `.reasoningBlock` when
    /// the block stops, so a caller can send it back unchanged.
    private var thinkingBlocks: [Int: (text: String, signature: String)] = [:]
    /// Citations seen inside an open text block, emitted with their range when it stops.
    private var pendingCitations: [Int: [WebSearchCitationSeed]] = [:]
    /// The collected content's length so far in UTF-16 code units, counted across calls.
    private(set) var contentLength: Int
    private var finishReason: FinishReason = .stop
    private var paused = false
    /// Set when this call paused and the adapter should send the turn back to continue it.
    private(set) var continuesAfterPause = false
    /// The call's content blocks as raw JSON, for echoing a paused turn.
    private(set) var turn = AnthropicTurnRecorder()
    private let priorUsage: TokenUsage?
    /// What the call has reported so far, or nil if it has reported nothing. Fields are
    /// overwritten rather than summed: each is stated once, by whichever frame carries it.
    private var reportedUsage: TokenUsage?

    init(
        structuredToolName: String?,
        mayContinue: Bool = false,
        contentOffset: Int = 0,
        priorUsage: TokenUsage? = nil
    ) {
        self.structuredToolName = structuredToolName
        self.mayContinue = mayContinue
        self.contentLength = contentOffset
        self.priorUsage = priorUsage
    }

    struct ToolAccumulator {
        var id: String
        var name: String
        var arguments: String
    }

    /// Usage across every call of the merged response: the earlier calls' plus this one's.
    var totalUsage: TokenUsage? {
        switch (priorUsage, reportedUsage) {
        case let (prior?, reported?): prior + reported
        case let (prior, reported): prior ?? reported
        }
    }

    private mutating func absorbUsage(_ usage: AnthropicFrame.Usage?) {
        guard let usage else { return }
        var merged = reportedUsage ?? TokenUsage(inputTokens: 0, outputTokens: 0)
        if let input = usage.inputTokens { merged.inputTokens = input }
        if let output = usage.outputTokens { merged.outputTokens = output }
        if let cacheRead = usage.cacheReadInputTokens { merged.cacheReadTokens = cacheRead }
        if let cacheWrite = usage.cacheCreationInputTokens { merged.cacheWriteTokens = cacheWrite }
        if let searches = usage.serverToolUse?.webSearchRequests { merged.webSearchRequests = searches }
        if let longWrite = usage.cacheCreation?.ephemeral1HInputTokens { merged.cacheWrite1hTokens = longWrite }
        reportedUsage = merged
    }

    mutating func consume(_ frame: SSEEvent) throws -> [ModelEvent] {
        let payload = frame.data
        let decoded: AnthropicFrame
        do {
            decoded = try Self.decoder.decode(AnthropicFrame.self, from: Data(payload.utf8))
        } catch {
            throw KBLLMError.decoding(expected: "an Anthropic Messages event", fragment: payload)
        }
        turn.record(type: decoded.type, index: decoded.index, payload: payload)
        // Usage arrives in TWO frames: `message_start` opens with input and cache counts,
        // `message_delta` closes with output counts. Both are merged into one report rather
        // than emitted separately, so a consumer adding up what it receives cannot
        // double-count a call.
        absorbUsage(decoded.message?.usage)
        absorbUsage(decoded.usage)
        if let container = decoded.message?.container?.id ?? decoded.delta?.container?.id {
            containerID = container
        }
        switch decoded.type {
        case "error":
            // The API failed after the stream opened. Ending quietly here would hand the caller
            // a cut-off answer as if it were whole (and a cut-off structured document as a
            // schema violation), so it is surfaced as the status the failure would have had.
            throw Self.streamError(decoded.error)
        case "content_block_start":
            return consumeBlockStart(decoded)
        case "content_block_delta":
            return consumeDelta(decoded)
        case "content_block_stop":
            guard let index = decoded.index else { return [] }
            return consumeBlockStop(index)
        case "message_delta":
            if let reason = decoded.delta?.stopReason {
                // `pause_turn` is not a finish: the API stopped a long search turn part way and
                // expects it sent back to resume.
                if reason == "pause_turn" {
                    paused = true
                } else {
                    finishReason = mapStopReason(reason)
                }
            }
            return []
        case "message_stop":
            if paused, mayContinue {
                // The terminal belongs to the merged response, so it waits for the last call.
                continuesAfterPause = true
                return []
            }
            if paused { finishReason = .paused }
            // A legacy structured answer given in text, not through the tool, is released now
            // so the shared conformance check judges it, rather than vanishing.
            let released: [ModelEvent] = !sawStructuredBlock && !heldText.isEmpty ? [.contentDelta(heldText)] : []
            heldText = ""
            guard let usage = totalUsage else { return released + [.completed(finishReason)] }
            return released + [.usage(usage), .completed(finishReason)]
        default:
            return []
        }
    }

    private mutating func consumeBlockStart(_ frame: AnthropicFrame) -> [ModelEvent] {
        guard let block = frame.contentBlock, let index = frame.index else { return [] }
        switch block.type {
        case "tool_use":
            if let structuredToolName, block.name == structuredToolName {
                // The structured tool's block: its JSON becomes content, not a tool call, and
                // any text held before it was commentary on the answer, not part of it.
                structuredBlocks.insert(index)
                sawStructuredBlock = true
                heldText = ""
            } else {
                toolBlocks[index] = ToolAccumulator(id: block.id ?? "", name: block.name ?? "", arguments: "")
            }
        case "server_tool_use" where block.name == "web_search":
            searchBlocks[index] = SearchAccumulator(id: block.id ?? "", startQuery: block.input?.query, input: "")
        case "web_search_tool_result":
            return searchResultEvents(block)
        case "text":
            textBlockStarts[index] = contentLength
        case "thinking":
            thinkingBlocks[index] = ("", "")
        case "redacted_thinking":
            if let data = block.data { return [.reasoningBlock(.redacted(data: data))] }
        default:
            break
        }
        return []
    }

    private mutating func consumeBlockStop(_ index: Int) -> [ModelEvent] {
        // The structured block ends silently: its content was streamed as it arrived.
        if structuredBlocks.remove(index) != nil { return [] }
        if let thinking = thinkingBlocks.removeValue(forKey: index) {
            // A block without a signature cannot be sent back (the API would refuse it), so it is shown but not kept.
            guard !thinking.signature.isEmpty else { return [] }
            return [.reasoningBlock(.thinking(text: thinking.text, signature: thinking.signature))]
        }
        if let search = searchBlocks.removeValue(forKey: index) {
            return [.webSearchCall(WebSearchCall(id: search.id, query: Self.query(of: search)))]
        }
        if let start = textBlockStarts.removeValue(forKey: index) {
            let seeds = pendingCitations.removeValue(forKey: index) ?? []
            return seeds.map { seed in
                .citation(WebSearchCitation(
                    url: seed.url,
                    title: seed.title,
                    citedText: seed.citedText,
                    utf16Range: start..<contentLength
                ))
            }
        }
        guard let accumulator = toolBlocks.removeValue(forKey: index) else { return [] }
        // A tool that takes NO parameters gets no `input_json_delta` at all: the block opens
        // with an empty input and closes again, leaving nothing joined. Empty string is not
        // valid JSON, so dispatch refused the call and the run died on a tool whose arguments
        // were never in question. A call with no input is an empty OBJECT.
        let joined = accumulator.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ToolCallRecord(
            id: accumulator.id,
            name: accumulator.name,
            arguments: Data((joined.isEmpty ? "{}" : accumulator.arguments).utf8)
        )
        return [.toolCall(record)]
    }

    private mutating func consumeDelta(_ frame: AnthropicFrame) -> [ModelEvent] {
        guard let delta = frame.delta else { return [] }
        if delta.type == "text_delta", let text = delta.text {
            if structuredToolName != nil {
                // Legacy structured route: held until the call shows whether the tool answered.
                if !sawStructuredBlock { heldText += text }
                return []
            }
            contentLength += text.utf16.count
            return [.contentDelta(text)]
        }
        // A `thinking_delta` block carries the model's reasoning in its `thinking` field; it
        // maps to the neutral `.reasoningDelta`, never to `.contentDelta`, so reasoning is
        // surfaced as progress without ever joining the answer.
        if delta.type == "thinking_delta" || delta.type == "signature_delta" {
            return consumeThinking(delta, at: frame.index)
        }
        if delta.type == "citations_delta", let index = frame.index,
           let citation = delta.citation, let url = citation.url {
            pendingCitations[index, default: []].append(
                WebSearchCitationSeed(url: url, title: citation.title, citedText: citation.citedText ?? "")
            )
            return []
        }
        if delta.type == "input_json_delta", let partial = delta.partialJson, let index = frame.index {
            // The forced structured block's JSON streams as content deltas; every other tool
            // block accumulates its arguments for a single terminal `.toolCall`.
            if structuredBlocks.contains(index) {
                contentLength += partial.utf16.count
                return [.contentDelta(partial)]
            }
            if searchBlocks[index] != nil {
                searchBlocks[index]?.input += partial
            } else {
                toolBlocks[index]?.arguments += partial
            }
        }
        return []
    }

    /// A thinking block's text, surfaced as it streams, and its signature, both kept for the block's `.reasoningBlock`.
    private mutating func consumeThinking(_ delta: AnthropicFrame.Delta, at index: Int?) -> [ModelEvent] {
        if let signature = delta.signature, let index {
            thinkingBlocks[index]?.signature += signature
        }
        guard let thinking = delta.thinking else { return [] }
        if let index { thinkingBlocks[index]?.text += thinking }
        return [.reasoningDelta(thinking)]
    }

    /// Map Anthropic's stop reason, honouring the legacy structured route: a `tool_use` stop
    /// there is the structured ANSWER arriving, so it maps to `.stop`, never `.toolCalls`, which
    /// would tell a caller the run ended to dispatch a tool it never registered. A `refusal` (the
    /// model declined, which is how a structured answer can come back off-schema) is
    /// `.contentFilter`, so it is not mistaken for a finished answer.
    private func mapStopReason(_ reason: String) -> FinishReason {
        switch reason {
        case "tool_use": structuredToolName == nil ? .toolCalls : .stop
        case "max_tokens", "model_context_window_exceeded": .length
        case "refusal": .contentFilter
        default: .stop
        }
    }

    /// The typed error for an in-band `error` event: the HTTP status the same failure carries
    /// when it happens before the stream opens, so a caller's retry policy (529 and 429 are
    /// worth retrying, 400 is not) treats both the same.
    static func streamError(_ error: AnthropicFrame.APIError?) -> KBLLMError {
        let type = error?.type ?? "error"
        let code = switch type {
        case "invalid_request_error": 400
        case "authentication_error": 401
        case "permission_error": 403
        case "not_found_error": 404
        case "request_too_large": 413
        case "rate_limit_error": 429
        case "overloaded_error": 529
        default: 500
        }
        return .httpStatus(code: code, message: [type, error?.message].compactMap { $0 }.joined(separator: ": "))
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
