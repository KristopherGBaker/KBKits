import Foundation

// Recorded provider transcripts in each provider's GENUINE streaming wire shape. The
// Anthropic transcripts use the Messages event grammar (message_start,
// content_block_start/delta/stop with text_delta and input_json_delta, message_delta with
// stop_reason, message_stop). The OpenAI transcripts use the Chat Completions chunk grammar
// (choices[].delta.content, choices[].delta.tool_calls[].function.arguments fragments,
// finish_reason) terminated by `data: [DONE]`. Neither is the other's encoding re-labeled;
// that difference is what the equivalence and discriminator tests turn on.
//
// Long JSON payloads are concatenated across raw-string fragments purely to stay under the
// line-length limit; the joined value is one wire frame.
enum Fixtures {
    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func text(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// One terminated SSE frame: an optional `event:` line, a `data:` line, and the blank
    /// line that closes it.
    static func frame(event: String? = nil, data: String) -> String {
        if let event {
            return "event: \(event)\ndata: \(data)\n\n"
        }
        return "data: \(data)\n\n"
    }

    // MARK: Anthropic Messages transcripts

    private static let anthMessageStart =
        #"{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}"#
    // Reused by the usage fixtures in `Fixtures+Usage.swift`; `private` is file-scoped.
    static let anthTextBlockStart =
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
    // Reused by the usage fixtures in `Fixtures+Usage.swift`; `private` is file-scoped.
    static let anthTextDelta =
        #"{"type":"content_block_delta","index":0,"delta":"#
        + #"{"type":"text_delta","text":"The weather in Paris is sunny."}}"#
    // Reused by the usage fixtures in `Fixtures+Usage.swift`; `private` is file-scoped.
    static let anthTextBlockStop =
        #"{"type":"content_block_stop","index":0}"#
    private static let anthToolBlockStart =
        #"{"type":"content_block_start","index":1,"content_block":"#
        + #"{"type":"tool_use","id":"call_1","name":"get_weather"}}"#
    private static let anthToolDelta =
        #"{"type":"content_block_delta","index":1,"delta":"#
        + #"{"type":"input_json_delta","partial_json":"{\"city\":\"Paris\"}"}}"#
    private static let anthToolBlockStop =
        #"{"type":"content_block_stop","index":1}"#
    private static let anthMessageDelta =
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null}}"#
    // Reused by the usage fixtures in `Fixtures+Usage.swift`; `private` is file-scoped.
    static let anthMessageStop =
        #"{"type":"message_stop"}"#

    /// The weather exchange: assistant text, then a `get_weather` tool call whose arguments
    /// arrive whole, then a tool_use stop reason.
    static let anthropicWeather = bytes(
        frame(event: "message_start", data: anthMessageStart)
        + frame(event: "content_block_start", data: anthTextBlockStart)
        + frame(event: "content_block_delta", data: anthTextDelta)
        + frame(event: "content_block_stop", data: anthTextBlockStop)
        + frame(event: "content_block_start", data: anthToolBlockStart)
        + frame(event: "content_block_delta", data: anthToolDelta)
        + frame(event: "content_block_stop", data: anthToolBlockStop)
        + frame(event: "message_delta", data: anthMessageDelta)
        + frame(event: "message_stop", data: anthMessageStop)
    )

    /// The raw text form, so a marker test can prove this is genuinely Anthropic-shaped.
    static let anthropicWeatherText = text(anthropicWeather)

    private static let anthSplitToolStart =
        #"{"type":"content_block_start","index":0,"content_block":"#
        + #"{"type":"tool_use","id":"call_1","name":"get_weather"}}"#
    private static let anthSplitFragmentOne =
        #"{"type":"content_block_delta","index":0,"delta":"#
        + #"{"type":"input_json_delta","partial_json":"{\"city\":\"Par"}}"#
    private static let anthSplitFragmentTwo =
        #"{"type":"content_block_delta","index":0,"delta":"#
        + #"{"type":"input_json_delta","partial_json":"is\"}"}}"#

    /// Same tool call, but its single JSON value is split across two separately terminated
    /// `input_json_delta` frames.
    static let anthropicSplitToolCall = bytes(
        frame(event: "content_block_start", data: anthSplitToolStart)
        + frame(event: "content_block_delta", data: anthSplitFragmentOne)
        + frame(event: "content_block_delta", data: anthSplitFragmentTwo)
        + frame(event: "content_block_stop", data: anthTextBlockStop)
        + frame(event: "message_delta", data: anthMessageDelta)
        + frame(event: "message_stop", data: anthMessageStop)
    )

    private static let anthTrailingText =
        #"{"type":"content_block_delta","index":0,"delta":"#
        + #"{"type":"text_delta","text":"LEAKED"}}"#

    /// A well-formed text delta that is NOT closed by a blank line, appended after a
    /// complete transcript. The shipped SSE parser must drop it.
    static let anthropicTrailingPartial =
        "event: content_block_delta\ndata: \(anthTrailingText)\n"

    static let anthropicWeatherWithTrailingPartial =
        anthropicWeather + bytes(anthropicTrailingPartial)

    private static let anthBadFrame =
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"#

    /// A frame whose JSON payload is malformed, to drive `.decoding`.
    static let anthropicUndecodable = bytes(
        frame(event: "message_start", data: anthMessageStart)
        + frame(event: "content_block_delta", data: anthBadFrame)
    )

    private static let anthThinkingBlockStart =
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#
    private static let anthThinkingDelta =
        #"{"type":"content_block_delta","index":0,"delta":"#
        + #"{"type":"thinking_delta","thinking":"Paris in June is usually warm."}}"#
    private static let anthThinkingBlockStop =
        #"{"type":"content_block_stop","index":0}"#
    private static let anthAnswerBlockStart =
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#
    private static let anthAnswerDelta =
        #"{"type":"content_block_delta","index":1,"delta":"#
        + #"{"type":"text_delta","text":"The weather in Paris is sunny."}}"#
    private static let anthAnswerBlockStop =
        #"{"type":"content_block_stop","index":1}"#
    private static let anthEndTurnDelta =
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}"#

    /// A reasoning exchange: a `thinking_delta` block whose text is distinct from the answer
    /// text, then the answer, then an `end_turn` stop. The reasoning must surface as
    /// `.reasoningDelta` and never appear in `ModelResponse.content`.
    static let anthropicReasoning = bytes(
        frame(event: "message_start", data: anthMessageStart)
        + frame(event: "content_block_start", data: anthThinkingBlockStart)
        + frame(event: "content_block_delta", data: anthThinkingDelta)
        + frame(event: "content_block_stop", data: anthThinkingBlockStop)
        + frame(event: "content_block_start", data: anthAnswerBlockStart)
        + frame(event: "content_block_delta", data: anthAnswerDelta)
        + frame(event: "content_block_stop", data: anthAnswerBlockStop)
        + frame(event: "message_delta", data: anthEndTurnDelta)
        + frame(event: "message_stop", data: anthMessageStop)
    )

    /// The reasoning text carried by `anthropicReasoning`, for an assertion that it surfaces.
    static let anthropicReasoningText = "Paris in June is usually warm."

    /// A 200 body in genuine Anthropic wire form whose payload is an error object, not an
    /// event stream (the observed unknown-path case). It yields no usable event, so the
    /// adapter must surface `.decoding` naming a fragment of this body.
    static let anthropicJSONError200 = bytes(
        #"{"type":"error","error":{"type":"not_found_error","message":"Unexpected endpoint or method"}}"#
    )

    // MARK: OpenAI Chat Completions transcripts

    // Reused by `Fixtures+Usage.swift`; `private` in Swift is file-scoped, not type-scoped.
    static func openAIChoice(_ delta: String, finish: String = "null") -> String {
        #"{"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
    }

    private static let openAIRoleDelta = openAIChoice(#"{"role":"assistant","content":""}"#)
    static let openAIContentDelta =
        openAIChoice(#"{"content":"The weather in Paris is sunny."}"#)
    private static let openAIToolOpen = openAIChoice(
        #"{"tool_calls":[{"index":0,"id":"call_1","type":"function","#
        + #""function":{"name":"get_weather","arguments":""}}]}"#
    )
    private static let openAIToolArgs = openAIChoice(
        #"{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"Paris\"}"}}]}"#
    )
    private static let openAIFinish = openAIChoice("{}", finish: #""tool_calls""#)

    /// The same logical weather exchange in OpenAI's chunk grammar.
    static let openAIWeather = bytes(
        frame(data: openAIRoleDelta)
        + frame(data: openAIContentDelta)
        + frame(data: openAIToolOpen)
        + frame(data: openAIToolArgs)
        + frame(data: openAIFinish)
        + frame(data: "[DONE]")
    )

    static let openAIWeatherText = text(openAIWeather)

    private static let openAISplitOpen = openAIChoice(
        #"{"tool_calls":[{"index":0,"id":"call_1","type":"function","#
        + #""function":{"name":"get_weather","arguments":"{\"city\":\"Par"}}]}"#
    )
    private static let openAISplitArgs = openAIChoice(
        #"{"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]}"#
    )

    /// The single JSON value split across two separately terminated `function.arguments`
    /// delta frames.
    static let openAISplitToolCall = bytes(
        frame(data: openAISplitOpen)
        + frame(data: openAISplitArgs)
        + frame(data: openAIFinish)
        + frame(data: "[DONE]")
    )

    private static let openAIParallelOpenA = openAIChoice(
        #"{"tool_calls":[{"index":0,"id":"call_a","type":"function","#
        + #""function":{"name":"get_weather","arguments":"{\"city\":\""}}]}"#
    )
    private static let openAIParallelOpenB = openAIChoice(
        #"{"tool_calls":[{"index":1,"id":"call_b","type":"function","#
        + #""function":{"name":"get_time","arguments":"{\"zone\":\""}}]}"#
    )
    private static let openAIParallelArgsA = openAIChoice(
        #"{"tool_calls":[{"index":0,"function":{"arguments":"Paris\"}"}}]}"#
    )
    private static let openAIParallelArgsB = openAIChoice(
        #"{"tool_calls":[{"index":1,"function":{"arguments":"CET\"}"}}]}"#
    )

    /// Two parallel tool calls whose argument fragments interleave across frames by index.
    static let openAIParallelToolCalls = bytes(
        frame(data: openAIParallelOpenA)
        + frame(data: openAIParallelOpenB)
        + frame(data: openAIParallelArgsA)
        + frame(data: openAIParallelArgsB)
        + frame(data: openAIFinish)
        + frame(data: "[DONE]")
    )

    static let openAITrailingPartial =
        "data: \(openAIChoice(#"{"content":"LEAKED"}"#))\n"

    static let openAIWeatherWithTrailingPartial =
        openAIWeather + bytes(openAITrailingPartial)

    /// A chunk whose JSON payload is malformed, to drive `.decoding`.
    static let openAIUndecodable = bytes(
        frame(data: #"{"choices":[{"index":0,"delta":{"content":"#)
    )

    private static let openAIReasoningDelta =
        openAIChoice(#"{"reasoning_content":"Paris in June is usually warm."}"#)
    private static let openAIAnswerDelta =
        openAIChoice(#"{"content":"The weather in Paris is sunny."}"#)
    private static let openAIStopFinish = openAIChoice("{}", finish: #""stop""#)

    /// A reasoning exchange: a `delta.reasoning_content` chunk whose text is distinct from
    /// the answer text, then the answer, then a stop. The reasoning must surface as
    /// `.reasoningDelta` and never appear in `ModelResponse.content`.
    static let openAIReasoning = bytes(
        frame(data: openAIRoleDelta)
        + frame(data: openAIReasoningDelta)
        + frame(data: openAIAnswerDelta)
        + frame(data: openAIStopFinish)
        + frame(data: "[DONE]")
    )

    /// The reasoning text carried by `openAIReasoning`, for an assertion that it surfaces.
    static let openAIReasoningText = "Paris in June is usually warm."

    /// A 200 body that is a plain JSON error object, NOT a chunk stream (the observed
    /// unknown-path case). It has no SSE frame, so the adapter produces zero events and must
    /// surface `.decoding` naming a fragment of this body.
    static let openAIJSONError200 = bytes(
        #"{"error":"Unexpected endpoint or method"}"#
    )

    /// A 200 `text/event-stream` whose frames are well-formed SSE but carry an error payload
    /// that yields no usable event: the OpenAI frame decodes with no `choices`, so nothing is
    /// emitted. The adapter must still surface `.decoding` with a fragment drawn from the body.
    static let openAIStreamErrorNoEvents = bytes(
        frame(data: #"{"error":{"message":"Unexpected endpoint or method","type":"invalid_request_error"}}"#)
    )

    // MARK: Structured output transcripts (unit 6)

    /// Serialize a dictionary into a compact JSON string, then wrap it as one terminated SSE
    /// frame. Building the frame through `JSONSerialization` escapes the embedded structured
    /// document's own quotes correctly, which a hand-written raw string would get wrong.
    static func jsonFrame(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return frame(data: String(bytes: [UInt8](data), encoding: .utf8) ?? "")
    }

    /// One OpenAI chunk carrying an optional content delta and/or a finish reason.
    private static func openAIChunkFrame(content: String? = nil, finishReason: String? = nil) -> String {
        var delta: [String: Any] = [:]
        if let content { delta["content"] = content }
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finishReason { choice["finish_reason"] = finishReason }
        return jsonFrame(["choices": [choice]])
    }

    /// An OpenAI structured stream: the given content chunks (the structured document arrives as
    /// ordinary content, fact 1), then a `stop` finish and the `[DONE]` sentinel.
    static func openAIStructured(contentChunks: [String]) -> [UInt8] {
        var text = contentChunks.map { openAIChunkFrame(content: $0) }.joined()
        text += openAIChunkFrame(finishReason: "stop")
        text += frame(data: "[DONE]")
        return bytes(text)
    }

    /// An Anthropic legacy-route structured stream: a `tool_use` block named `toolName` whose
    /// `input_json_delta` fragments carry the structured document, then a `tool_use` stop.
    static func anthropicStructured(toolName: String, fragments: [String]) -> [UInt8] {
        var text = frame(event: "message_start", data: anthMessageStart)
        text += jsonFrame([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "tool_use", "id": "toolu_1", "name": toolName]
        ])
        for fragment in fragments {
            text += jsonFrame([
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": fragment]
            ])
        }
        text += jsonFrame(["type": "content_block_stop", "index": 0])
        text += jsonFrame(["type": "message_delta", "delta": ["stop_reason": "tool_use"]])
        text += frame(event: "message_stop", data: anthMessageStop)
        return bytes(text)
    }

    /// An Anthropic stream that IGNORES the structured tool: a plain `text` block and an `end_turn`
    /// stop, with no `tool_use`. A structured request must reject this, not surface it as prose.
    static func anthropicStructuredPlainText(_ answer: String) -> [UInt8] {
        var text = frame(event: "message_start", data: anthMessageStart)
        text += jsonFrame([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "text", "text": ""]
        ])
        text += jsonFrame([
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "text_delta", "text": answer]
        ])
        text += jsonFrame(["type": "content_block_stop", "index": 0])
        text += jsonFrame(["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        text += frame(event: "message_stop", data: anthMessageStop)
        return bytes(text)
    }
}

// Split out of `Fixtures` rather than grown inside it: the enum is at the house type-body limit,
// and a transcript is a transcript wherever it is declared.
extension Fixtures {
    /// A tool that takes NO parameters: the block opens and closes with no `input_json_delta`
    /// between, which is exactly what Anthropic sends and what used to join to an empty string.
    static let anthropicNoArgumentTool = bytes(
        frame(event: "message_start", data: anthMessageStart)
        + frame(
            event: "content_block_start",
            data: #"{"type":"content_block_start","index":0,"content_block":"#
                + #"{"type":"tool_use","id":"call_1","name":"today_summary","input":{}}}"#
        )
        + frame(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#)
        + frame(event: "message_delta", data: anthMessageDelta)
        + frame(event: "message_stop", data: anthMessageStop)
    )
}
