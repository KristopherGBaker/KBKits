import Foundation
import KBLLM

// OpenAI Responses transcripts, built from the event shapes in the official streaming-events reference
// (developers.openai.com/api/reference/resources/responses, read 2026-11-05): each frame is `event: <type>` and a
// JSON `data:` whose `type` repeats it, with `sequence_number`, `output_index` and `item_id` as documented. No
// `[DONE]` sentinel: the stream ends after the terminal event.
extension Fixtures {
    /// The encrypted reasoning, base64 full of `/` and `+`, so a body that escaped it would be caught.
    static let responsesEncrypted = "gAAAAB/enc+reasoning/data=="

    static let responsesReasoningBlock = ReasoningBlock.openAIReasoning(
        id: "rs_1", encryptedContent: responsesEncrypted, summary: ["Check the weather.", "Then answer."]
    )

    static let responsesUsage =
        #"{"input_tokens":120,"input_tokens_details":{"cached_tokens":100,"cache_write_tokens":8},"#
        + #""output_tokens":12,"output_tokens_details":{"reasoning_tokens":4},"total_tokens":132}"#

    private static func responses(_ type: String, _ fields: String, sequence: Int) -> String {
        frame(event: type, data: #"{"type":"\#(type)","sequence_number":\#(sequence),\#(fields)}"#)
    }

    private static func completed(_ status: String = "completed", extra: String = "") -> String {
        responses(
            "response.\(status)",
            #""response":{"id":"resp_1","object":"response","status":"\#(status)","#
                + #"\#(extra)"usage":\#(responsesUsage)}"#,
            sequence: 99
        )
    }

    private static let created = responses(
        "response.created", #""response":{"id":"resp_1","object":"response","status":"in_progress","usage":null}"#,
        sequence: 0
    )

    /// Plain text in two deltas, then a completed response with cached and written tokens.
    static let responsesText = bytes(
        created
        + responses(
            "response.output_item.added",
            #""output_index":0,"item":{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","#
                + #""content":[]}"#,
            sequence: 1
        )
        + responses(
            "response.output_text.delta",
            #""item_id":"msg_1","output_index":0,"content_index":0,"delta":"The weather in Paris ","logprobs":[]"#,
            sequence: 2
        )
        + responses(
            "response.output_text.delta",
            #""item_id":"msg_1","output_index":0,"content_index":0,"delta":"is sunny.","logprobs":[]"#,
            sequence: 3
        )
        + responses(
            "response.output_text.done",
            #""item_id":"msg_1","output_index":0,"content_index":0,"text":"The weather in Paris is sunny.""#,
            sequence: 4
        )
        + completed()
    )

    private static let reasoningEvents =
        responses(
            "response.output_item.added",
            #""output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}"#, sequence: 1
        )
        + responses(
            "response.reasoning_summary_part.added",
            #""item_id":"rs_1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}"#,
            sequence: 2
        )
        + responses(
            "response.reasoning_summary_text.delta",
            #""item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Check the ""#, sequence: 3
        )
        + responses(
            "response.reasoning_summary_text.delta",
            #""item_id":"rs_1","output_index":0,"summary_index":0,"delta":"weather.""#, sequence: 4
        )
        + responses(
            "response.reasoning_summary_part.added",
            #""item_id":"rs_1","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""}"#,
            sequence: 5
        )
        + responses(
            "response.reasoning_summary_text.delta",
            #""item_id":"rs_1","output_index":0,"summary_index":1,"delta":"Then answer.""#, sequence: 6
        )
        + responses(
            "response.output_item.done",
            #""output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":["#
                + #"{"type":"summary_text","text":"Check the weather."},"#
                + #"{"type":"summary_text","text":"Then answer."}],"#
                + #""encrypted_content":"\#(responsesEncrypted)"}"#,
            sequence: 7
        )

    /// The function call's events, its arguments split across two deltas; `finalArguments` is the finished item's
    /// `arguments` field, or nil to leave it out.
    private static func functionCall(finalArguments: String?) -> String {
        let arguments = finalArguments.map { #","arguments":"\#($0)""# } ?? ""
        return responses(
            "response.output_item.added",
            #""output_index":1,"item":{"id":"fc_1","type":"function_call","status":"in_progress","#
                + #""call_id":"call_1","name":"get_weather","arguments":""}"#,
            sequence: 8
        )
        + responses(
            "response.function_call_arguments.delta",
            #""item_id":"fc_1","output_index":1,"delta":"{\"city\":""#, sequence: 9
        )
        + responses(
            "response.function_call_arguments.delta",
            #""item_id":"fc_1","output_index":1,"delta":"\"Paris\"}""#, sequence: 10
        )
        + responses(
            "response.function_call_arguments.done",
            #""item_id":"fc_1","output_index":1,"arguments":"{\"city\":\"Paris\"}""#, sequence: 11
        )
        + responses(
            "response.output_item.done",
            #""output_index":1,"item":{"id":"fc_1","type":"function_call","status":"completed","#
                + #""call_id":"call_1","name":"get_weather"\#(arguments)}"#,
            sequence: 12
        )
    }

    /// A summarized, encrypted reasoning item, then a `get_weather` call whose arguments stream in two deltas.
    static let responsesToolCall = bytes(
        created + reasoningEvents + functionCall(finalArguments: #"{\"city\":\"Paris\"}"#) + completed()
    )

    /// The same call, its finished item without `arguments`, so only the deltas carry them.
    static let responsesToolCallFromDeltas = bytes(created + functionCall(finalArguments: nil) + completed())

    /// A call to a tool that takes no arguments, finished with an empty `arguments`.
    static let responsesNoArgumentCall = bytes(
        created
        + responses(
            "response.output_item.done",
            #""output_index":0,"item":{"id":"fc_2","type":"function_call","status":"completed","#
                + #""call_id":"call_2","name":"get_time","arguments":""}"#,
            sequence: 1
        )
        + completed()
    )

    /// Text cut off by the output limit.
    static let responsesIncomplete = bytes(
        created
        + responses(
            "response.output_text.delta",
            #""item_id":"msg_1","output_index":0,"content_index":0,"delta":"The weather","logprobs":[]"#, sequence: 1
        )
        + completed("incomplete", extra: #""incomplete_details":{"reason":"max_output_tokens"},"#)
    )

    /// A response that failed after the stream opened.
    static let responsesFailed = bytes(
        created
        + responses(
            "response.failed",
            #""response":{"id":"resp_1","object":"response","status":"failed","#
                + #""error":{"code":"server_error","message":"The model failed to generate a response."},"#
                + #""incomplete_details":null,"usage":null}"#,
            sequence: 1
        )
    )

    /// An in-band `error` event.
    static let responsesError = bytes(
        responses("error", #""code":"rate_limit_exceeded","message":"Slow down","param":null"#, sequence: 0)
    )
}
